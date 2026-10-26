// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LaunchOS",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LaunchOS", targets: ["LaunchOS"])
    ],
    targets: [
        .executableTarget(
            name: "LaunchOS",
            path: "Sources/LaunchOS",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Combine"),
                .linkedFramework("CoreData"),
                .linkedFramework("Carbon"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
