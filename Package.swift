// swift-tools-version:6.0
//
// PROJECT_AA V1 core-proxy 正式工程骨架(单 SPM 包多 target,AA 前缀)。
// target 清单与依赖图来自 v1-mac-recharter 07 票「Swift 架构映射」裁决。
//
// 注意:本机 CLT 已损坏(module.modulemap 与 bridging.modulemap 重复定义 SwiftBridging),
// `swift build` 连本清单都解析不了 —— 本文件此刻「写而不验」,其真值化验证归 11 票(接完整 Xcode 后)。
// 骨架期的编译门禁改由 Scripts/check.sh(vfsoverlay 直编 + assert 测试)承担;11 票把引擎换成
// `swift build + swift test` 时,check.sh 的命令接口(一条命令、非零退出即失败)保持不变。

import PackageDescription

let package = Package(
    name: "PROJECT_AA",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "aa", targets: ["aa"]),
        .library(name: "AAContracts", targets: ["AAContracts"]),
        .library(name: "AAPluginSDK", targets: ["AAPluginSDK"]),
        .library(name: "AAHostRuntime", targets: ["AAHostRuntime"]),
        .library(name: "AAUISystem", targets: ["AAUISystem"]),
        .library(name: "AAHostMacOS", targets: ["AAHostMacOS"]),
        .library(name: "AAHostTestKit", targets: ["AAHostTestKit"]),
        .library(name: "PluginProxy", targets: ["PluginProxy"]),
    ],
    targets: [
        // ① 零依赖底座
        .target(name: "AAContracts"),

        // ② 只依赖 Contracts
        .target(name: "AAPluginSDK", dependencies: ["AAContracts"]),
        .target(name: "AAHostRuntime", dependencies: ["AAContracts"]),
        .target(name: "AAUISystem", dependencies: ["AAContracts"]),

        // ③ 依赖 HostRuntime 的宿主具体层 / 假件;以及插件域逻辑
        .target(name: "AAHostMacOS", dependencies: ["AAHostRuntime"]),
        .target(name: "AAHostTestKit", dependencies: ["AAHostRuntime"]),
        // 铁律:PluginProxy 只依赖 SDK / Contracts / UISystem,绝不依赖任何 Host* target。
        .target(name: "PluginProxy", dependencies: ["AAPluginSDK", "AAContracts", "AAUISystem"]),

        // ④ CLI 可执行
        .executableTarget(name: "aa", dependencies: ["AAContracts"]),
    ],
    swiftLanguageVersions: [.v5]
)
