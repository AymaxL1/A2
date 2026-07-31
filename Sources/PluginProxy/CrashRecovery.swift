// PluginProxy —— 崩溃自愈的域逻辑(08 票):持久化接管态清单 + 自愈判定纯函数。
// 依赖边:PluginProxy → AAPluginSDK(NetworkConfigPort/ServiceProxyState/ProxyKind…)、AAContracts。绝不 import Host*。
//
// 08 票核心:宿主崩溃/被 kill -9 强杀后,用户不断网——但系统代理可能仍指向本应用已死的内核端口(断网态)。
//   下次启动时据「持久化的接管态清单」判定并自愈,**硬不变式:自愈后系统代理绝不指向死端口**。
//   判定(何时恢复接管 / 何时还原快照 / 何时不覆盖用户设置)抽成纯函数 `SelfHealDecision.decide`,注入假件即可逐分支断言;
//   真正的副作用(reap 孤儿 / 重启内核 / 还原快照 / 读写持久化)由 ProxyPlugin.selfHeal 编排(见 PluginProxy.swift)。

import AAContracts
import AAPluginSDK
import Foundation

/// 持久化的「接管态清单」(08 崩溃自愈)。enable/接管成功时写;disable/正常退出还原成功时清除。
/// Codable,经 `TakeoverStateStore` 原子持久化(schema 决策在域层,不外泄到 SDK/Host)。
public struct TakeoverState: Sendable, Equatable, Codable {
    /// 接管前的系统代理原状态快照(自愈「还原快照」分支据此精确复原;绝不还原成「指向死端口」的当前态)。
    public let snapshot: SystemProxySnapshot
    /// 接管时把系统代理指向的内核端口(mixed-port)。自愈判定「当前系统代理是否仍指向我方端口」的锚点。
    public let kernelPort: Int
    /// 接管时的内核**原始 pid**。跨世代孤儿回收用:宿主被 kill -9 后据此探活/reap 上一世代残留内核。0 = 未知(不 reap)。
    public let kernelPID: Int32
    /// 接管时内核进程的**可执行映像绝对路径**(reap 前身份核验用)。
    /// **安全关键(修 pid 复用盲杀)**:pid 跨重启/重开机存活于持久化文件,其号极可能已被无关进程复用。
    /// reap 前必须用 `proc_pidpath(pid)` 读回该 pid 当前可执行路径,与本字段**逐字节相等**才 SIGKILL——否则不杀
    /// (可能是无辜进程)。空串 = 未知路径 → 一律不 reap(保守)。
    public let kernelExecutablePath: String
    /// 接管标记(恒 true;文件存在即已接管——留字段令语义显式,便于将来扩展多态标记)。
    public let active: Bool
    /// 接管时间戳(Unix 秒;诊断/将来做过期策略用)。
    public let takeoverAt: Double

    public init(snapshot: SystemProxySnapshot, kernelPort: Int, kernelPID: Int32,
                kernelExecutablePath: String, active: Bool = true, takeoverAt: Double) {
        self.snapshot = snapshot
        self.kernelPort = kernelPort
        self.kernelPID = kernelPID
        self.kernelExecutablePath = kernelExecutablePath
        self.active = active
        self.takeoverAt = takeoverAt
    }
}

/// 自愈判定结果(五分支;命名即策略,便于将来调策略而不动执行编排)。
public enum SelfHealDecision: String, Sendable, Equatable {
    /// ① 无持久化标记 → 干净启动,无操作。
    case clean
    /// ② 有标记,但当前系统代理已不指向我方端口(用户手动改过 / 已是别的代理 / 已直连)→ 不覆盖用户设置,只清陈旧标记。
    case userChangedProxy
    /// ③a 残留接管(代理仍指向我方端口,且端口已死)+ 内核能健康重启 → 恢复接管(重启内核 + 系统代理指向存活端口)。
    case recoverTakeover
    /// ③b 残留接管 + 内核不能健康重启 → 按快照精确还原(降级直连,绝不留死端口)。
    case restoreSnapshot
    /// ④ 有标记,系统代理指向我方端口且端口仍活(其实没崩,或已恢复)→ 视为正常,校正标记即可。
    case alreadyHealthy
    /// (非 decide 产物,执行层专用)标记不可解码/读取时，禁用指向本机的代理并降级到可联网状态。
    case failSafeDirect
    /// (非 decide 产物,执行层专用)采集信号失败(如读当前系统代理抛错)→ 保守中止:**保留标记、不清、不误判**,待下次启动重试。
    /// `decide` 只做五条策略分派,绝不返回本值;它表达「无法判定」这一操作性中止,与「判定为某策略」区分开。
    case deferred
}

/// 崩溃自愈的纯逻辑(判定 + 不变式辅助)。
public enum CrashRecovery {

    /// 自愈判定纯函数(五分支)。输入均为「已由执行层采集好的」布尔信号,故本函数无 I/O、可逐分支断言。
    ///
    /// **硬不变式**:任一分支的后续执行都不得让系统代理停留在「指向死端口」——`decide` 只做分派,
    /// 保证「代理仍指向死端口」的残留态(③)一定走向 恢复接管 或 还原快照 二者之一,绝不放任不管。
    ///
    /// - Parameters:
    ///   - hasPersistedMarker: 是否存在持久化接管态清单。
    ///   - proxyStillPointsAtKernelPort: 当前系统代理是否仍指向我方内核端口(127.0.0.1:<清单里的 kernelPort>)。
    ///   - kernelPortHealthy: 该端口当前是否由「受本世代管理且健康」的内核承载(启动早期通常为 false:旧内核是孤儿、已 reap)。
    ///   - kernelHealthilyRestartable: 内核能否被健康重启(已配置内核路径且重启后 REST 可读到 mixed-port)。
    public static func decide(hasPersistedMarker: Bool,
                              proxyStillPointsAtKernelPort: Bool,
                              kernelPortHealthy: Bool,
                              kernelHealthilyRestartable: Bool) -> SelfHealDecision {
        // ① 无标记 → clean(绝不读网络/内核,避免无谓触达真 networksetup)。
        guard hasPersistedMarker else { return .clean }
        // ② 有标记但代理已不指向我方端口 → 用户手动改过,不覆盖,只清陈旧标记。
        guard proxyStillPointsAtKernelPort else { return .userChangedProxy }
        // ④ 代理仍指向我方端口且端口仍活 → 视为正常,校正标记。
        if kernelPortHealthy { return .alreadyHealthy }
        // ③ 残留接管(代理指向我方端口但端口已死):内核可健康重启 → 恢复接管;否则 → 还原快照(降级直连)。
        return kernelHealthilyRestartable ? .recoverTakeover : .restoreSnapshot
    }

    /// 身份核验纯逻辑(修 pid 复用盲杀):持久化 pid 的**当前**可执行路径 `currentPath` 是否确为我们记录的内核 `expectedPath`。
    /// 仅当 `currentPath` 非 nil、`expectedPath` 非空、二者逐字节相等时返回 true(才允许 SIGKILL)。
    /// `currentPath == nil` 表示 pid 已死 / 无权读取(EPERM,非本用户进程)/ 无法确定 → 一律不是我方内核 → 不杀。
    public static func isOurKernel(currentPath: String?, expectedPath: String) -> Bool {
        guard let current = currentPath, !expectedPath.isEmpty else { return false }
        return current == expectedPath
    }

    /// 不变式辅助:当前系统代理里是否**仍有任一服务的任一类代理**指向 `host:port`(开启态)。
    /// 用于判定「代理是否仍指向我方端口」(②/③ 的分水岭),也用于断言「自愈后不指向死端口」。
    public static func systemProxyPointsAt(host: String, port: Int, services: [ServiceProxyState]) -> Bool {
        for state in services {
            for kind in ProxyKind.allCases {
                let s = state.setting(for: kind)
                if s.enabled && s.host == host && s.port == port { return true }
            }
        }
        return false
    }
}

/// 一次自愈的结果报告(供宿主日志 + E2E 观测)。
public struct SelfHealReport: Sendable, Equatable {
    /// 采取的判定分支。
    public let decision: SelfHealDecision
    /// 若清理了上世代残留内核孤儿,其 pid(否则 nil)。
    public let reapedOrphanPID: Int32?
    /// 自愈过程中是否(重新)拉起了内核(恢复接管路径为 true)。
    public let kernelRelaunched: Bool

    public init(decision: SelfHealDecision, reapedOrphanPID: Int32?, kernelRelaunched: Bool) {
        self.decision = decision
        self.reapedOrphanPID = reapedOrphanPID
        self.kernelRelaunched = kernelRelaunched
    }

    /// deferred 表示隔离/采集未完成；宿主不得在无还原快照时走常规内核启停。
    public var allowsKernelLaunch: Bool { decision != .deferred }

    /// 一行人读摘要(宿主启动日志用;E2E 可 grep)。
    public var logLine: String {
        let reap = reapedOrphanPID.map { "reaped-orphan-pid=\($0)" } ?? "reaped-orphan=none"
        return "self-heal decision=\(decision.rawValue) \(reap) kernel-relaunched=\(kernelRelaunched)"
    }
}
