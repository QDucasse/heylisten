// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HeyListen",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "HeyListen",
            path: "Sources/HeyListen",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
