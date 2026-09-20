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
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DabbiKit", targets: ["DabbiKit"]),
        .executable(name: "dabbi", targets: ["dabbi"]),
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
        .target(name: "DabbiQuery", dependencies: ["DabbiStore"]),
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
            path: "Tools/Writer"
        ),

        // MARK: Tests

        .target(name: "DabbiTestSupport", dependencies: ["FixtureKit"], path: "Tests/DabbiTestSupport"),
        .testTarget(name: "DabbiBaseTests", dependencies: ["DabbiBase"]),
        .testTarget(name: "DabbiObjCTests", dependencies: ["DabbiObjC"]),
        .testTarget(name: "DabbiSQLiteTests", dependencies: ["DabbiSQLite", "DabbiTestSupport"]),
        .testTarget(name: "DabbiModelTests", dependencies: ["DabbiModel", "DabbiTestSupport"]),
        .testTarget(name: "DabbiStoreTests", dependencies: ["DabbiStore", "DabbiTestSupport"]),
        .testTarget(name: "FixtureKitTests", dependencies: ["FixtureKit", "DabbiTestSupport"]),
    ]
)
