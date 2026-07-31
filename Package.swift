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
        // agent-delegation 07:委托试驾 CLI(与 `aa` 各自独立,互不影响 —— 守并行红线)。
        .executable(name: "aa-agent", targets: ["aa-agent"]),
        .library(name: "AAContracts", targets: ["AAContracts"]),
        .library(name: "AAPluginSDK", targets: ["AAPluginSDK"]),
        .library(name: "AAHostRuntime", targets: ["AAHostRuntime"]),
        .library(name: "AAUISystem", targets: ["AAUISystem"]),
        .library(name: "AAHostMacOS", targets: ["AAHostMacOS"]),
        .library(name: "AAHostTestKit", targets: ["AAHostTestKit"]),
        .library(name: "PluginProxy", targets: ["PluginProxy"]),
        // agent-delegation 模块(「宿主调用本地 agent」适配层)——与 v1-core-proxy 的 16 票并行落地。
        .library(name: "AAAgentCore", targets: ["AAAgentCore"]),
        .library(name: "AAAgentSystem", targets: ["AAAgentSystem"]),
        .library(name: "AAAgentTestKit", targets: ["AAAgentTestKit"]),
    ],
    targets: [
        // ① 零依赖底座
        .target(name: "AAContracts"),

        // ② 只依赖 Contracts
        .target(name: "AAPluginSDK", dependencies: ["AAContracts"]),
        .target(name: "AAHostRuntime", dependencies: ["AAContracts"]),
        .target(name: "AAUISystem", dependencies: ["AAContracts"]),
        // agent-delegation:AAAgentCore 是「宿主调用本地 agent」适配层的纯逻辑地基,
        //   **只依赖 AAContracts**(不依赖 SDK / Host*),故与 v1-core-proxy 的 16 票并行落地、互不踩施工面。
        //   铁律与 PluginProxy 同级:check.sh grep 强制不 import 任何 Host*。
        .target(name: "AAAgentCore", dependencies: ["AAContracts"]),
        // agent-delegation 06:AAAgentSystem 是 AgentPort 的**生产实现**所在的薄桥接层(碰 posix_spawn/管道/信号)。
        //   刻意不进 AAAgentCore(纯逻辑核零系统调用),也刻意不进 AAHostMacOS(守与 v1-core-proxy 的并行红线)。
        //   check.sh 断言组 3e grep 强制它不 import 任何 Host*。
        //   依赖**只有 AAAgentCore**:全部源码(SystemAgentPort.swift)只 import Foundation/Darwin/AAAgentCore,
        //   一行 AAContracts 都没有 —— 按本文件下面「依赖边须与源码实际 import 一一对应」的口径,不挂空头依赖。
        .target(name: "AAAgentSystem", dependencies: ["AAAgentCore"]),

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
        .target(
            name: "PluginProxy",
            dependencies: ["AAPluginSDK", "AAContracts", "AAUISystem"],
            resources: [.copy("Resources")]
        ),
        // agent-delegation:AAAgentTestKit 是 AAAgentCore 的**独立**测试基建(FakeAgentPort + 纯逻辑一致性测试)。
        //   刻意不并入 AAHostTestKit——后者正被 v1-core-proxy 施工,合用会制造合并冲突。只依赖 AAAgentCore + Contracts。
        //   06 票追加 AAAgentSystem:真实现的一致性测试(真进程/进程组/反孤儿)要驱动生产端口本身。
        .target(name: "AAAgentTestKit", dependencies: ["AAAgentCore", "AAAgentSystem", "AAContracts"]),

        // ④ CLI 可执行
        .executableTarget(name: "aa", dependencies: ["AAContracts"]),
        // agent-delegation 07:委托试驾 CLI(`run|status|cancel|list|prune`)。
        //   依赖边与源码实际 import 一一对应:AAAgentCore(组装 / 状态机 / 归一化 / 看门狗)+
        //   AAAgentSystem(真进程端口与真文件系统端口)+ AAContracts(退出码单一来源)。
        //   **绝不依赖 AAHostMacOS / AAHostRuntime / PluginProxy**:它是 agent-delegation 模块自己的入口,
        //   与 v1-core-proxy 的 16 票并行落地、互不踩施工面(现有 `aa` 一个字节都不动)。
        .executableTarget(name: "aa-agent", dependencies: ["AAContracts", "AAAgentCore", "AAAgentSystem"]),
    ],
    swiftLanguageVersions: [.v5]
)
