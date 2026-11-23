// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RBMini",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "RBMini", path: "Sources/RBMini")
    ]
)
