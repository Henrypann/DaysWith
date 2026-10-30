// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JinbaoCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "JinbaoCore", targets: ["JinbaoCore"]),
    ],
    targets: [
        .target(name: "JinbaoCore"),
        .testTarget(name: "JinbaoCoreTests", dependencies: ["JinbaoCore"]),
    ]
)
