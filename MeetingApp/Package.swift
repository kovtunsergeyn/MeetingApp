// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingApp",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "MeetingApp",
            path: "Sources/MeetingApp"
        )
    ]
)
