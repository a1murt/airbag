// swift-tools-version: 6.0
import PackageDescription

// Note: the app's executable product is "AirbagApp" (not "Airbag") because the CLI is "airbag" and
// both land in .build/<config>/ on a case-insensitive file system. Scripts/build-app.sh renames it.
let package = Package(
    name: "Airbag",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AirbagCore", targets: ["AirbagCore"]),
        .executable(name: "airbag", targets: ["airbag"]),
        .executable(name: "AirbagApp", targets: ["AirbagApp"]),
    ],
    targets: [
        .target(
            name: "AirbagCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "airbag", dependencies: ["AirbagCore"]),
        .executableTarget(
            name: "AirbagApp",
            dependencies: ["AirbagCore"],
            exclude: ["Resources"] // copied into Airbag.app/Contents/Resources by Scripts/build-app.sh
        ),
        .testTarget(
            name: "AirbagCoreTests",
            dependencies: ["AirbagCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
