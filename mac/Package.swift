// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhoneBridge",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "PhoneBridge", path: "Sources/PhoneBridge")]
)
