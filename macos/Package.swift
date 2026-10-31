// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MusicShareMVP",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MusicShareMVP", targets: ["MusicShareMVP"])
    ],
    dependencies: [
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "4.0.4")
    ],
    targets: [
        .executableTarget(
            name: "MusicShareMVP",
            dependencies: [
                .product(name: "Starscream", package: "Starscream")
            ],
            path: "Sources/MusicShareMVP"
        )
    ]
)
