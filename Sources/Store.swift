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
    @ObservationIgnored private var expirationRefreshTask: Task<Void, Never>?
    private var products: [Product] = []
    private var hasResolvedEntitlements = false
    private var purchasedSubscriptionsDidSet: (([Product]) -> Void)?
    private var purchasedProductIDsDidSet: (@MainActor (Set<String>) -> Void)?

    nonisolated public init() {
        client = .live
    }

    init(client: StoreClient) {
        self.client = client
    }

    /// Starts observation using the original product callback signature.
    public func open(
        groupID: String?,
        productIDs: [String],
        purchasedSubscriptionsDidSet: (([Product]) -> Void)?
    ) {
        open(
            groupID: groupID,
            productIDs: productIDs,
            purchasedProductIDsDidSet: nil,
            purchasedSubscriptionsDidSet: purchasedSubscriptionsDidSet
        )
    }

    /// Starts observation. Reopening replaces the previous observation.
    /// The identifier callback runs on MainActor and accepts actor-isolated bridges directly.
    /// Use it for access decisions; the legacy Product callback
    /// waits until metadata exists for every verified subscription.
    public func open(
        groupID: String?,
        productIDs: [String],
        purchasedProductIDsDidSet: (@MainActor (Set<String>) -> Void)?,
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
        let client = client
        let identifiers = Set(productIDs)
        let groupID = groupID
        return Task { [weak self] in
            guard self?.isObserving(observationID) == true else {
                return
            }
            for await result in Transaction.updates {
                guard self?.isObserving(observationID) == true else {
                    return
                }
                switch result {
                case .verified(let transaction):
                    guard
                        identifiers.contains(transaction.productID)
                            || (identifiers.isEmpty && groupID != nil
                                && transaction.subscriptionGroupID == groupID)
                    else {
                        continue
                    }
                    do {
                        let purchasedIdentifiers = try await client.currentEntitlements(identifiers, groupID)
                        if self?.publishEntitlements(purchasedIdentifiers, generation: observationID) == true {
                            await transaction.finish()
                        }
                    } catch {
                        self?.record(error, generation: observationID)
                    }
                case .unverified(_, let error):
                    self?.record(error, generation: observationID)
                }
            }
        }
    }

    private func makeRefreshTask(
        observationID: UUID,
        configuredProductIDs: [String]
    ) -> Task<Void, Never> {
        let client = client
        let groupID = groupID
        return Task { [weak self] in
            guard self?.isObserving(observationID) == true else {
                return
            }
            self?.isLoading = true
            // Access must not wait for a catalog request that may fail or stall.
            do {
                let identifiers = try await client.currentEntitlements(Set(configuredProductIDs), groupID)
                _ = self?.publishEntitlements(identifiers, generation: observationID)
            } catch {
                self?.record(error, generation: observationID)
            }
            guard self?.isObserving(observationID) == true else {
                return
            }
            do {
                let products = try await client.loadProducts(configuredProductIDs)
                guard let self, isObserving(observationID) else {
                    return
                }
                self.products = products
                product = products.first { configuredProductIDs.contains($0.id) }
                publishLegacyProducts()
            } catch {
                self?.record(error, generation: observationID)
            }
            if self?.isObserving(observationID) == true {
                self?.isLoading = false
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
        expirationRefreshTask?.cancel()
        expirationRefreshTask = nil
        purchasedSubscriptionsDidSet = nil
        purchasedProductIDsDidSet = nil
        isLoading = false
    }

    nonisolated public func buildSubscriptionSection() -> some View {
        StoreSection()
            .environment(self)
    }

    private func isObserving(_ generation: UUID) -> Bool {
        self.generation == generation && !Task.isCancelled
    }

    private func publishEntitlements(_ entitlements: StoreEntitlements, generation: UUID) -> Bool {
        guard isObserving(generation) else {
            return false
        }
        hasResolvedEntitlements = true
        purchasedProductIDs = entitlements.productIDs
        purchasedProductIDsDidSet?(entitlements.productIDs)
        guard isObserving(generation) else {
            return false
        }
        publishLegacyProducts()
        guard isObserving(generation) else {
            return false
        }
        scheduleExpirationRefresh(entitlements.nextExpirationDate, generation: generation)
        return true
    }

    private func scheduleExpirationRefresh(_ expirationDate: Date?, generation: UUID) {
        expirationRefreshTask?.cancel()
        expirationRefreshTask = nil
        guard let expirationDate else {
            return
        }
        let client = client
        let identifiers = Set(productIDs)
        let groupID = groupID
        // Recheck authority at expiry; an elapsed date alone must not revoke grace-period access.
        let remaining = expirationDate.timeIntervalSinceNow
        let delay = remaining > 0 ? remaining + 0.1 : 60
        expirationRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                guard self?.isObserving(generation) == true else {
                    return
                }
                let entitlements = try await client.currentEntitlements(identifiers, groupID)
                _ = self?.publishEntitlements(entitlements, generation: generation)
            } catch {
                guard self?.isObserving(generation) == true else {
                    return
                }
                self?.record(error, generation: generation)
                self?.scheduleExpirationRefresh(.now.addingTimeInterval(60), generation: generation)
            }
        }
    }

    private func record(_ error: any Error, generation: UUID) {
        guard isObserving(generation) else {
            return
        }
        // An unverifiable snapshot must not revoke previously known access.
        lastError = error
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
        expirationRefreshTask?.cancel()
    }
}
