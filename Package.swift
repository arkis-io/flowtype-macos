// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FlowType",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "FlowType", targets: ["FlowType"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(name: "FlowType"),
        .testTarget(name: "FlowTypeTests", dependencies: ["FlowType"])
    ],
    swiftLanguageModes: [.v5]
)
