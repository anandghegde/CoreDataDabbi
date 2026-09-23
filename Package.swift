// swift-tools-version: 6.0
import PackageDescription

// Layering (docs/ARCHITECTURE.md §3.1): dependencies only point down this list.
//
//   DabbiKit (umbrella)
//   DabbiProject · DabbiLocator · DabbiSnapshots · DabbiExchange · DabbiDiagnostics · DabbiTracking · DabbiQuery
//   DabbiStore
//   DabbiModel · DabbiContent
//   DabbiSQLite
//   DabbiObjC · DabbiBase

let package = Package(
    name: "CoreDataDabbi",
    // iOS is here for one product only: `FixtureKit` is linked into the simulator writer app (M2-11,
    // `Tools/Writer/iOS`), which is what proves the tracker end to end against a real app in a real container.
    // That app is built by Xcode and excluded from the `Writer` target below, so nothing this package builds
    // imports UIKit, and no part of the engine is built for iOS at all.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DabbiKit", targets: ["DabbiKit"]),
        .executable(name: "dabbi", targets: ["dabbi"]),
        // For the app's hosted tests, which are built by Xcode and can only link products. It depends on none
        // of the engine, so linking it next to the app duplicates nothing.
        .library(name: "FixtureKit", targets: ["FixtureKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        // MARK: Engine

        .target(name: "DabbiObjC"),
        .target(name: "DabbiBase", dependencies: ["DabbiObjC"]),
        .target(name: "CDabbiSQLite", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "DabbiSQLite", dependencies: ["DabbiBase", "CDabbiSQLite"]),
        .target(name: "DabbiModel", dependencies: ["DabbiBase", "DabbiSQLite"]),
        .target(name: "DabbiContent", dependencies: ["DabbiBase"]),
        .target(name: "DabbiStore", dependencies: ["DabbiBase", "DabbiModel"]),
        .target(name: "DabbiQuery", dependencies: ["DabbiModel", "DabbiStore"]),
        .target(name: "DabbiTracking", dependencies: ["DabbiStore", "DabbiSQLite"]),
        .target(name: "DabbiLocator", dependencies: ["DabbiModel", "DabbiSQLite"]),
        .target(name: "DabbiExchange", dependencies: ["DabbiStore", "DabbiQuery"]),
        .target(name: "DabbiSnapshots", dependencies: ["DabbiStore", "DabbiSQLite"]),
        .target(name: "DabbiDiagnostics", dependencies: ["DabbiStore", "DabbiSQLite"]),
        .target(name: "DabbiProject", dependencies: ["DabbiBase"]),
        .target(
            name: "DabbiKit",
            dependencies: [
                "DabbiBase", "DabbiSQLite", "DabbiModel", "DabbiContent", "DabbiStore", "DabbiQuery",
                "DabbiTracking", "DabbiLocator", "DabbiExchange", "DabbiSnapshots", "DabbiDiagnostics",
                "DabbiProject",
            ]
        ),

        // MARK: Front ends

        .executableTarget(
            name: "dabbi",
            dependencies: [
                "DabbiKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // MARK: Tools

        .target(name: "FixtureKit", path: "Tools/FixtureKit"),
        .executableTarget(
            name: "FixtureGen",
            dependencies: [
                "FixtureKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tools/FixtureGen"
        ),
        .executableTarget(
            name: "Writer",
            dependencies: [
                "FixtureKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tools/Writer",
            // The writer's other half is an iOS app (M2-11) built by Xcode, which is the only thing with a
            // simulator SDK to build it against. It sits here because it runs the same script; it is not part
            // of this executable.
            exclude: ["iOS"]
        ),

        // Mutation fuzzing of the content decoders (ARCHITECTURE.md §6.8). The kit is shared with the test suite,
        // which runs a short, deterministic campaign on every build.
        .target(name: "ContentFuzzKit", dependencies: ["DabbiContent"], path: "Tools/ContentFuzzKit"),
        .executableTarget(
            name: "ContentFuzz",
            dependencies: [
                "ContentFuzzKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tools/ContentFuzz"
        ),

        // MARK: Tests

        .target(
            name: "DabbiTestSupport", dependencies: ["FixtureKit", "DabbiLocator"], path: "Tests/DabbiTestSupport"),
        .testTarget(name: "DabbiBaseTests", dependencies: ["DabbiBase"]),
        .testTarget(name: "DabbiObjCTests", dependencies: ["DabbiObjC"]),
        .testTarget(name: "DabbiSQLiteTests", dependencies: ["DabbiSQLite", "DabbiTestSupport"]),
        .testTarget(name: "DabbiModelTests", dependencies: ["DabbiModel", "DabbiTestSupport"]),
        .testTarget(name: "DabbiStoreTests", dependencies: ["DabbiStore", "DabbiTestSupport"]),
        .testTarget(name: "DabbiQueryTests", dependencies: ["DabbiQuery", "DabbiTestSupport"]),
        .testTarget(
            name: "DabbiTrackingTests",
            dependencies: ["DabbiTracking", "DabbiStore", "DabbiModel", "DabbiSQLite", "DabbiTestSupport"]),
        .testTarget(name: "DabbiContentTests", dependencies: ["DabbiContent", "ContentFuzzKit"]),
        .testTarget(name: "DabbiProjectTests", dependencies: ["DabbiProject"]),
        .testTarget(name: "DabbiLocatorTests", dependencies: ["DabbiLocator", "DabbiTestSupport"]),
        .testTarget(name: "DabbiKitTests", dependencies: ["DabbiKit", "DabbiTestSupport"]),
        .testTarget(name: "FixtureKitTests", dependencies: ["FixtureKit", "DabbiTestSupport"]),
    ]
)
