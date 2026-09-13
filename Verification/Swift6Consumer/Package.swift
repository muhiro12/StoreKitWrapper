// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Swift6Consumer",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [.package(name: "StoreKitWrapper", path: "../..")],
    targets: [
        .target(
            name: "Consumer",
            dependencies: [.product(name: "StoreKitWrapper", package: "StoreKitWrapper")]
        )
    ]
)
