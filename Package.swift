// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZeloMCP",
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
            ],
            path: "Sources/App"
        ),
    ]
)
