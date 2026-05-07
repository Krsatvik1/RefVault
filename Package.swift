// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RefVault",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RefVault", targets: ["RefVault"]),
    ],
    targets: [
        .executableTarget(
            name: "RefVault",
            path: "Sources/RefVault",
            resources: [.copy("Resources")]
        ),
    ]
)
