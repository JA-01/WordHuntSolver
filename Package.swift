// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WordHuntSolver",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WordHuntCore", targets: ["WordHuntCore"]),
        .library(name: "WordHuntMac", targets: ["WordHuntMac"]),
        .executable(name: "WordHuntSolver", targets: ["WordHuntSolver"])
    ],
    targets: [
        .target(name: "WordHuntCore", resources: [.process("Resources")]),
        .target(name: "WordHuntMac", dependencies: ["WordHuntCore"], resources: [.process("Resources")]),
        .executableTarget(name: "WordHuntSolver", dependencies: ["WordHuntCore", "WordHuntMac"]),
        .testTarget(name: "WordHuntCoreTests", dependencies: ["WordHuntCore"]),
        .testTarget(name: "WordHuntMacTests", dependencies: ["WordHuntMac", "WordHuntCore"],
                    resources: [.copy("Fixtures")])
    ]
)
