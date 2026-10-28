// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sottova",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SottovaCore"),
        .executableTarget(name: "Sottova", dependencies: ["SottovaCore"]),
    ]
)
