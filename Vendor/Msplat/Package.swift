// swift-tools-version: 6.0
// Vendored msplat-ios trainer, built from source by scripts/build-msplat.sh (see COMMIT). iOS only.
import PackageDescription

let package = Package(
    name: "Msplat",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "Msplat", targets: ["Msplat"]),
    ],
    targets: [
        .binaryTarget(name: "MsplatCore", path: "MsplatCore.xcframework"),
        .target(
            name: "Msplat",
            dependencies: ["MsplatCore"],
            path: "Sources/Msplat",
            resources: [
                .copy("Resources/default-ios.metallib"),
                .copy("Resources/default-iossimulator.metallib"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("Foundation"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreGraphics"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
