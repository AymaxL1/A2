// AAPluginSDK —— TakeoverStateStore:接管态清单的持久化边界(08 崩溃自愈)。
// 依赖边:AAPluginSDK → AAContracts(+ Foundation)。绝不 import 任何 Host*。
//
// 08 票:宿主接管系统代理成功时,要把「接管态清单」(接管前快照 + 内核端口 + 内核 pid + 标记/时间戳)持久化,
//   供下次启动(尤其是被 kill -9 强杀后)自愈判定。本 Port 只负责**原子、持久**地搬一坨不透明字节:
//     * 真实现(AAHostMacOS.FileTakeoverStateStore)= 临时文件 + rename 原子写到 AAPaths 下的 takeover-state.json;
//     * 假件(AAHostTestKit.FakeTakeoverStateStore)= 存内存,供纯逻辑/E2E 单测。
//   **schema 决策留在域层(PluginProxy.TakeoverState 的 Codable)**——本 Port 不认识清单结构,只搬字节,
//   这样持久化格式的演进不牵动宿主/SDK,边界干净。
//
// 铁律落点:协议定义在 SDK(插件只依赖 SDK);真实现/假件在 Host* 侧。

import Foundation

/// 接管态持久化 Port(原子字节存储;域层负责 Codable 编解码)。
///
/// 语义契约:
/// - `load`:读取已持久化的字节;无(从未接管 / 已清除)返回 nil。读失败(半截/损坏)亦返回 nil(按「无残留」保守处理)。
/// - `save`:**原子**写入字节(临时文件 + rename,杜绝半截文件)。写失败抛错(由域层收敛记日志,不崩)。
/// - `clear`:清除持久化(还原成功后表示「无残留接管」)。幂等:本就不存在为 no-op。
public protocol TakeoverStateStore: Sendable {
    func load() -> Data?
    func save(_ data: Data) throws
    func clear()
}

/// 无操作 TakeoverStateStore(缺省注入):load 永远 nil、save/clear 为 no-op。
/// 用于「持久化关闭」的场景(如纯逻辑单测不关心持久化时);生产/E2E 由宿主注入文件后端真实现。
public struct NoopTakeoverStateStore: TakeoverStateStore {
    public init() {}
    public func load() -> Data? { nil }
    public func save(_ data: Data) throws {}
    public func clear() {}
}
