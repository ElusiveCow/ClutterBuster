// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CoverSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CoverSpike", path: "Sources/CoverSpike")
    ]
)
