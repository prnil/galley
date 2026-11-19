// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Galley",
    platforms: [.macOS("14.0")],
    targets: [
        .executableTarget(name: "Galley", path: "Sources/Galley")
    ]
)
