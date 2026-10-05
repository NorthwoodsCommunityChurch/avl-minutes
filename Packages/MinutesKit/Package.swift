// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MinutesKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MinutesKit", targets: ["MinutesKit"]),
        .library(name: "MinutesMCP", targets: ["MinutesMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .target(name: "MinutesKit"),
        .target(
            name: "MinutesMCP",
            dependencies: ["MinutesKit", .product(name: "MCP", package: "swift-sdk")]
        ),
        .testTarget(name: "MinutesKitTests", dependencies: ["MinutesKit"]),
        .testTarget(name: "MinutesMCPTests", dependencies: ["MinutesMCP", "MinutesKit"]),
    ]
)
