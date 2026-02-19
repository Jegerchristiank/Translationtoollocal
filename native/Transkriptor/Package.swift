// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TranskriptorNative",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TranskriptorApp", targets: ["AppUI"]),
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "Pipeline", targets: ["Pipeline"]),
        .library(name: "Export", targets: ["Export"]),
        .library(name: "SecurityKit", targets: ["SecurityKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0")
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "SecurityKit"),
        .target(
            name: "Storage",
            dependencies: [
                "Domain",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "Pipeline",
            dependencies: [
                "Domain",
                "Storage",
                "SecurityKit"
            ]
        ),
        .target(
            name: "Export",
            dependencies: [
                "Domain"
            ]
        ),
        .executableTarget(
            name: "AppUI",
            dependencies: [
                "Domain",
                "Storage",
                "Pipeline",
                "Export",
                "SecurityKit"
            ]
        ),
        .testTarget(
            name: "ExportTests",
            dependencies: ["Export", "Domain"]
        ),
        .testTarget(
            name: "PipelineTests",
            dependencies: ["Pipeline", "Domain"]
        ),
        .testTarget(
            name: "AppUITests",
            dependencies: ["AppUI"]
        )
    ]
)
