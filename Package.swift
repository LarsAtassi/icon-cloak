// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IconCloak",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "IconCloak", path: "Sources/IconCloak")
    ]
)
