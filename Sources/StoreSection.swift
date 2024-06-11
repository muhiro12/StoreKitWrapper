//
//  StoreSection.swift
//
//
//  Created by Hiromu Nakano on 2022/01/31.
//  Copyright © 2022 Hiromu Nakano. All rights reserved.
//

import StoreKit
import SwiftUI

struct StoreSection {
    @Environment(Store.self)
    private var store
}

extension StoreSection: View {
    var body: some View {
        Section(content: {
            SubscriptionStoreView(groupID: store.groupID)
                .storeButton(.visible, for: .policies)
                .storeButton(.visible, for: .restorePurchases)
                .storeButton(.hidden, for: .cancellation)
                .subscriptionStorePolicyDestination(
                    url: .init(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!,
                    for: .termsOfService
                )
                .fixedSize(horizontal: false, vertical: true)
        }, footer: {
            Text(store.product?.description ?? "")
        })
    }
}
