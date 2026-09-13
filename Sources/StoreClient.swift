import StoreKit

struct StoreClient: Sendable {
    var loadProducts: @Sendable ([String]) async throws -> [Product]
    var currentEntitlements: @Sendable (Set<String>, String?) async throws -> StoreEntitlements

    static let live = Self(
        loadProducts: { identifiers in
            try await Product.products(for: identifiers)
        },
        currentEntitlements: { identifiers, groupID in
            var purchasedIdentifiers = Set<String>()
            var nextExpirationDate: Date?
            for await result in Transaction.currentEntitlements {
                let transaction: Transaction
                switch result {
                case .verified(let verified):
                    transaction = verified
                case .unverified(_, let error):
                    throw error
                }
                guard transaction.productType == .autoRenewable else {
                    continue
                }
                if identifiers.contains(transaction.productID)
                    || (identifiers.isEmpty && groupID != nil && transaction.subscriptionGroupID == groupID)
                {
                    purchasedIdentifiers.insert(transaction.productID)
                    if let expirationDate = transaction.expirationDate {
                        nextExpirationDate = min(nextExpirationDate ?? expirationDate, expirationDate)
                    }
                }
            }
            return .init(productIDs: purchasedIdentifiers, nextExpirationDate: nextExpirationDate)
        }
    )
}

struct StoreEntitlements: Sendable {
    var productIDs: Set<String>
    var nextExpirationDate: Date?
}
