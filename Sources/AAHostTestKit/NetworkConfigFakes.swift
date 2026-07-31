// AAHostTestKit —— NetworkConfigPort 内存假件(让系统代理接管/还原域逻辑在零真 networksetup 下可纯逻辑单测)。
// 依赖边:AAHostTestKit → AAPluginSDK(NetworkConfigPort / 值类型)。
//
// 07 票测试金字塔的次 seam:把「读/设/关系统代理」换成可编程内存假件,即可断言快照/接管/还原逻辑
//   (含「原本就有第三方代理」用例),不碰真系统设置、不起真宿主。

import Foundation
import AAPluginSDK

/// 可编程内存假 NetworkConfigPort。构造注入初始各服务状态;记录 set/disable 调用序列。
/// `@unchecked Sendable`:内部状态由 lock 串行化保护。
public final class FakeNetworkConfigPort: NetworkConfigPort, @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String]                       // 服务枚举顺序(稳定)
    private var state: [String: ServiceProxyState]

    /// 设代理调用记录,供断言「接管把各服务各类都指向内核端口」。
    public private(set) var setCalls: [(service: String, kind: ProxyKind, host: String, port: Int)] = []
    /// 关代理调用记录,供断言「原本关闭的还原成关闭」。
    public private(set) var disableCalls: [(service: String, kind: ProxyKind)] = []

    /// 编程:让**读**(networkServices/proxyState)抛错——模拟「读当前系统代理失败」(08 自愈应保守 deferred,不误判用户改过)。
    public var failReads = false
    /// 编程:让**写**(setProxy/disableProxy)抛错——模拟「还原/接管失败」(08 自愈失败应保留标记,绝不清标记留死端口)。
    public var failWrites = false
    /// 编程:仅第 N 次写入失败一次。用于模拟接管已部分落地后才失败,验证事务回滚。
    public var failWriteAtCall: Int?
    /// 编程:从第 N 次写开始持续失败，用于模拟接管失败后回滚也失败。
    public var failWritesStartingAtCall: Int?
    private var writeAttemptCount = 0

    public init(initial: [ServiceProxyState]) {
        self.order = initial.map { $0.service }
        var m = [String: ServiceProxyState]()
        for s in initial { m[s.service] = s }
        self.state = m
    }

    public enum FakeError: Error, Equatable {
        case unknownService(String)
        case readProgrammedToFail
        case writeProgrammedToFail
    }

    public func networkServices() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        if failReads { throw FakeError.readProgrammedToFail }
        return order
    }

    public func proxyState(service: String) throws -> ServiceProxyState {
        lock.lock(); defer { lock.unlock() }
        if failReads { throw FakeError.readProgrammedToFail }
        guard let s = state[service] else { throw FakeError.unknownService(service) }
        return s
    }

    public func setProxy(service: String, kind: ProxyKind, host: String, port: Int) throws {
        lock.lock(); defer { lock.unlock() }
        writeAttemptCount += 1
        if failWrites { throw FakeError.writeProgrammedToFail }
        if failWriteAtCall == writeAttemptCount { throw FakeError.writeProgrammedToFail }
        if let n = failWritesStartingAtCall, writeAttemptCount >= n { throw FakeError.writeProgrammedToFail }
        setCalls.append((service, kind, host, port))
        guard let s = state[service] else { throw FakeError.unknownService(service) }
        state[service] = s.replacing(kind, with: ProxySetting(enabled: true, host: host, port: port))
    }

    public func disableProxy(service: String, kind: ProxyKind) throws {
        lock.lock(); defer { lock.unlock() }
        writeAttemptCount += 1
        if failWrites { throw FakeError.writeProgrammedToFail }
        if failWriteAtCall == writeAttemptCount { throw FakeError.writeProgrammedToFail }
        if let n = failWritesStartingAtCall, writeAttemptCount >= n { throw FakeError.writeProgrammedToFail }
        disableCalls.append((service, kind))
        guard let s = state[service] else { throw FakeError.unknownService(service) }
        state[service] = s.replacing(kind, with: .off)
    }

    /// 测试助手:读某服务当前(内存)状态,供断言接管/还原后的落点。
    public func currentState(service: String) -> ServiceProxyState? {
        lock.lock(); defer { lock.unlock() }
        return state[service]
    }

    /// 测试助手:模拟「接管后新出现一个网络服务」(用户中途接了 Ethernet / iPhone USB 等),
    /// 用于回归「enable 重放快照漏洞」——接管后新增的服务也必须进快照、能被还原,不残留指向内核死端口。
    public func addService(_ svc: ServiceProxyState) {
        lock.lock(); defer { lock.unlock() }
        if state[svc.service] == nil { order.append(svc.service) }
        state[svc.service] = svc
    }
}
