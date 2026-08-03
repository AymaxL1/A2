// AAHostTestKit —— 14 票菜单模型的**共享固定装置**(能力清单 + 三种状态)。
//
// 为什么放这里而不是放进 AAUISystem:它们是**测试装置**,不该随产品库出厂。
//   放在 TestKit 里,门禁的纯逻辑断言(MenuModelConformanceTests)与快照工具(`menu-snapshot`)
//   就能吃**同一份**装置 —— 于是「快照覆盖的三种状态」与「状态反映断言喂的三种状态」物理上是同一批,
//   不可能出现「断言验的是 A、图片画的是 B」这种看起来都绿、其实各说各话的局面。
//
// 依赖边:AAHostTestKit → AAUISystem / AAHostRuntime / PluginProxy / AAPluginSDK / AAContracts。

import Foundation
import AAContracts
import AAHostRuntime
import AAPluginSDK
import AAUISystem
import PluginProxy

/// 菜单模型的固定装置。
public enum AAMenuFixtures {

    // ============ 能力清单:与宿主装配**同源** ============

    /// 造一份与宿主 `applicationDidFinishLaunching` **同样装配**的注册表:
    /// `Registry.demoCapabilities + ProxyPlugin.capabilities()`,只是把三个 Port 换成假件。
    ///
    /// 这一条是「菜单项能追溯到真实能力」这条验收的**证据来源**:门禁不去另抄一份能力 id 名单,
    ///   而是拿这份真注册表的 `list()` / `describe()` 去交叉核对菜单模型 ——
    ///   能力被改名/删掉/换风险档,断言当场红。
    ///
    /// - Parameter confirmDangerous: dangerous 确认回调(纯逻辑断言可注入假件;缺省 nil = fail-closed)。
    public static func realRegistry(confirmDangerous: ConfirmDangerous? = nil) -> Registry {
        let plugin = ProxyPlugin(processPort: FakeProcessPort(),
                                 httpPort: FakeHTTPPort(),
                                 networkConfigPort: FakeNetworkConfigPort(initial: []),
                                 kernelPath: nil,
                                 controlPort: 9090)
        let pluginCaps = plugin.capabilities().map { Capability(descriptor: $0.descriptor, handler: $0.handler) }
        return Registry(capabilities: Registry.demoCapabilities + pluginCaps,
                        confirmDangerous: confirmDangerous)
    }

    /// 真实能力描述符清单(即上面那份注册表的 `list()`)。
    public static func realCapabilities() -> [CapabilityDescriptor] { realRegistry().list() }

    // ============ 三种「主要菜单状态」 ============

    /// 一个固定装置 = 稳定名(产物文件名)+ 人读标题 + 状态。
    public struct Fixture: Sendable {
        public let name: String
        public let title: String
        public let state: AAProxyUIState
        public init(name: String, title: String, state: AAProxyUIState) {
            self.name = name; self.title = title; self.state = state
        }
    }

    /// ① 内核未运行。
    public static let kernelDown = Fixture(
        name: "01-kernel-down",
        title: "内核未运行",
        state: AAProxyUIState(kernelRunning: false))

    /// ② 内核运行中:rule 模式 + 已选节点 + 两个代理组。
    public static let kernelRunning = Fixture(
        name: "02-kernel-running",
        title: "内核运行中(rule 模式 · 节点 HK-01)",
        state: AAProxyUIState(
            kernelRunning: true,
            apiReachable: true,
            kernelVersion: "v1.19.28",
            mode: "rule",
            mixedPort: 7890,
            currentNode: "HK-01",
            groups: [
                AAProxyUIState.Group(name: "PROXY", type: "Selector", now: "HK-01",
                                     all: ["HK-01", "JP-02", "DIRECT"]),
                AAProxyUIState.Group(name: "GLOBAL", type: "Selector", now: "PROXY",
                                     all: ["PROXY", "DIRECT"])
            ]))

    /// ③ 有激活订阅(内核运行中 + 两条订阅,激活其一)。
    public static let activeSubscription = Fixture(
        name: "03-active-subscription",
        title: "有激活订阅(激活「机场 A」)",
        state: AAProxyUIState(
            kernelRunning: true,
            apiReachable: true,
            kernelVersion: "v1.19.28",
            mode: "global",
            mixedPort: 7890,
            currentNode: "JP-02",
            groups: [
                AAProxyUIState.Group(name: "PROXY", type: "Selector", now: "JP-02",
                                     all: ["HK-01", "JP-02"])
            ],
            subscriptions: [
                AAProxyUIState.Subscription(id: "sub-jichang-a-1a2b3c", name: "机场 A"),
                AAProxyUIState.Subscription(id: "sub-jichang-b-4d5e6f", name: "机场 B")
            ],
            activeSubscriptionID: "sub-jichang-a-1a2b3c"))

    /// 快照与状态反映断言共用的三种主要状态(顺序即产物编号顺序)。
    public static let fixtures: [Fixture] = [kernelDown, kernelRunning, activeSubscription]
}
