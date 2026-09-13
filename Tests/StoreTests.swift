import StoreKit
import XCTest

@testable import StoreKitWrapper

@MainActor
final class StoreTests: XCTestCase {
    private enum Failure: Error {
        case metadata
        case verification
    }

    func testMetadataFailureKeepsVerifiedIdentityWithoutFalseLegacyRevocation() async throws {
        let store = Store(
            client: .init(
                loadProducts: { _ in
                    throw Failure.metadata
                },
                currentEntitlements: { identifiers, _ in
                    .init(productIDs: identifiers)
                }
            ))
        defer {
            store.close()
        }
        var identities: Set<String>?
        var legacyCalled = false
        store.open(
            groupID: nil,
            productIDs: ["premium"],
            purchasedProductIDsDidSet: { identifiers in
                identities = identifiers
            },
            purchasedSubscriptionsDidSet: { _ in
                legacyCalled = true
            })
        try await waitUntil {
            store.lastError != nil
        }
        XCTAssertEqual(identities, ["premium"])
        XCTAssertFalse(legacyCalled)
        XCTAssertFalse(store.isLoading)
    }

    func testEmptyCatalogDoesNotEraseVerifiedIdentity() async throws {
        let store = Store(
            client: .init(
                loadProducts: { _ in
                    []
                },
                currentEntitlements: { identifiers, _ in
                    .init(productIDs: identifiers)
                }
            ))
        defer {
            store.close()
        }
        var identities: Set<String>?
        var legacyCalled = false
        store.open(
            groupID: nil,
            productIDs: ["premium"],
            purchasedProductIDsDidSet: { identifiers in
                identities = identifiers
            },
            purchasedSubscriptionsDidSet: { _ in
                legacyCalled = true
            })
        try await waitUntil {
            identities != nil && !store.isLoading
        }
        XCTAssertEqual(identities, ["premium"])
        XCTAssertFalse(legacyCalled)
    }

    func testVerifiedEmptyEntitlementsStillReportInactive() async throws {
        let store = Store(
            client: .init(
                loadProducts: { _ in
                    []
                },
                currentEntitlements: { _, _ in
                    .init(productIDs: [])
                }
            ))
        defer {
            store.close()
        }
        var identities: Set<String>?
        var legacyCount: Int?
        store.open(
            groupID: nil,
            productIDs: ["premium"],
            purchasedProductIDsDidSet: { identifiers in
                identities = identifiers
            },
            purchasedSubscriptionsDidSet: { products in
                legacyCount = products.count
            })
        try await waitUntil {
            identities != nil && !store.isLoading
        }
        XCTAssertEqual(identities, [])
        XCTAssertEqual(legacyCount, 0)
    }

    func testVerificationFailureDoesNotPublishInactive() async throws {
        let store = Store(
            client: .init(
                loadProducts: { _ in
                    []
                },
                currentEntitlements: { _, _ in
                    throw Failure.verification
                }
            ))
        defer {
            store.close()
        }
        var identities: Set<String>?
        var legacyCalled = false
        store.open(
            groupID: nil,
            productIDs: ["premium"],
            purchasedProductIDsDidSet: { identifiers in
                identities = identifiers
            },
            purchasedSubscriptionsDidSet: { _ in
                legacyCalled = true
            })
        try await waitUntil {
            store.lastError != nil && !store.isLoading
        }
        XCTAssertNil(identities)
        XCTAssertFalse(legacyCalled)
    }

    func testReopeningIgnoresDelayedPreviousSnapshot() async throws {
        let gate = SnapshotGate()
        let store = Store(
            client: .init(
                loadProducts: { _ in
                    []
                },
                currentEntitlements: { identifiers, _ in
                    if identifiers == ["old"] {
                        await gate.wait()
                    }
                    return .init(productIDs: identifiers)
                }
            ))
        defer {
            store.close()
        }
        var oldCallbacks = 0
        var identities: [Set<String>] = []
        store.open(
            groupID: nil,
            productIDs: ["old"],
            purchasedProductIDsDidSet: { _ in
                oldCallbacks += 1
            }, purchasedSubscriptionsDidSet: nil)
        try await waitUntilWaiting(gate)
        store.open(
            groupID: nil,
            productIDs: ["new"],
            purchasedProductIDsDidSet: { identifiers in
                identities.append(identifiers)
            }, purchasedSubscriptionsDidSet: nil)
        await gate.resume()
        try await waitUntil {
            !identities.isEmpty && !store.isLoading
        }
        XCTAssertEqual(oldCallbacks, 0)
        XCTAssertEqual(identities, [["new"]])
        XCTAssertEqual(store.purchasedProductIDs, ["new"])
    }

    func testCloseSuppressesDelayedSnapshot() async throws {
        let gate = SnapshotGate()
        let store = Store(
            client: .init(
                loadProducts: { _ in
                    []
                },
                currentEntitlements: { identifiers, _ in
                    await gate.wait()
                    return .init(productIDs: identifiers)
                }
            ))
        var callbacks = 0
        store.open(
            groupID: nil,
            productIDs: ["premium"],
            purchasedProductIDsDidSet: { _ in
                callbacks += 1
            }, purchasedSubscriptionsDidSet: nil)
        try await waitUntilWaiting(gate)
        store.close()
        await gate.resume()
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(callbacks, 0)
        XCTAssertFalse(store.isLoading)
    }

    func testNoConfigurationStartsNoRequests() async throws {
        let store = Store(
            client: .init(
                loadProducts: { _ in
                    XCTFail("Unconfigured store requested product metadata")
                    return []
                },
                currentEntitlements: { _, _ in
                    XCTFail("Unconfigured store requested entitlements")
                    return .init(productIDs: [])
                }
            ))
        defer {
            store.close()
        }
        store.open(groupID: nil, productIDs: [], purchasedSubscriptionsDidSet: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.lastError)
    }

    func testClosingInsideCallbackStopsLegacyDelivery() async throws {
        let store = Store(
            client: .init(
                loadProducts: { _ in
                    []
                },
                currentEntitlements: { _, _ in
                    .init(productIDs: [])
                }
            ))
        var receivedSnapshot = false
        var legacyCalled = false
        store.open(
            groupID: nil,
            productIDs: ["premium"],
            purchasedProductIDsDidSet: { _ in
                receivedSnapshot = true
                store.close()
            },
            purchasedSubscriptionsDidSet: { _ in
                legacyCalled = true
            }
        )
        try await waitUntil {
            receivedSnapshot
        }
        XCTAssertFalse(legacyCalled)
        XCTAssertFalse(store.isLoading)
    }

    func testIdleListenerDoesNotRetainStore() async throws {
        var store: Store? = Store(
            client: .init(
                loadProducts: { _ in
                    []
                },
                currentEntitlements: { _, _ in
                    .init(productIDs: [])
                }
            ))
        weak var weakStore = store
        var receivedSnapshot = false
        store?.open(
            groupID: nil,
            productIDs: ["premium"],
            purchasedProductIDsDidSet: { _ in
                receivedSnapshot = true
            },
            purchasedSubscriptionsDidSet: nil
        )
        try await waitUntil {
            receivedSnapshot && store?.isLoading == false
        }
        store = nil
        try await waitUntil {
            weakStore == nil
        }
        XCTAssertNil(weakStore)
    }

    func testImmediateCloseDoesNotRestartLoadingOrRequests() async throws {
        let store = Store(
            client: .init(
                loadProducts: { _ in
                    XCTFail("Closed store requested metadata")
                    return []
                },
                currentEntitlements: { _, _ in
                    XCTFail("Closed store requested entitlements")
                    return .init(productIDs: [])
                }
            ))
        store.open(groupID: nil, productIDs: ["premium"], purchasedSubscriptionsDidSet: nil)
        store.close()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(store.isLoading)
    }

    func testPendingMetadataDoesNotRetainStore() async throws {
        let gate = SnapshotGate()
        var store: Store? = Store(
            client: .init(
                loadProducts: { _ in
                    await gate.wait()
                    return []
                },
                currentEntitlements: { identifiers, _ in
                    .init(productIDs: identifiers)
                }
            ))
        weak var weakStore = store
        store?.open(groupID: nil, productIDs: ["premium"], purchasedSubscriptionsDidSet: nil)
        try await waitUntilWaiting(gate)
        store = nil
        let wasReleased = weakStore == nil
        await gate.resume()
        XCTAssertTrue(wasReleased, "Pending catalog request retained its Store owner")
    }

    func testPendingEntitlementsDoNotRetainStore() async throws {
        let gate = SnapshotGate()
        var store: Store? = Store(
            client: .init(
                loadProducts: { _ in
                    []
                },
                currentEntitlements: { identifiers, _ in
                    await gate.wait()
                    return .init(productIDs: identifiers)
                }
            ))
        weak var weakStore = store
        store?.open(groupID: nil, productIDs: ["premium"], purchasedSubscriptionsDidSet: nil)
        try await waitUntilWaiting(gate)
        store = nil
        let wasReleased = weakStore == nil
        await gate.resume()
        XCTAssertTrue(wasReleased, "Pending entitlement request retained its Store owner")
    }

    func testExpiryRechecksAuthorityAndPublishesActualRevocation() async throws {
        let snapshots = ExpiringSnapshots()
        let store = Store(
            client: .init(
                loadProducts: { _ in
                    throw Failure.metadata
                },
                currentEntitlements: { _, _ in
                    try await snapshots.next()
                }
            ))
        defer {
            store.close()
        }
        var identities: [Set<String>] = []
        var legacy: [Int] = []
        store.open(
            groupID: nil, productIDs: ["premium"],
            purchasedProductIDsDidSet: { identities.append($0) },
            purchasedSubscriptionsDidSet: { legacy.append($0.count) })
        try await waitUntil {
            identities.last == [] && identities.count >= 2
        }
        XCTAssertEqual(identities, [["premium"], []])
        XCTAssertEqual(legacy, [0])
    }

    func testExpiryVerificationFailureKeepsPreviouslyVerifiedAccess() async throws {
        let snapshots = ExpiringSnapshots(outcome: .failure)
        let store = Store(
            client: .init(
                loadProducts: { _ in [] },
                currentEntitlements: { _, _ in try await snapshots.next() }
            ))
        defer { store.close() }
        var identities: [Set<String>] = []
        var legacyCalled = false
        store.open(
            groupID: nil, productIDs: ["premium"],
            purchasedProductIDsDidSet: { identities.append($0) },
            purchasedSubscriptionsDidSet: { _ in legacyCalled = true })
        try await waitUntil { store.lastError != nil }
        XCTAssertEqual(identities, [["premium"]])
        XCTAssertEqual(store.purchasedProductIDs, ["premium"])
        XCTAssertFalse(legacyCalled)
    }

    func testElapsedDateDoesNotRevokeAnEntitlementStillVerifiedByStoreKit() async throws {
        let snapshots = ExpiringSnapshots(outcome: .stillEntitled)
        let store = Store(
            client: .init(
                loadProducts: { _ in [] },
                currentEntitlements: { _, _ in try await snapshots.next() }
            ))
        defer { store.close() }
        var identities: [Set<String>] = []
        store.open(
            groupID: nil, productIDs: ["premium"],
            purchasedProductIDsDidSet: { identities.append($0) },
            purchasedSubscriptionsDidSet: nil)
        try await waitUntil { identities.count == 2 }
        XCTAssertEqual(identities, [["premium"], ["premium"]])
        XCTAssertEqual(store.purchasedProductIDs, ["premium"])
    }

    func testCloseCancelsScheduledExpiryRefresh() async throws {
        let snapshots = ExpiringSnapshots()
        let store = Store(
            client: .init(
                loadProducts: { _ in
                    []
                },
                currentEntitlements: { _, _ in
                    try await snapshots.next()
                }
            ))
        store.open(groupID: nil, productIDs: ["premium"], purchasedSubscriptionsDidSet: nil)
        try await waitUntil {
            store.purchasedProductIDs == ["premium"] && !store.isLoading
        }
        store.close()
        try await Task.sleep(for: .milliseconds(200))
        let count = await snapshots.count
        XCTAssertEqual(count, 1)
    }

    private func waitUntilWaiting(_ gate: SnapshotGate) async throws {
        for _ in 0..<200 {
            if await gate.isWaiting {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Entitlement request did not start")
        throw Failure.verification
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Store state did not settle")
    }
}

private actor SnapshotGate {
    var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ExpiringSnapshots {
    enum Outcome {
        case expired
        case stillEntitled
        case failure
    }

    enum Failure: Error {
        case verification
    }

    var count = 0
    private let outcome: Outcome

    init(outcome: Outcome = .expired) {
        self.outcome = outcome
    }

    func next() throws -> StoreEntitlements {
        count += 1
        if count == 1 {
            return .init(productIDs: ["premium"], nextExpirationDate: .now.addingTimeInterval(0.03))
        }
        switch outcome {
        case .expired:
            return .init(productIDs: [])
        case .stillEntitled:
            return .init(productIDs: ["premium"], nextExpirationDate: .distantPast)
        case .failure:
            throw Failure.verification
        }
    }
}
