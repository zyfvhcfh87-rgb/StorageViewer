// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "StorageViewer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StorageViewer", targets: ["StorageViewer"])
    ],
    targets: [
        .target(name: "StorageViewerCore"),
        .executableTarget(
            name: "StorageViewer",
            dependencies: ["StorageViewerCore"]
        ),
        .testTarget(
            name: "StorageViewerTests",
            dependencies: ["StorageViewerCore"]
        )
    ]
)
