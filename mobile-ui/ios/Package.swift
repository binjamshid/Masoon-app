// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MasoonUI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MasoonUI", targets: ["MasoonUI"]),
        .executable(name: "MasoonUIDemo", targets: ["MasoonUIDemo"]),
    ],
    targets: [
        .target(name: "MasoonUI"),
        .executableTarget(name: "MasoonUIDemo", dependencies: ["MasoonUI"]),
    ]
)
