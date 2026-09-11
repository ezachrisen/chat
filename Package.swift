// swift-tools-version: 6.2
import PackageDescription

// A test harness for the same native sources compiled into Chat.app. No runtime package dependency.
let package = Package(
    name: "ChatAppleServices",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ChatAppleServices", targets: ["ChatAppleServices"])],
    targets: [
        .target(name: "ChatAppleServices", path: "Chat/AppleServices",
                exclude: ["AppleServicesViews.swift", "AppleServiceTools.swift", "ReminderTools.swift", "Vendor/imsg-LICENSE.txt"],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "AppleServicesTests", dependencies: ["ChatAppleServices"], path: "Tests/AppleServices"),
        .target(name: "AgentLoopCore", path: "Chat/AgentLoop", exclude: ["RecoveringFoundationTool.swift", "ToolRecoveryPolicy.swift"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "AgentLoopTests", dependencies: ["AgentLoopCore"], path: "Tests/AgentLoop")
    ]
)
