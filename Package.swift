// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sottova",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "CEbur128"),
        .target(name: "SottovaCore", dependencies: ["CEbur128"]),
        .executableTarget(name: "Sottova", dependencies: ["SottovaCore"]),
        .testTarget(name: "SottovaCoreTests", dependencies: ["SottovaCore"]),
    ]
)
