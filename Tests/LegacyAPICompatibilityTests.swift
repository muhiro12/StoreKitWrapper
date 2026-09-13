import StoreKit
import StoreKitWrapper
import SwiftUI
import XCTest

@MainActor
func legacyCallSites(_ store: Store) {
    let open: (String?, [String], (([Product]) -> Void)?) -> Void = store.open
    open(nil, [], nil)
    let namedOpen = store.open(groupID:productIDs:purchasedSubscriptionsDidSet:)
    namedOpen(nil, [], nil)
    store.open(groupID: nil, productIDs: []) { products in
        _ = products.map(\.id)
    }
}

func nonisolatedFactory() -> Store {
    Store()
}

func nonisolatedSection(_ store: Store) -> some View {
    store.buildSubscriptionSection()
}

@MainActor
final class LegacyAPICompatibilityTests: XCTestCase {
    func testOriginalSignaturesRemainCallable() {
        let store = nonisolatedFactory()
        defer {
            store.close()
        }
        legacyCallSites(store)
        _ = nonisolatedSection(store)
        XCTAssertNil(store.groupID)
        XCTAssertEqual(store.productIDs, [])
        XCTAssertNil(store.product)
    }
}
