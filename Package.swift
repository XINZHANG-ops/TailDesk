// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "TailDesk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TailDesk", targets: ["TailDesk"])
    ],
    targets: [
        .executableTarget(name: "TailDesk")
    ]
)
