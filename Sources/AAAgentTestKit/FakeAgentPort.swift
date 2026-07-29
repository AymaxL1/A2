// AAAgentTestKit —— AAAgentCore 的主 seam 假件:把一次 agent 进程执行换成可编程 `FakeAgentPort`,
//   让任务状态机 / 生命周期 / 看门狗 / 归一化在零真实 agent 下纯逻辑测试(spec Testing Decisions 主 seam)。
// 依赖边:AAAgentTestKit → AAAgentCore、AAContracts(+ 系统 Foundation)。
//
// 能力(样板 = AAHostTestKit.FakeProcessPort):
//   * 回放一段预置 stdout 事件脚本(programEvents → 下一次 launch 后 nextEvent 依次弹出);
//   * 编程 launch 失败(programNextLaunchToFail);
//   * 模拟进程中途死亡(simulateDeath,不经 terminate);
//   * 记录 launch 规格(launchCalls)与终止句柄序列(terminateCalls)。

import Foundation
import AAAgentCore

/// 可编程假 `AgentPort`。记录 launch/terminate 调用;可回放预置事件脚本、编程 launch 失败、模拟外部死亡。
/// `@unchecked Sendable`:内部状态由 lock 串行化保护(与 FakeProcessPort 同款并发约定)。
public final class FakeAgentPort: AgentPort, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt64 = 1
    private var alive: [UInt64: Bool] = [:]
    /// 每个存活句柄剩余待弹出的原始事件行(FIFO)。
    private var events: [UInt64: [String]] = [:]
    /// 待绑定给「下一次 launch」的事件脚本(programEvents 预置,launch 时移交给新句柄)。
    private var pendingEvents: [String] = []
    /// 下一次 launch 是否抛错。
    private var failNextLaunch = false

    /// 拉起调用记录(完整启动规格),供断言「拉起被正确调用 + 参数/工作目录/stdin 处置无误」。
    public private(set) var launchCalls: [AgentLaunchSpec] = []
    /// 终止调用记录,供反孤儿 / 取消断言「终止被调用」。
    public private(set) var terminateCalls: [AgentProcessHandle] = []

    public init() {}

    /// 编程:预置「下一次 launch 后」nextEvent 依次弹出的原始事件脚本(逐行 agent stdout)。
    public func programEvents(_ lines: [String]) {
        lock.lock(); defer { lock.unlock() }
        pendingEvents = lines
    }

    /// 编程:令下一次 launch 抛错(测拉起失败降级)。
    public func programNextLaunchToFail() {
        lock.lock(); defer { lock.unlock() }
        failNextLaunch = true
    }

    public enum FakeError: Error { case launchProgrammedToFail }

    public func launch(_ spec: AgentLaunchSpec) throws -> AgentProcessHandle {
        lock.lock(); defer { lock.unlock() }
        if failNextLaunch { failNextLaunch = false; throw FakeError.launchProgrammedToFail }
        launchCalls.append(spec)
        let id = nextID; nextID += 1
        alive[id] = true
        events[id] = pendingEvents      // 把预置脚本绑定到本次句柄
        pendingEvents = []              // 消费掉,不外溢到下一次 launch
        return AgentProcessHandle(id: id)
    }

    public func nextEvent(_ handle: AgentProcessHandle) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard alive[handle.id] == true else { return nil }          // 未知 / 已死 → nil
        guard var queue = events[handle.id], !queue.isEmpty else { return nil }  // 脚本弹完 → nil
        let line = queue.removeFirst()
        events[handle.id] = queue
        return line
    }

    public func isAlive(_ handle: AgentProcessHandle) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return alive[handle.id] ?? false
    }

    public func terminate(_ handle: AgentProcessHandle) {
        lock.lock(); defer { lock.unlock() }
        terminateCalls.append(handle)
        alive[handle.id] = false
    }

    /// 测试助手:模拟进程「中途外部死亡」(不经 terminate、不记录),用于「进程中途死亡后读流/探活如实反映」断言。
    public func simulateDeath(_ handle: AgentProcessHandle) {
        lock.lock(); defer { lock.unlock() }
        alive[handle.id] = false
    }
}
