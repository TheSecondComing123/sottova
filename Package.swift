// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sottova",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "SottovaCore"),
        .executableTarget(name: "Sottova", dependencies: ["SottovaCore"]),
        .testTarget(name: "SottovaCoreTests", dependencies: ["SottovaCore"]),
    ]
)
