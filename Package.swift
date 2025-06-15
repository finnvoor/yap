// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "yap",
    platforms: [.macOS("26")],
    products: [
        .executable(name: "yap", targets: ["yap"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/tuist/Noora.git", from: "0.40.1")
    ],
    targets: [
        .executableTarget(
            name: "yap",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Noora", package: "Noora")
            ]
        )
    ]
)
