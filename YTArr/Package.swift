// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "YTArr",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "YTArrCore", targets: ["YTArrCore"]),
        .executable(name: "ytarrd", targets: ["ytarrd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "YTArrCore",
            dependencies: [.product(name: "Hummingbird", package: "hummingbird")]
        ),
        .executableTarget(name: "ytarrd", dependencies: ["YTArrCore"]),
        .testTarget(name: "YTArrCoreTests", dependencies: ["YTArrCore"]),
    ]
)
