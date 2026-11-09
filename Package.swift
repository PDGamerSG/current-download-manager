// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Current",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CurrentCore", targets: ["CurrentCore"]),
        .executable(name: "Current", targets: ["CurrentApp"]),
        .executable(name: "currentctl", targets: ["CurrentCLI"])
    ],
    targets: [
        .target(name: "CurrentCore"),
        .executableTarget(name: "CurrentApp", dependencies: ["CurrentCore"]),
        .executableTarget(name: "CurrentCLI", dependencies: ["CurrentCore"]),
        .executableTarget(name: "CurrentCoreTests", dependencies: ["CurrentCore"], path: "tests/CurrentCoreTests")
    ]
)
