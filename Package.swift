// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ocrsearch",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "OCRSearchCore", path: "Sources/OCRSearchCore"),
        .executableTarget(name: "ocrsearch", dependencies: ["OCRSearchCore"], path: "Sources/ocrsearch"),
        .executableTarget(name: "OCRSearchApp", dependencies: ["OCRSearchCore"], path: "Sources/OCRSearchApp"),
    ]
)
