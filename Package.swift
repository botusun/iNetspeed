// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "iNetspeed",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "iNetspeed", targets: ["iNetspeed"])
    ],
    targets: [
        .executableTarget(
            name: "iNetspeed"
        )
    ]
)
