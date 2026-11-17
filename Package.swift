// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Membrow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Membrow", targets: ["Membrow"]),
        .library(name: "MembrowCore", targets: ["MembrowCore"]),
    ],
    targets: [
        .target(
            name: "MembrowCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Membrow",
            dependencies: ["MembrowCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "MembrowSelfTest",
            dependencies: ["MembrowCore"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
