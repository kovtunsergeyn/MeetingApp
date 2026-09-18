// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingApp",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Ядро без интерфейса: типы и чистые функции. Отдельная библиотека
        // нужна ради тестов — исполняемую цель импортировать нельзя.
        .target(
            name: "MeetingCore",
            path: "Sources/MeetingCore"
        ),
        .executableTarget(
            name: "MeetingApp",
            dependencies: ["MeetingCore"],
            path: "Sources/MeetingApp"
        ),
        // Тесты — тоже исполняемая цель: XCTest без Xcode недоступен,
        // а `swift run MeetingAppTests` работает на голых Command Line Tools.
        .executableTarget(
            name: "MeetingAppTests",
            dependencies: ["MeetingCore"],
            path: "Sources/MeetingAppTests"
        )
    ]
)
