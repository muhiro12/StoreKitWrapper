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
                    identifiers
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
                    identifiers
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
                    []
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
                    return identifiers
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
                    return identifiers
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
        let store = Store(client: .init(
            loadProducts: { _ in
                XCTFail("Unconfigured store requested product metadata")
                return []
            },
            currentEntitlements: { _, _ in
                XCTFail("Unconfigured store requested entitlements")
                return []
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
        let store = Store(client: .init(
            loadProducts: { _ in
                []
            },
            currentEntitlements: { _, _ in
                []
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
        var store: Store? = Store(client: .init(
            loadProducts: { _ in
                []
            },
            currentEntitlements: { _, _ in
                []
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
