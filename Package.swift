// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StoreKitWrapper",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "StoreKitWrapper",
            targets: ["StoreKitWrapper"]
        )
    ],
    targets: [
        .target(name: "StoreKitWrapper")
    ]
)
