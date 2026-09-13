import Foundation
import StoreKit
import StoreKitTest
import StoreKitWrapper
import XCTest

enum StoreKitScenarios {
    private static let productID = "test.premium.monthly"
    private static let groupID = "584A72BC"

    private struct Failure: Error {
        let message: String
    }

    @MainActor
    static func run(_ phase: String) async throws {
        let configurationURL = try XCTUnwrap(
            Bundle(for: StoreKitScenariosTests.self).url(forResource: "Products", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: configurationURL)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.timeRate = .realTime
        switch phase {
        case "purchase":
            session.clearTransactions()
            _ = try await session.buyProduct(identifier: productID)
            let store = Store()
            defer {
                store.close()
            }
            var products: Set<String>?
            store.open(groupID: groupID, productIDs: [productID]) { purchased in
                products = Set(purchased.map(\.id))
            }
            try await wait("Legacy callback with complete metadata") {
                products == [productID] && !store.isLoading
            }
            store.close()
            try await verifyCatalogFailure(session)
        case "restart-active":
            try require(try await currentIDs() == [productID], "Purchase survives process restart")
            try await verifyCatalogFailure(session)
        case "expire":
            try await verifyExpiryAndClosure(session)
        case "restart-inactive":
            let store = Store()
            defer {
                store.close()
            }
            var identities: Set<String>?
            var legacy: Set<String>?
            store.open(
                groupID: groupID,
                productIDs: [productID],
                purchasedProductIDsDidSet: { identities = $0 },
                purchasedSubscriptionsDidSet: { legacy = Set($0.map(\.id)) }
            )
            try await wait("Inactive state survives process restart") {
                identities == [] && legacy == [] && !store.isLoading
            }
            try require(try await currentIDs().isEmpty, "StoreKit confirms no current entitlement")
            session.clearTransactions()
        default:
            throw Failure(message: "Unknown verification phase")
        }
        session.resetToDefaultState()
        print("PASS phase: \(phase)")
    }

    @MainActor
    private static func verifyCatalogFailure(_ session: SKTestSession) async throws {
        try await session.setSimulatedError(
            .generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        let store = Store()
        defer {
            store.close()
        }
        var identities: Set<String>?
        var legacyCalled = false
        store.open(
            groupID: groupID,
            productIDs: [productID],
            purchasedProductIDsDidSet: { identities = $0 },
            purchasedSubscriptionsDidSet: { _ in legacyCalled = true }
        )
        try await wait("Catalog network failure preserves purchased identity") {
            identities == [productID] && store.lastError != nil && !store.isLoading
        }
        try require(store.purchasedProductIDs == [productID] && !legacyCalled, "No false legacy revocation")
        try require(try await currentIDs() == [productID], "StoreKit still verifies the entitlement")
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
    }

    @MainActor
    private static func verifyExpiryAndClosure(_ session: SKTestSession) async throws {
        session.clearTransactions()
        session.timeRate = .oneRenewalEveryTenSeconds
        let expiringTransaction = try await session.buyProduct(identifier: productID)
        try session.disableAutoRenewForTransaction(identifier: UInt(expiringTransaction.id))
        try await session.setSimulatedError(
            .generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        let store = Store()
        defer {
            store.close()
        }
        var identities: [Set<String>] = []
        var legacy: [Set<String>] = []
        store.open(
            groupID: groupID,
            productIDs: [productID],
            purchasedProductIDsDidSet: { identities.append($0) },
            purchasedSubscriptionsDidSet: { legacy.append(Set($0.map(\.id))) }
        )
        try await wait("Active before natural expiry with failed catalog") {
            identities.last == [productID] && !store.isLoading
        }
        try await wait("Natural expiry publishes inactive without a transaction update") {
            identities.last == [] && legacy.last == []
        }
        try require(try await currentIDs().isEmpty, "Expired subscription leaves currentEntitlements")
        store.close()
        let closedIdentityCount = identities.count
        let closedLegacyCount = legacy.count
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        session.timeRate = .realTime
        let transaction = try await session.buyProduct(identifier: productID)
        try await Task.sleep(for: .milliseconds(300))
        try require(
            identities.count == closedIdentityCount && legacy.count == closedLegacyCount,
            "Closed observer receives no purchase callbacks")
        try require(try await currentIDs() == [productID], "Repurchase exists while observer is closed")
        store.open(
            groupID: groupID,
            productIDs: [productID],
            purchasedProductIDsDidSet: { identities.append($0) },
            purchasedSubscriptionsDidSet: { legacy.append(Set($0.map(\.id))) }
        )
        try await wait("Reopened observer recovers the purchase and product metadata") {
            identities.last == [productID] && legacy.last == [productID] && !store.isLoading
        }
        try session.refundTransaction(identifier: UInt(transaction.id))
        try await wait("Refund revokes identity and legacy products") {
            identities.last == [] && legacy.last == []
        }
        try require(try await currentIDs().isEmpty, "Refunded subscription leaves currentEntitlements")
    }

    private static func currentIDs() async throws -> Set<String> {
        var identifiers = Set<String>()
        for await result in Transaction.currentEntitlements {
            let transaction = try result.payloadValue
            identifiers.insert(transaction.productID)
        }
        return identifiers
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw Failure(message: message)
        }
        print("PASS: \(message)")
    }

    @MainActor
    private static func wait(_ message: String, until condition: () -> Bool) async throws {
        for _ in 0..<1500 {
            if condition() {
                print("PASS: \(message)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(message: message)
    }
}

@MainActor
final class StoreKitScenariosTests: XCTestCase {
    func test01Purchase() async throws {
        try await StoreKitScenarios.run("purchase")
    }

    func test02RestartActive() async throws {
        try await StoreKitScenarios.run("restart-active")
    }

    func test03Expire() async throws {
        try await StoreKitScenarios.run("expire")
    }

    func test04RestartInactive() async throws {
        try await StoreKitScenarios.run("restart-inactive")
    }
}
