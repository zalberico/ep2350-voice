// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "fxmic",
    platforms: [.macOS("26.0")],
    targets: [
        .testTarget(name: "VoiceTurnTests", dependencies: ["FXMicCore"], path: "Tests/VoiceTurnTests"),
        .target(name: "FXMicCore", path: "Sources/FXMicCore"),
        .executableTarget(name: "fxmic-cal", dependencies: ["FXMicCore"], path: "Sources/fxmic-cal"),
        .executableTarget(
            name: "FXMic",
            dependencies: ["FXMicCore"],
            path: "Sources/FXMic",
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("ServiceManagement")]),
    ]
)
