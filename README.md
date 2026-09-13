# StoreKitWrapper

StoreKit subscription observation and a native subscription section for iOS
and macOS.

Use `Store` on the main actor. `open` replaces the previous observation;
`close` cancels owned work and stops callbacks. Use the product identifier
callback for access decisions. It is typed `@MainActor`, so an existing
actor-isolated callback can be passed directly without an extra `Task`:

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

The store rechecks current entitlements at the earliest verified subscription
expiration date, even when no transaction update arrives. An elapsed date does
not itself revoke access. If StoreKit still verifies the entitlement after that
date, or verification fails during the recheck, the store retries after one
minute. Reopening and closing cancel the previous scheduled recheck.

The original three-argument `open` signature remains available, including typed
function references and the labeled method reference. `Store()` and
`buildSubscriptionSection()` remain callable from nonisolated factory code;
observe and mutate the store on the main actor.

See [Verification](Verification/README.md) for package regression tests and the
hosted StoreKit scenarios covering catalog failures, natural expiration,
refunds, observation lifecycle, and separate-process restarts.
