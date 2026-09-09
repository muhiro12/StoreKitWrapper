import StoreKit
import SwiftUI

@preconcurrency
@MainActor
@Observable
public final class Store {
    public private(set) var groupID: String?
    public private(set) var productIDs: [String] = []
    public private(set) var product: Product?
    /// Verified current subscription identities, independent of product metadata.
    public private(set) var purchasedProductIDs: Set<String> = []
    public private(set) var isLoading = false
    public private(set) var lastError: (any Error)?

    private let client: StoreClient
    private var generation = UUID()
    @ObservationIgnored private var updateListenerTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    private var products: [Product] = []
    private var hasResolvedEntitlements = false
    private var purchasedSubscriptionsDidSet: (([Product]) -> Void)?
    private var purchasedProductIDsDidSet: ((Set<String>) -> Void)?

    nonisolated public init() {
        client = .live
    }

    init(client: StoreClient) {
        self.client = client
    }

    /// Starts observation. Reopening replaces the previous observation.
    /// Use the identifier callback for access decisions; the legacy Product callback
    /// waits until metadata exists for every verified subscription.
    public func open(
        groupID: String?,
        productIDs: [String],
        purchasedProductIDsDidSet: ((Set<String>) -> Void)? = nil,
        purchasedSubscriptionsDidSet: (([Product]) -> Void)?
    ) {
        close()
        self.groupID = groupID
        self.productIDs = productIDs
        self.purchasedProductIDsDidSet = purchasedProductIDsDidSet
        self.purchasedSubscriptionsDidSet = purchasedSubscriptionsDidSet
        purchasedProductIDs = []
        hasResolvedEntitlements = false
        products = []
        product = nil
        lastError = nil
        guard !productIDs.isEmpty || groupID != nil else {
            return
        }
        updateListenerTask = makeListener(observationID: generation)
        refreshTask = makeRefreshTask(observationID: generation, configuredProductIDs: productIDs)
    }

    private func makeListener(observationID: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self, !Task.isCancelled, self.generation == observationID else {
                    return
                }
                switch result {
                case .verified(let transaction):
                    guard
                        self.productIDs.contains(transaction.productID)
                            || (self.productIDs.isEmpty && self.groupID != nil
                                && transaction.subscriptionGroupID == self.groupID)
                    else {
                        continue
                    }
                    if await refreshEntitlements(generation: observationID) {
                        await transaction.finish()
                    }
                case .unverified(_, let error):
                    lastError = error
                }
            }
        }
    }

    private func makeRefreshTask(
        observationID: UUID,
        configuredProductIDs: [String]
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else {
                return
            }
            isLoading = true
            // Access must not wait for a catalog request that may fail or stall.
            _ = await refreshEntitlements(generation: observationID)
            guard self.generation == observationID, !Task.isCancelled else {
                return
            }
            do {
                let products = try await client.loadProducts(configuredProductIDs)
                guard self.generation == observationID, !Task.isCancelled else {
                    return
                }
                self.products = products
                product = products.first { configuredProductIDs.contains($0.id) }
                publishLegacyProducts()
            } catch {
                guard self.generation == observationID, !Task.isCancelled else {
                    return
                }
                lastError = error
            }
            if self.generation == observationID, !Task.isCancelled {
                isLoading = false
            }
        }
    }

    /// Stops callbacks and cancels work owned by this store.
    public func close() {
        generation = UUID()
        updateListenerTask?.cancel()
        updateListenerTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        purchasedSubscriptionsDidSet = nil
        purchasedProductIDsDidSet = nil
        isLoading = false
    }

    nonisolated public func buildSubscriptionSection() -> some View {
        StoreSection()
            .environment(self)
    }

    private func refreshEntitlements(generation: UUID) async -> Bool {
        do {
            let identifiers = try await client.currentEntitlements(Set(productIDs), groupID)
            guard self.generation == generation, !Task.isCancelled else {
                return false
            }
            hasResolvedEntitlements = true
            purchasedProductIDs = identifiers
            purchasedProductIDsDidSet?(identifiers)
            guard self.generation == generation, !Task.isCancelled else {
                return false
            }
            publishLegacyProducts()
            return self.generation == generation && !Task.isCancelled
        } catch {
            guard self.generation == generation, !Task.isCancelled else {
                return false
            }
            // An unverifiable snapshot must not revoke previously known access.
            lastError = error
            return false
        }
    }

    private func publishLegacyProducts() {
        guard hasResolvedEntitlements else {
            return
        }
        let purchasedProducts = products.filter { purchasedProductIDs.contains($0.id) }
        guard Set(purchasedProducts.map(\.id)) == purchasedProductIDs else {
            return
        }
        purchasedSubscriptionsDidSet?(purchasedProducts)
    }

    deinit {
        updateListenerTask?.cancel()
        refreshTask?.cancel()
    }
}
