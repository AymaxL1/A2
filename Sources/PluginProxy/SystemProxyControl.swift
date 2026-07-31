// PluginProxy —— 系统代理接管/还原的纯逻辑引擎(快照 / 接管 / 还原)。
// 依赖边:PluginProxy → AAPluginSDK(NetworkConfigPort/ProxyKind/ServiceProxyState/ProxySetting)、AAContracts。绝不 import Host*。
//
// 07 票核心语义(全纯逻辑,注入假 NetworkConfigPort 即可断言):
//   * 快照(capture):接管前逐服务、逐类(HTTP/HTTPS/SOCKS)记录代理原状态(开关+host+port)。
//   * 接管(takeover):把各服务三类代理都指向内核 host:port(127.0.0.1:<mihomo mixed-port>)。
//   * 还原(restore):**按快照精确还原**——原本开着第三方代理的还原成那个第三方 host:port,原本关着的还原成关闭。
//       绝不「一律关闭」:那会抹掉用户接管前自己配的第三方代理(旗舰体验最忌讳的隐性破坏)。
// 快照可 Codable 持久化,为 08 崩溃自愈(重启后检测上一世代快照 + 内核指向死端口)埋点。

import AAContracts
import AAPluginSDK

/// 接管前的系统代理全量快照(逐服务的三类代理原状态)。Codable 以便持久化(08 崩溃自愈复用)。
public struct SystemProxySnapshot: Sendable, Equatable, Codable {
    /// 接管前各网络服务的代理原状态(顺序即枚举顺序)。
    public let services: [ServiceProxyState]

    public init(services: [ServiceProxyState]) {
        self.services = services
    }
}

/// 在修改任何系统设置前已完整捕获、可安全持久化的接管计划。
public struct SystemProxyTakeoverPlan: Sendable, Equatable {
    /// 首次接管前快照（并入本次新服务），最终 disable/self-heal 使用。
    public let snapshot: SystemProxySnapshot
    /// 本次调用开始时的即时状态，仅用于本次 apply 失败回滚。
    public let rollbackSnapshot: SystemProxySnapshot
    public let services: [String]

    public init(snapshot: SystemProxySnapshot, rollbackSnapshot: SystemProxySnapshot, services: [String]) {
        self.snapshot = snapshot
        self.rollbackSnapshot = rollbackSnapshot
        self.services = services
    }
}

/// 系统代理接管/还原引擎(无状态纯逻辑;快照存放在调用方,如 ProxyPlugin)。
/// 构造注入 `NetworkConfigPort`(真实现调 networksetup;假件模拟);capture/takeover/restore 只编排 Port 调用,可单测。
public struct SystemProxyController: Sendable {
    private let net: any NetworkConfigPort

    public init(net: any NetworkConfigPort) {
        self.net = net
    }

    /// 捕获当前各服务的三类代理原状态(接管前调用一次)。
    public func capture() throws -> SystemProxySnapshot {
        var states: [ServiceProxyState] = []
        for service in try net.networkServices() {
            states.append(try net.proxyState(service: service))
        }
        return SystemProxySnapshot(services: states)
    }

    /// 接管:对每个**当前**网络服务——若其接管前原状态尚未在快照里,先捕获并**并入**快照,再把 HTTP/HTTPS/SOCKS
    /// 三类都指向内核 `host:port`(mixed-port 同时承载 HTTP 与 SOCKS,三类同指一 host:port)。返回并入后的新快照。
    ///
    /// **关键(修「重放快照漏洞」)**:凡被指向内核端口的服务,其接管前状态都必须进快照——**包括已接管后新出现的服务**
    /// (用户中途接了 Ethernet / iPhone USB 网络等)。否则该新服务被接管却不在首次快照里,`restore` 只遍历快照 →
    /// disable/宿主退出后**永久指向已死的内核端口**(本平台最不能犯的错)。既有快照里的服务保持首次捕获的原状态
    /// (不被覆盖,幂等:重复 enable 不改「最初」)。
    public func prepareTakeover(into existing: SystemProxySnapshot?) throws -> SystemProxyTakeoverPlan {
        var order: [String] = []
        var captured: [String: ServiceProxyState] = [:]
        for state in existing?.services ?? [] {
            captured[state.service] = state          // 保留既有快照的首次原状态(不覆盖)
            order.append(state.service)
        }
        let services = try net.networkServices()
        var rollbackStates: [ServiceProxyState] = []
        for service in services {
            let current = try net.proxyState(service: service)
            rollbackStates.append(current)
            if captured[service] == nil {
                // 首次见到的服务并入最终还原快照；所有读取均发生在第一笔写入前。
                captured[service] = current
                order.append(service)
            }
        }
        return SystemProxyTakeoverPlan(
            snapshot: SystemProxySnapshot(services: order.map { captured[$0]! }),
            rollbackSnapshot: SystemProxySnapshot(services: rollbackStates),
            services: services
        )
    }

    /// 应用已准备好的接管计划；本方法只写，捕获与持久化由调用方负责。
    public func applyTakeover(_ plan: SystemProxyTakeoverPlan, host: String, port: Int) throws {
        for service in plan.services {
            for kind in ProxyKind.allCases {
                try net.setProxy(service: service, kind: kind, host: host, port: port)
            }
        }
    }

    /// 供不持有持久事务状态的调用方使用的兼容便利入口。
    public func takeover(host: String, port: Int, into existing: SystemProxySnapshot?) throws -> SystemProxySnapshot {
        let plan = try prepareTakeover(into: existing)
        try applyTakeover(plan, host: host, port: port)
        return plan.snapshot
    }

    /// 按快照精确还原:逐服务逐类——原本开着(含第三方代理)→ 还原成那个 host:port;原本关着 → 还原成关闭。
    public func restore(_ snapshot: SystemProxySnapshot) throws {
        for state in snapshot.services {
            for kind in ProxyKind.allCases {
                let setting = state.setting(for: kind)
                if setting.enabled {
                    // 精确还原到原 host:port(含「原本就有第三方代理」用例——绝不一律关闭)。
                    try net.setProxy(service: state.service, kind: kind, host: setting.host, port: setting.port)
                } else {
                    // 原本关着 → 还原成关闭。
                    try net.disableProxy(service: state.service, kind: kind)
                }
            }
        }
    }
}
