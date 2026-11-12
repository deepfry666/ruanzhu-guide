// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// 测试只在本机保留、不进仓库：有 Tests 文件夹时才加测试目标
let hasTests = FileManager.default.fileExists(atPath: Context.packageDirectory + "/Tests/StudioCoreTests")

/// 核心逻辑（生图网关、大模型、流水线、排版、批量、导出）：不依赖界面，本机有测试时可用 `swift test`。
/// App 界面在 ../App/ 里，用 ../ManualStudio.xcodeproj 构建。
let package = Package(
    name: "ManualStudio",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "StudioCore", targets: ["StudioCore"]),
    ],
    targets: [
        .target(name: "StudioCore", path: "Sources/StudioCore"),
    ] + (hasTests ? [
        .testTarget(name: "StudioCoreTests", dependencies: ["StudioCore"], path: "Tests/StudioCoreTests"),
    ] : [])
)
