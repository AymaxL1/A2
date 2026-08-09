// swift-tools-version:6.0
//
// PROJECT_AA —— **Swift 侧只剩菜单栏壳**(a2 内核 bin 化 10 票,蓝图第⑤步「壳原子切换」)。
//
// ============================================================================
// 这个包现在是什么(以及它此前是什么)
// ============================================================================
// 此前:整个平台的主逻辑都在这里 —— GUI 宿主 `aahost` 持有注册表 / UDS server / 插件 / mihomo 生命周期,
//   `aa` 只是薄客户端,`aa-agent` 是委托试驾 CLI。UI 是必需品,agent 是客人。
// 现在:主逻辑全部在 `kernel/`(TS,Bun compile 成单文件 bin `a2`,macOS + Linux)。
//   本包收敛为**壳 target 群** —— 一个可选的 macOS 菜单栏客户端,经 UDS 与内核说话。
//
// 10 票退场的 16 个 target(理由见 ADR 0008 / spec 迁移六步节⑤;逐条断言落定见
// `kernel/test/swift-parity-map.md` 的「10 票收口」一节):
//   可执行 `aa` / `aa-agent` / `aahost` / `registry-tests` / `menu-snapshot` / `a2-smoke`,
//   库 `AAContracts` / `AAPluginSDK` / `AAHostRuntime` / `AAUISystem` / `AAHostMacOS` /
//   `AAHostTestKit` / `PluginProxy` / `AAAgentCore` / `AAAgentSystem` / `AAAgentTestKit`。
//
// ============================================================================
// 依赖图(两族,四层)
// ============================================================================
//   A2Contract        零依赖。与 `kernel/src/contract/wire.ts` 一一对照的手写 Codable 镜像。
//   A2KernelClient    → A2Contract。UDS 客户端基座(拆行 / 相关性 / 推送分流 / 角色注册)。
//   A2Panel           → A2Contract + A2KernelClient。**零 AppKit**:菜单模型、构造器、
//                       事件投影、会话循环、确认呈现模型 —— 全部可在纯逻辑测试里跑。
//   A2PanelMacOS      → A2Panel + AppKit。两个渲染器、确认器窗口、关于页、装配层。
//   A2PanelFixtures   → A2Panel。菜单状态固定装置(10 票四种 + 16 票六种引导分支,共十种)
//                       + 与内核 manifest 逐条对照的能力清单。
//
// 「依赖边须与源码实际 import 一一对应」这条口径继续有效(不挂空头依赖)。
//
// ============================================================================
// 工具链
// ============================================================================
// 需要一份 **SPM 可用**的 swift(CLT 自带的 libPackageDescription 与其接口错配,用不了):
//   `~/Library/Developer/Toolchains/swift-latest.xctoolchain` —— `Scripts/check.sh` 会现场探测。
// 门禁的命令接口(一条命令、非零退出即失败)自 11 票以来**逐字不变**,10 票换引擎时也不变。

import PackageDescription

let package = Package(
    name: "PROJECT_AA",
    platforms: [.macOS(.v13)],
    products: [
        // **本包唯一的对外交付物**:菜单栏壳(.app 显示名「A2 Panel」)。
        //   `.app` bundle 由 `Scripts/build-app.sh` 手工组 + ad-hoc 签名产出(本机无 Xcode,
        //   理由与实测证据写在该脚本顶部)。内核 bin `a2` 走单文件下载分发,不吃 .app 签名链。
        .executable(name: "a2-panel", targets: ["a2-panel"]),
        .library(name: "A2Contract", targets: ["A2Contract"]),
        .library(name: "A2KernelClient", targets: ["A2KernelClient"]),
        .library(name: "A2Panel", targets: ["A2Panel"]),
        .library(name: "A2PanelMacOS", targets: ["A2PanelMacOS"]),
    ],
    targets: [
        // ① 契约镜像(零依赖)
        //
        // 契约事实源是 TS(ADR 0010),这边**手写**对照 + 双端跑同一批金标样本
        // (`kernel/contract/golden/`),契约漂移在门禁层报警,**不引入代码生成链**。
        .target(name: "A2Contract"),

        // ② UDS 客户端基座
        //
        // 连接、NDJSON 字节级拆行、请求-响应按 id 相关、推送分发、角色注册与确认往返。
        // 依赖边与源码实际 import 一一对应:只有 A2Contract + Foundation/Darwin。
        .target(name: "A2KernelClient", dependencies: ["A2Contract"]),

        // ③ 壳的纯逻辑(**零 AppKit**)
        //
        // 「一个模型,两个渲染器」的模型层住在这里 —— 那是「快照能进 headless 门禁」的唯一前提
        // (`NSMenu` 没有可靠的离屏渲染入口,详见 A2MenuModel.swift 头注)。
        // 会话循环也在这里:它只用 Foundation/Darwin,于是 `a2-panel-probe` 这个无头替身
        // 能把壳的真实代码路径接到真内核上跑 e2e。
        .target(name: "A2Panel", dependencies: ["A2Contract", "A2KernelClient"]),

        // ④ 壳的 macOS 呈现面
        //
        // 渲染器 A(A2MenuModel → NSMenu)、渲染器 B(A2MenuModel → PNG)、确认器窗口、
        // 关于页(ADR 0007 修订版:降级为外部程序声明)、装配层(退出仅断连)。
        .target(name: "A2PanelMacOS", dependencies: ["A2Panel", "A2Contract"]),

        // ④′ 固定装置:**刻意住在 Sources/ 而不是 Tests/**
        //
        // 两类消费者 —— 测试 target 与 `a2-panel-snapshot` 这个可执行,而 SPM 的 executableTarget
        // 不能依赖 testTarget。于是「快照画的」与「断言验的」物理上是同一批状态。
        .target(name: "A2PanelFixtures", dependencies: ["A2Panel", "A2Contract"]),

        // ⑤ 可执行
        //
        // 壳本体:只有「建 NSApplication、挂 AppDelegate、run」三行,装配在 A2PanelMacOS 里。
        .executableTarget(name: "a2-panel", dependencies: ["A2PanelMacOS"]),
        // 壳快照的**产物工具**(重录 golden + 给人眼抽查的图)。**门禁内部工具,刻意不进 products**;
        //   门禁的判据在 `Tests/A2PanelSnapshotTests`(swift test),不在这里。
        .executableTarget(name: "a2-panel-snapshot",
                          dependencies: ["A2PanelMacOS", "A2Panel", "A2PanelFixtures"]),
        // 壳的**无头替身**,旗舰 e2e 的驱动(门禁内部工具,刻意不进 products)。
        //   `--decision approve|deny` 是**人的替身**,只住在这里 ——
        //   壳与内核里都没有任何测试专用的确认旁路(08 票的裁定,10 票照办)。
        .executableTarget(name: "a2-panel-probe",
                          dependencies: ["A2Panel", "A2PanelFixtures", "A2Contract"]),

        // ⑥ swift-testing 用例(新门禁四件套里的第②件半边与第③件)
        //
        // 双端金标门禁的 Swift 半边 —— 读 `kernel/contract/golden/` 的**同一批样本**:
        //   合法样本必须解得动且往返语义等价,非法样本必须被拒,外加「已登记契约 ↔ 镜像范围表」
        //   与「JSON Schema 封闭词表 ↔ Swift enum」两层对账。
        //   样本路径由 `#filePath` 推仓库根,**不经环境变量注入**(门禁脚本不必喂路径)。
        .testTarget(name: "A2ContractTests", dependencies: ["A2Contract"]),
        // 客户端基座的协议逻辑(拆行、相关性、推送分流、超时顺延)。
        //   假内核用 `socketpair()` 现造,**不起任何进程、不碰文件系统** —— 真 daemon 那一关归旗舰 e2e。
        .testTarget(name: "A2KernelClientTests", dependencies: ["A2KernelClient", "A2Contract"]),
        // 壳的纯逻辑:菜单覆盖面与可追溯性、四态如实反映、六族事件投影、确认原样呈现。
        .testTarget(name: "A2PanelTests", dependencies: ["A2Panel", "A2PanelFixtures", "A2Contract"]),
        // **壳快照**:渲染器 B 在测试进程里离屏渲染 → 与入库 golden(`Snapshots/a2-panel/`)
        //   比像素 + 比模型文本。14 票那条 shell 中间层(menu-snapshot + menubar.sh)随之退役。
        .testTarget(name: "A2PanelSnapshotTests",
                    dependencies: ["A2PanelMacOS", "A2Panel", "A2PanelFixtures"]),
    ],
    swiftLanguageModes: [.v5]
)
