import StoreKit

struct StoreClient: Sendable {
    var loadProducts: @Sendable ([String]) async throws -> [Product]
    var currentEntitlements: @Sendable (Set<String>, String?) async throws -> Set<String>

    static let live = Self(
        loadProducts: { identifiers in
            try await Product.products(for: identifiers)
        },
        currentEntitlements: { identifiers, groupID in
            var purchasedIdentifiers = Set<String>()
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
                    || (identifiers.isEmpty && groupID != nil && transaction.subscriptionGroupID == groupID) {
                    purchasedIdentifiers.insert(transaction.productID)
                }
            }
            return purchasedIdentifiers
        }
    )
}
