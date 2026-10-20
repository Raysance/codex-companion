// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "CodexCompanion",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexCompanion", targets: ["CodexCompanion"])
    ],
    targets: [
        .executableTarget(
            name: "CodexCompanion",
            path: "Sources/CodexCompanion"
        )
    ]
)
