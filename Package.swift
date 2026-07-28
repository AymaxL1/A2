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
        // 依赖边须与源码实际 import 一一对应(两个 target 都同时 import AAHostRuntime 与 AAContracts)。
        //
        // @main 债务口径(重要):AAHostMacOS 的终态是「库」——07 票架构映射定它为 Host Port 的 macOS 实现,
        //   spec 定 GUI 宿主是 XcodeGen app 壳(LSUIElement;SPM 可执行产不出 .app bundle)。
        //   现阶段 Sources/AAHostMacOS/HostApp.swift 里塞的 @main 只是 vfsoverlay 过桥用(check.sh 单独把它编成可执行冒烟);
        //   正确终态归 12 票:把 @main 移进 XcodeGen app 壳、AppDelegate 转 public,本 target 保持库不变。
        //   因此这里保持 .target(库),不要改成 .executableTarget。
        // 06 票:宿主 V1 内封栈——AAHostMacOS 装配 PluginProxy(注入真 Port),故新增 AAPluginSDK + PluginProxy 依赖。
        //   注意方向:宿主依赖插件(合法);铁律只禁「插件依赖 Host*」,不禁「Host 依赖插件」。
        .target(name: "AAHostMacOS", dependencies: ["AAHostRuntime", "AAContracts", "AAPluginSDK", "PluginProxy"]),
        // 06 票:AAHostTestKit 加 Port 假件 + 插件域逻辑纯逻辑测试,故新增 AAPluginSDK + PluginProxy 依赖(同样是「测试基建依赖插件」,合法)。
        .target(name: "AAHostTestKit", dependencies: ["AAHostRuntime", "AAContracts", "AAPluginSDK", "PluginProxy"]),
        // 铁律:PluginProxy 只依赖 SDK / Contracts / UISystem,绝不依赖任何 Host* target。
        //   06 票新增的 ProcessPort/HTTPPort **协议**定在 AAPluginSDK(插件只依赖 SDK),真实现/假件在 Host* 侧——边界不破。
        .target(name: "PluginProxy", dependencies: ["AAPluginSDK", "AAContracts", "AAUISystem"]),

        // ④ CLI 可执行
        .executableTarget(name: "aa", dependencies: ["AAContracts"]),
    ],
    swiftLanguageVersions: [.v5]
)
