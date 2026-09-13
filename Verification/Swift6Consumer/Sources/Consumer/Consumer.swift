import StoreKit
import StoreKitWrapper

// The factory is nonisolated; the returned bridge preserves MainActor isolation.
func makeStoreBridge(store: Store) -> @MainActor (@escaping @MainActor (Set<String>) -> Void) -> Void {
    let open:
        @MainActor (
            String?, [String], (@MainActor (Set<String>) -> Void)?, (([Product]) -> Void)?
        ) -> Void = store.open
    return { callback in
        open(
            nil,
            ["premium"],
            callback,
            nil
        )
    }
}

@MainActor
func existingIdentifierSignatures(store: Store) {
    let open: (String?, [String], ((Set<String>) -> Void)?, (([Product]) -> Void)?) -> Void = store.open
    open(nil, [], nil, nil)
    let namedOpen = store.open(groupID:productIDs:purchasedProductIDsDidSet:purchasedSubscriptionsDidSet:)
    namedOpen(nil, [], nil, nil)
}

func forwardPurchasedIdentifiers(
    store: Store,
    callback: @escaping @MainActor (Set<String>) -> Void
) async {
    await store.open(
        groupID: nil,
        productIDs: ["premium"],
        purchasedProductIDsDidSet: callback,
        purchasedSubscriptionsDidSet: nil
    )
}
