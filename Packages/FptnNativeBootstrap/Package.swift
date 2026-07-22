// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FptnNativeBootstrap",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
        .tvOS(.v17)
    ],
    products: [
        .library(name: "FptnNativeBootstrap", targets: ["FptnNativeBootstrap"])
    ],
    dependencies: [
        .package(url: "https://github.com/mrmidi/FptnShared.git", exact: "0.4.4")
    ],
    targets: [
        .target(
            name: "FptnNativeBootstrap",
            dependencies: [
                .product(name: "FptnSharedCore", package: "FptnShared"),
                .product(name: "FptnServerSelection", package: "FptnShared")
            ]
        )
    ]
)
