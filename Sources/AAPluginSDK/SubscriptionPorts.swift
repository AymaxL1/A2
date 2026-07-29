// AAPluginSDK —— SubscriptionStore / SubscriptionSourcePort:订阅管理的两个持久化/拉取边界(10 票)。
// 依赖边:AAPluginSDK → AAContracts(+ Foundation)。绝不 import 任何 Host*。
//
// 10 票:订阅生命周期(存多个订阅 / 单一激活 / 更新已有源 / 新增或替换源)要落两类真 I/O——
//   ① 订阅清单元数据 + 按 id 物化的配置字节的**持久化**;② 按 source(file:// 或 http(s)://)**拉取**配置字节。
//   与 06/07/08 同口径:真 I/O 压到 Port 协议之后,宿主注入真实现(原子文件 / 真网络),测试注入假件;
//   **schema 决策留在域层**(PluginProxy.Subscription/SubscriptionCatalog 的 Codable)——本两 Port 只搬不透明字节,
//   不认识清单/配置结构,这样格式演进不牵动宿主/SDK,边界干净(照 TakeoverStateStore 的口径)。
//
// 铁律落点:协议定义在 SDK(插件只依赖 SDK)+ Noop 缺省实现;真实现/假件在 Host* 侧。

import Foundation

/// 订阅持久化边界:catalog(清单元数据)+ 按 id 物化的配置字节 + 物化配置的真实文件路径。
///
/// 语义契约:
/// - `loadCatalog`:读回清单字节;无(从未存)→ nil;损坏/半截 → nil(保守按「无清单」处理,域层重建)。
/// - `saveCatalog`:**原子**写清单字节(临时文件 + rename,杜绝半截)。写失败抛错(域层收敛记日志)。
/// - `saveConfig`:**原子**物化某订阅的配置字节(临时文件 + rename)。写失败抛错。
/// - `loadConfig`:读回某订阅已物化的配置字节(更新失败回滚用);无 → nil。
/// - `removeConfig`:删除某订阅的物化配置(幂等:本就不存在为 no-op)。
/// - `configPath`:该订阅物化配置的**绝对路径**(传给 `MihomoRESTClient.reloadConfig`——内核从路径重载配置需要它)。
public protocol SubscriptionStore: Sendable {
    func loadCatalog() -> Data?
    func saveCatalog(_ data: Data) throws
    func saveConfig(id: String, _ data: Data) throws
    func loadConfig(id: String) -> Data?
    func removeConfig(id: String)
    func configPath(id: String) -> String
}

/// 无操作 SubscriptionStore(缺省注入):loadCatalog 永远 nil、其余为 no-op、configPath 返回空串。
/// 用于「订阅持久化关闭」的场景(如既有构造点不注入时);生产/E2E 由宿主注入文件后端真实现。
public struct NoopSubscriptionStore: SubscriptionStore {
    public init() {}
    public func loadCatalog() -> Data? { nil }
    public func saveCatalog(_ data: Data) throws {}
    public func saveConfig(id: String, _ data: Data) throws {}
    public func loadConfig(id: String) -> Data? { nil }
    public func removeConfig(id: String) {}
    public func configPath(id: String) -> String { "" }
}

/// 订阅源拉取边界:给定 source(`file://` 路径 / 裸绝对路径 / `http(s)://` URL)取回配置字节。
///
/// 语义契约:
/// - `fetch`:同步取回该 source 的配置字节;不可达 / 非 2xx / 读失败一律抛错(域层收敛为业务失败,不崩)。
public protocol SubscriptionSourcePort: Sendable {
    func fetch(source: String) throws -> Data
}

/// SubscriptionSourcePort 的「未配置」错误(Noop 抛它;域层收敛为业务失败 → 退出码 5)。
public enum SubscriptionSourceError: Error, Equatable {
    /// 未配置订阅源拉取通道(缺省 Noop:宿主未注入真实现)。
    case notConfigured
    /// 拉取失败(不可达 / 非 2xx / 读失败),携带诊断。
    case fetchFailed(String)
}

/// 无操作 SubscriptionSourcePort(缺省注入):fetch 恒抛「未配置订阅源」错。
/// 生产/E2E 由宿主注入 RealSubscriptionSourcePort(file/http)。
public struct NoopSubscriptionSourcePort: SubscriptionSourcePort {
    public init() {}
    public func fetch(source: String) throws -> Data {
        throw SubscriptionSourceError.notConfigured
    }
}
