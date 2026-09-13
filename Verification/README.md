# Verification

## Package tests

Run the `StoreKitWrapper` scheme's tests on macOS or an iOS Simulator.
The 17 tests cover catalog failure and missing metadata, verified empty
entitlements, verification failures, observation replacement, immediate and
in-flight cancellation, ownership, expiration rechecks, and the original
consumer API signatures. Package tests can also run with `swift test` on macOS.

## Swift 6 consumer compatibility

Run `swift build --package-path Verification/Swift6Consumer` to compile the
public API with Swift 6 checking. The fixture forwards an existing `@MainActor`
identifier callback from a nonisolated factory, matching runtime adapter
composition. Its returned bridge must be invoked on the main actor. It also
checks async forwarding from outside the main actor and existing typed and
labeled identifier observation references.

The package metadata-failure test passes an explicitly actor-isolated callback
and checks its executor during delivery.

## Hosted StoreKit scenarios

Open `StoreKitHost/StoreKitHost.xcodeproj` and select `StoreKitHost` and
`My Mac`. Close a separately opened instance of the package workspace if Xcode
reports a missing local package product. The host uses a relative local package
reference and imports `StoreKitWrapper`; it does not contain a source copy.

Run these tests as **four separate Test actions**, in this order. The purchase
is intentionally kept between actions to verify a fresh process without
recreating the transaction. Do not run the phases concurrently.

| Test | Evidence |
| --- | --- |
| `test01Purchase` | Local purchase, complete legacy metadata, catalog network failure with verified IDs retained |
| `test02RestartActive` | Existing entitlement survives process restart, including catalog failure |
| `test03Expire` | Natural expiration with failed metadata, closed observer, repurchase, reopen, and refund |
| `test04RestartInactive` | No entitlement after another process restart; test transactions are then cleared |

The expiry phase uses a ten-second renewal period and disables auto-renewal.
It checks both callbacks and `Transaction.currentEntitlements`. Expiration is
not simulated by substituting an empty response. The other phases use real-time
renewal rates. The configuration contains only synthetic local test products.

For an official command-line fallback, run from the repository root with the
selected Xcode's StoreKit testing framework compatible with the host runtime:

```sh
for test in test01Purchase test02RestartActive test03Expire test04RestartInactive; do
    xcodebuild test \
        -project Verification/StoreKitHost/StoreKitHost.xcodeproj \
        -scheme StoreKitHost \
        -destination 'platform=macOS' \
        -parallel-testing-enabled NO \
        -only-testing:StoreKitHostTests/StoreKitScenariosTests/$test || exit 1
done
```

These tests establish local StoreKit behavior and public package integration.
They do not establish production-account purchase or restoration, real-device
behavior, or an adopting app's persistence and subscription policy.
