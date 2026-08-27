// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumeMetricsKit",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
    ],
    products: [
        .library(name: "LumeMetricsKit", targets: ["LumeMetricsKit"]),
    ],
    targets: [
        .target(
            name: "LumeMetricsKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LumeMetricsKitTests",
            dependencies: ["LumeMetricsKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
