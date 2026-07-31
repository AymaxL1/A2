// AAHostTestKit —— 08 崩溃自愈的假件(让自愈判定 + 执行编排在零真文件 / 零真进程下可单测)。
// 依赖边:AAHostTestKit → AAPluginSDK(TakeoverStateStore / ProcessReaper)。
//
// 08 票测试金字塔次 seam:把「接管态持久化」「跨世代孤儿回收」两个 Port 换成可编程内存假件,
//   即可断言自愈的读→判定→执行全链路(reap 孤儿 / 恢复接管 / 还原快照 / 用户改过只清标记),不碰真 AppSupport、不碰真进程。

import Foundation
import AAPluginSDK

/// 内存假 TakeoverStateStore。存一坨字节,记录 save/clear 调用,供断言持久化的写入/清除时机与内容。
/// `@unchecked Sendable`:内部状态由 lock 串行化保护。
public final class FakeTakeoverStateStore: TakeoverStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var blob: Data?
    private var recoveryBlob: Data?
    private var tombstoned = false

    /// save 调用次数(断言「接管成功即持久化」)。
    public private(set) var saveCount = 0
    /// clear 调用次数(断言「还原/用户改过后清标记」)。
    public private(set) var clearCount = 0
    /// 编程:让 save 抛错,用于证明接管态持久化失败时绝不开始修改系统代理。
    public var failSaves = false
    /// 编程:让 load 抛错，证明不可读标记不会被误判为“不存在”。
    public var failLoads = false
    public var failRecoveryRemoval = false
    public var failTombstoneWrites = false

    /// 构造时可预置一坨已持久化字节(模拟「上一世代崩溃后残留的接管态清单」)。
    public init(initial: Data? = nil, initialRecovery: Data? = nil) {
        self.blob = initial
        self.recoveryBlob = initialRecovery
    }

    public func load() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if tombstoned { return nil }
        if failLoads { throw FakeStoreError.loadProgrammedToFail }
        return blob
    }

    public func loadRecovery() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if tombstoned { return nil }
        return recoveryBlob
    }

    public func save(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if failSaves { throw FakeStoreError.saveProgrammedToFail }
        blob = data
        recoveryBlob = data
        tombstoned = false
        saveCount += 1
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        if failTombstoneWrites { throw FakeStoreError.tombstoneProgrammedToFail }
        tombstoned = true
        blob = nil
        if !failRecoveryRemoval { recoveryBlob = nil }
        clearCount += 1
    }

    /// 测试助手:当前是否有持久化(供断言「清标记后无残留」/「接管后有清单」)。
    public var isPersisted: Bool {
        lock.lock(); defer { lock.unlock() }
        return !tombstoned && (blob != nil || recoveryBlob != nil)
    }

    public var hasStaleRecoveryBlob: Bool {
        lock.lock(); defer { lock.unlock() }
        return tombstoned && recoveryBlob != nil
    }

    public enum FakeStoreError: Error {
        case loadProgrammedToFail
        case saveProgrammedToFail
        case tombstoneProgrammedToFail
    }
}

/// 可编程内存假 ProcessReaper。可预置「某 pid 存活」及其**可执行路径**(供 reap 前身份核验测试),记录 reap 调用序列。
/// reap 后该 pid 即置为不存活(模拟 SIGKILL 生效),故 `waitForOrphanGone` 能收敛。
/// `@unchecked Sendable`:内部状态由 lock 串行化保护。
public final class FakeProcessReaper: ProcessReaper, @unchecked Sendable {
    private let lock = NSLock()
    private var alivePIDs: Set<Int32>
    /// pid → 可执行路径(身份核验用):存活的 pid 才返回其路径;未编程的 pid 返回 nil。
    private var paths: [Int32: String]

    /// reap 调用记录(反孤儿可核验:断言上世代 pid 被强杀;也可断言身份不符时**未**被 reap)。
    public private(set) var reapCalls: [Int32] = []

    /// - Parameters:
    ///   - alive: 声明哪些 pid「当前存活」(模拟上一世代残留孤儿)。
    ///   - paths: 声明存活 pid 的可执行路径(reap 前身份核验:与持久化内核路径比对)。未列出的 pid → executablePath 返回 nil。
    public init(alive: Set<Int32> = [], paths: [Int32: String] = [:]) {
        self.alivePIDs = alive
        self.paths = paths
    }

    public func executablePath(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard alivePIDs.contains(pid) else { return nil }   // 死进程无路径(与真实现语义一致)
        return paths[pid]
    }

    public func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        return alivePIDs.contains(pid)
    }

    public func reap(pid: Int32) {
        guard pid > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        reapCalls.append(pid)
        alivePIDs.remove(pid)   // SIGKILL 生效 → 置为不存活
    }
}
