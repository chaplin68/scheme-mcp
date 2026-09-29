// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "scheme-mcp",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "scheme-mcp", targets: ["SchemeMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "SchemeMCP",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SchemeMCPTests",
            dependencies: ["SchemeMCP"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
