# StoreKitWrapper

StoreKit subscription observation and a native subscription section for iOS
and macOS.

Use `Store` on the main actor. `open` replaces the previous observation;
`close` cancels owned work and stops callbacks. Use the product identifier
callback for access decisions:

```swift
store.open(
    groupID: subscriptionGroupID,
    productIDs: subscriptionProductIDs,
    purchasedProductIDsDidSet: { identifiers in
        isSubscribed = identifiers.contains(subscriptionProductID)
    },
    purchasedSubscriptionsDidSet: nil
)
```

Verified entitlement identifiers are independent of product-catalog loading.
An empty verified snapshot reports no purchased subscriptions. A verification
failure reports `lastError` without publishing a replacement snapshot.
`isLoading` covers the initial refresh; `lastError` records the latest failure
since `open` and is cleared when the store is reopened.

The existing Product callback remains available for display-oriented callers.
It is withheld when metadata is missing for any verified purchased product.
Callers that used this callback to grant access should adopt the identifier
callback. The default subscription-section presentation is unchanged.

The package tests inject catalog and entitlement responses to cover metadata
failure, absent metadata, no purchases, verification failure, and cancelled or
replaced observations, unconfigured startup, callback cancellation, and listener
ownership. StoreKit testing with a hosted app is also needed for
transaction delivery, expiry, restoration, and release-platform verification.
