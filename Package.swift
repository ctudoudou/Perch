// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Perch", targets: ["Perch"]),
        .library(name: "PerchKit", targets: ["PerchKit"]),
    ],
    targets: [
        // Public surface a third-party plugin compiles against.
        .target(name: "PerchKit"),
        .executableTarget(
            name: "Perch",
            dependencies: ["PerchKit"],
            // Info.plist is copied into the bundle by build-app.sh, not by SwiftPM.
            // Bundled by build-app.sh into the .app, not by SwiftPM.
            exclude: ["Resources/Info.plist", "Resources/Perch.icns"]
        ),
        .testTarget(
            name: "PerchTests",
            dependencies: ["Perch", "PerchKit"]
        ),
    ]
)
