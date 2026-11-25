// swift-tools-version:5.9
// Veyra for macOS — Apple Silicon port (VideoToolbox / ScreenCaptureKit / AVFoundation / Core Image)
import PackageDescription

let package = Package(
    name: "VeyraMac",
    platforms: [.macOS("26.0")],
    products: [.library(name: "EnhanceKit", targets: ["EnhanceKit"])],
    targets: [
        .target(name: "EnhanceKit", path: "Sources/EnhanceKit"),
        .executableTarget(name: "VeyraMac", dependencies: ["EnhanceKit"], path: "Sources/VeyraMac"),
        .executableTarget(name: "MakeTestVideo", path: "Sources/MakeTestVideo"),
    ]
)
