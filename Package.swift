// swift-tools-version:6.0
//
// PROJECT_AA V1 core-proxy 正式工程骨架(单 SPM 包多 target,AA 前缀)。
// target 清单与依赖图来自 v1-mac-recharter 07 票「Swift 架构映射」裁决。
//
// 状态(11 票已真值化,2026-08-04):本清单不再是「写而不验」——`Scripts/check.sh` 的编译引擎就是
// `swift build` + `swift test`,本文件每次跑门禁都被真实解析与构建。**不需要 Xcode.app**;
// 需要的是一份 SPM 可用的工具链(CLT 自带的 libPackageDescription 与其接口错配,用不了):
//   ~/Library/Developer/Toolchains/swift-latest.xctoolchain —— bootstrap.sh 会现场探测并挑出可用的那个。
// check.sh 的命令接口(一条命令、非零退出即失败)在换引擎前后保持不变。

import PackageDescription

let package = Package(
    name: "PROJECT_AA",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "aa", targets: ["aa"]),
        // agent-delegation 07:委托试驾 CLI(与 `aa` 各自独立,互不影响 —— 守并行红线)。
        .executable(name: "aa-agent", targets: ["aa-agent"]),
        // 11 票:GUI 宿主的薄可执行壳(@main 从 AAHostMacOS 库里搬出来的落点)。
        //   是产品(不是门禁内部工具):12 票已把它打进 .app bundle(LSUIElement),
        //   由 Scripts/build-app.sh 手工组 bundle + ad-hoc 签名产出(不走 XcodeGen —— 本机无 Xcode)。
        .executable(name: "aahost", targets: ["aahost"]),
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
        // @main 债务口径(11 票已结清):AAHostMacOS 的终态是「库」——07 票架构映射定它为 Host Port 的 macOS 实现,
        //   spec 定 GUI 宿主是 LSUIElement 菜单栏 app 壳(SPM 可执行本身产不出 .app bundle)。
        //   壳的产出方式在 12 票被改写:spec 原文写 XcodeGen,但本机无 Xcode → 无 `xcodebuild` → `.xcodeproj` 无消费者,
        //   故改为 `Scripts/build-app.sh` 手工组 bundle + ad-hoc 签名(spec 已就此追加勘误,验收意图不变)。
        //   曾塞在 Sources/AAHostMacOS/HostApp.swift 里的 @main 已移到独立的 `aahost` executable target
        //   (Sources/aahost/AAHostMain.swift),AppDelegate 随之转 public。原计划归 12 票,因 11 票换引擎后
        //   SPM 必须有真 executable target 才产得出可执行而提前。12 票只剩「把 aahost 打进 .app bundle」——已落地。
        //   因此这里保持 .target(库),**不要**改成 .executableTarget。
        // 06 票:宿主 V1 内封栈——AAHostMacOS 装配 PluginProxy(注入真 Port),故新增 AAPluginSDK + PluginProxy 依赖。
        //   注意方向:宿主依赖插件(合法);铁律只禁「插件依赖 Host*」,不禁「Host 依赖插件」。
        // 14 票:菜单栏轻壳落地 —— AAHostMacOS 新增 AAUISystem 依赖(菜单模型 `AAMenuModel` 住在那里,
        //   两个渲染器 MenuBarController.swift / MenuSnapshotRenderer.swift 都 import 它)。
        //   此前它是靠 PluginProxy 传递引入的,按本文件「依赖边须与源码实际 import 一一对应」的口径,显式声明。
        .target(name: "AAHostMacOS", dependencies: ["AAHostRuntime", "AAContracts", "AAPluginSDK", "PluginProxy", "AAUISystem"]),
        // 06 票:AAHostTestKit 加 Port 假件 + 插件域逻辑纯逻辑测试,故新增 AAPluginSDK + PluginProxy 依赖(同样是「测试基建依赖插件」,合法)。
        // 14 票:加菜单模型的纯逻辑测试与固定装置(MenuFixtures / MenuModelConformanceTests),故显式补 AAUISystem。
        // 17 票:断言全部搬进 `Tests/AAHostTestKitTests`(swift-testing),本 target 只剩**假件与固定装置**
        //   (ProxyFakes / NetworkConfigFakes / SelfHealFakes / SubscriptionFakes / MenuFixtures)。
        //   **假件刻意留在 Sources/ 而不是搬进 Tests/**:它们有两类消费者 —— 测试 target,以及
        //   `menu-snapshot` 这个**可执行**(它用 MenuFixtures 的三种状态渲染快照)。SPM 的 executableTarget
        //   不能依赖 testTarget,搬进 Tests/ 会直接把 menu-snapshot 打断。依赖边不变(五个假件文件的
        //   实际 import 仍是这五个模块)。
        .target(name: "AAHostTestKit", dependencies: ["AAHostRuntime", "AAContracts", "AAPluginSDK", "PluginProxy", "AAUISystem"]),
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
        // 17 票:断言全部搬进 `Tests/AAAgentTestKitTests`(swift-testing),本 target 只剩
        //   **假件**(FakeAgentPort / FakeTaskPorts)与**反孤儿探针**(SystemAgentPortOrphanProbe)。
        //   探针必须留在 Sources/:它的唯一消费者是 `registry-tests` 这个可执行,而 executableTarget
        //   不能依赖 testTarget(理由详见 Sources/registry-tests/main.swift 头注)。
        //   依赖边随之收窄:剩下的三个文件只 import AAAgentCore / AAAgentSystem / Foundation / Darwin,
        //   **一行 AAContracts 都没有** —— 按本文件「依赖边须与源码实际 import 一一对应」的口径去掉它,不挂空头依赖。
        .target(name: "AAAgentTestKit", dependencies: ["AAAgentCore", "AAAgentSystem"]),

        // ④ CLI 可执行
        .executableTarget(name: "aa", dependencies: ["AAContracts"]),
        // agent-delegation 07:委托试驾 CLI(`run|status|cancel|list|prune`)。
        //   依赖边与源码实际 import 一一对应:AAAgentCore(组装 / 状态机 / 归一化 / 看门狗)+
        //   AAAgentSystem(真进程端口与真文件系统端口)+ AAContracts(退出码单一来源)。
        //   **绝不依赖 AAHostMacOS / AAHostRuntime / PluginProxy**:它是 agent-delegation 模块自己的入口,
        //   与 v1-core-proxy 的 16 票并行落地、互不踩施工面(现有 `aa` 一个字节都不动)。
        .executableTarget(name: "aa-agent", dependencies: ["AAContracts", "AAAgentCore", "AAAgentSystem"]),
        // 11 票:GUI 宿主的薄可执行壳。依赖边与源码实际 import 一一对应:只有 AppKit(系统)+ AAHostMacOS。
        //   壳里只有「建 NSApplication、挂 AppDelegate、run」三行,全部业务逻辑仍在 AAHostMacOS 库里。
        .executableTarget(name: "aahost", dependencies: ["AAHostMacOS"]),
        // 11 票:门禁的 TestKit runner。此前由 Scripts/check/build.sh 用 heredoc 动态生成再 swiftc 直编,
        //   换 `swift build` 后 SPM 只认真源文件,故固化成 target。
        //   **刻意不加 product**:它是门禁内部工具,不是对外交付物,`swift build` 会因为是 executableTarget
        //   自动把它造出来,无需在 products 里露面。
        // 17 票:断言迁走后它只剩**反孤儿信号探针宿主**这一件事(`Scripts/check/agent-e2e.sh` 的
        //   `AA_ORPHAN_PROBE=exit|signal` 两条路径)。那件事在测试进程内验不了(要宿主真的死一次),
        //   故 target 保留;依赖边随之收窄到 AAAgentTestKit 一个(main.swift 现在只 import 它 + Foundation)。
        // 依赖 AAContracts 是为了退出码单一来源(`AAExitCode.usage`)—— 17 票之后 AAAgentTestKit
        //   不再依赖它,故这里显式声明,与「依赖边须与源码实际 import 一一对应」的口径一致。
        .executableTarget(name: "registry-tests", dependencies: ["AAAgentTestKit", "AAContracts"]),
        // 14 票:菜单快照工具(渲染器 B 的驱动)。与 registry-tests 同性质 —— **门禁内部工具,不是交付物**,
        //   故同样刻意不进 products。依赖边与 Sources/menu-snapshot/main.swift 的实际 import 一一对应:
        //   AAHostMacOS(渲染器 B)+ AAHostTestKit(三种状态的固定装置与真能力清单)+ AAUISystem(模型)+ AAContracts。
        //   为什么必须是独立可执行、不能并进 registry-tests:渲染要 AppKit,而 registry-tests 是纯逻辑 runner,
        //   把 AppKit 拖进去会让「纯逻辑套件不依赖 GUI」这条金字塔底座失守。
        .executableTarget(name: "menu-snapshot",
                          dependencies: ["AAHostMacOS", "AAHostTestKit", "AAUISystem", "AAContracts"]),
        // ⑤ swift-testing 用例(11 票起 `swift test` 进门禁;17 票把手写 TestReport 断言全量迁进来)。
        //   依赖边一律与各测试文件的实际 import 一一对应,口径与库 target 相同。
        .testTarget(name: "AAContractsTests", dependencies: ["AAContracts"]),
        // 17 票:宿主域逻辑六套(Registry / Proxy / SystemProxy / CrashRecovery / Subscription / MenuModel)。
        //   依赖 AAHostTestKit 是为了拿它的**假件**(ProxyFakes / NetworkConfigFakes / SelfHealFakes /
        //   SubscriptionFakes / MenuFixtures),其余四个模块是被测对象本身。
        .testTarget(name: "AAHostTestKitTests",
                    dependencies: ["AAHostTestKit", "AAHostRuntime", "AAContracts", "AAPluginSDK",
                                   "PluginProxy", "AAUISystem"]),
        // 17 票:agent 委托适配层七套(Core / ClaudeAdapter / CodexAdapter / Task / Watchdog /
        //   LaunchAssembler / SystemAgentPort)。**注意 SystemAgentPortTests 会起真进程**(sleep 87137),
        //   裸跑 `swift test` 没有门禁的清场网 —— 警告见 Tests/README.md 与该文件头注。
        .testTarget(name: "AAAgentTestKitTests",
                    dependencies: ["AAAgentTestKit", "AAAgentCore", "AAAgentSystem", "AAContracts"]),
    ],
    swiftLanguageModes: [.v5]
)
