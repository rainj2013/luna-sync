// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LunaSync",
    platforms: [.iOS("18.0"), .macOS(.v13)],
    products: [
        .library(name: "LunaSyncCore", targets: ["LunaSyncCore"]),
        .library(name: "LunaSyncPhotoKit", targets: ["LunaSyncPhotoKit"])
    ],
    targets: [
        .target(name: "LunaSyncCore"),
        .target(name: "LunaSyncPhotoKit", dependencies: ["LunaSyncCore"],
                linkerSettings: [.linkedLibrary("sqlite3", .when(platforms: [.iOS]))]),
        .testTarget(name: "LunaSyncCoreTests", dependencies: ["LunaSyncCore"])
    ]
)
