// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "meeting",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MeetingCore", targets: ["MeetingCore"]),
        .library(name: "MeetingWhisper", targets: ["MeetingWhisper"]),
        .library(name: "MinimalUI", targets: ["MinimalUI"]),
        .library(name: "MeetingUI", targets: ["MeetingUI"]),
        .executable(name: "MeetingApp", targets: ["MeetingApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "MeetingCore",
            resources: [.copy("Resources/diarize.py")]
        ),
        .target(
            name: "MeetingWhisper",
            dependencies: [
                "MeetingCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .target(name: "MinimalUI"),
        .target(
            name: "MeetingUI",
            dependencies: ["MeetingCore", "MinimalUI"]
        ),
        .executableTarget(
            name: "MeetingApp",
            dependencies: ["MeetingCore", "MeetingWhisper", "MeetingUI", "MinimalUI"]
        ),
        .testTarget(
            name: "MeetingCoreTests",
            dependencies: ["MeetingCore"]
        ),
    ]
)
