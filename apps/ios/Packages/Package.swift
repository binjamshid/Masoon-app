// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MasoonPackages",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "MasoonDomain", targets: ["MasoonDomain"]),
        .library(name: "MasoonCurriculum", targets: ["MasoonCurriculum"]),
        .library(name: "MasoonWatchShared", targets: ["MasoonWatchShared"]),
        .executable(name: "FixtureRunner", targets: ["FixtureRunner"]),
    ],
    targets: [
        .target(name: "MasoonDomain"),
        .target(name: "MasoonCurriculum", dependencies: ["MasoonDomain"]),
        .target(name: "MasoonWatchShared", dependencies: ["MasoonDomain"]),
        .executableTarget(name: "FixtureRunner", dependencies: ["MasoonDomain", "MasoonCurriculum"]),
        .testTarget(name: "MasoonDomainTests", dependencies: ["MasoonDomain"]),
        .testTarget(
            name: "MasoonCurriculumTests",
            dependencies: ["MasoonDomain", "MasoonCurriculum"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "MasoonWatchSharedTests", dependencies: ["MasoonDomain", "MasoonWatchShared"]),
    ]
)
