// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClutterBuster",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClutterBuster", path: "Sources/ClutterBuster")
    ]
)
