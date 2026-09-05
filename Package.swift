// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FounderHQEvents",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "FounderHQEvents", targets: ["FounderHQEvents"])],
    targets: [
        .target(name: "FounderHQEvents", resources: [.process("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "FounderHQEventsTests", dependencies: ["FounderHQEvents"]),
    ]
)
