// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Keyla",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Keyla",
            path: "Sources/Keyla",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
