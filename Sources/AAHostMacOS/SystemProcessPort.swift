// AAHostMacOS —— ProcessPort 真实现(特权面归宿主)。基于 Foundation `Process` 拉起子进程 + 反孤儿回收。
// 依赖边:AAHostMacOS → AAPluginSDK(ProcessPort 协议)、Foundation/Darwin。
//
// 06 票反孤儿铁律:宿主进程无论以何种方式退出,都必须回收所有经本 Port 拉起且尚存活的子进程——零孤儿。
// (孤儿 mihomo = 宿主死后系统网络仍被内核代理,是本平台最不能错的地方。)
// macOS 无 PR_SET_PDEATHSIG(子进程不会随父死自动终止,会被 launchd 收养),故由**父侧退出钩子**兜底:
//   * atexit —— 正常退出(含 NSApplication.terminate / exit)路径回收。
//   * signal(SIGTERM/SIGINT/SIGHUP) —— 被 kill/pkill/Ctrl-C 时回收后再以默认处置重抛(退出码反映信号)。
// 退出钩子一律发 **SIGKILL**:即便内核不理会 SIGTERM(见测试的 --ignore-sigterm 用例),也够得着、必被回收。
//
// 记债(本票不修,指向 08 票崩溃自愈):宿主被 `kill -9`(SIGKILL)强杀时,atexit 与信号钩子都**不会触发**,
//   此路径下的孤儿内核在本票内无兜底。正确的兜底归 08 票——下次启动时检测并清理上一世代残留的内核进程。
//
// 信号处理器只能用「异步信号安全」原语:故把子进程 pid 另存进一块顶层全局定长缓冲(kill/signal/raise 皆 async-signal-safe),
// 处理器只遍历它发 SIGKILL,不取锁、不分配、不碰 Swift 运行时对象。

import Foundation
import Darwin
import AAPluginSDK

// ============ 反孤儿:全局 pid 缓冲 + 单一共享锁 ============

/// 反孤儿 pid 缓冲容量(V1 内核只有 1 个,余量充足)。
private let kAAMaxChildPIDs = 128

/// 已拉起且**尚未确认死亡**的子进程 pid 缓冲(0 = 空槽)。
/// 所有 record/unrecord 都在下面的**单一共享锁** `gAAChildLock` 内串行(跨所有 SystemProcessPort 实例共享,消除写写竞态);
/// 信号处理器不取锁、只读遍历(异步信号安全:pid 为对齐 32 位,读单值不撕裂;稳态下与写不重叠,最坏漏杀一个已在别处回收的 slot)。
private let gAAChildPIDs: UnsafeMutablePointer<pid_t> = {
    let p = UnsafeMutablePointer<pid_t>.allocate(capacity: kAAMaxChildPIDs)
    p.initialize(repeating: 0, count: kAAMaxChildPIDs)
    return p
}()

/// 保护 gAAChildPIDs 全部 record/unrecord 的**单一共享锁**(模块级一把,非每实例各一把)。
private let gAAChildLock = NSLock()

/// 登记 pid(占一个空槽)。在共享锁内。
private func aaRecordPID(_ pid: pid_t) {
    gAAChildLock.lock(); defer { gAAChildLock.unlock() }
    for i in 0..<kAAMaxChildPIDs where gAAChildPIDs[i] == 0 { gAAChildPIDs[i] = pid; return }
}
/// 摘除 pid(清所有匹配槽)。在共享锁内。仅在**确认该 pid 对应进程已死**后调用——防 OS 复用 pid 后退出钩子误杀无辜进程。
private func aaUnrecordPID(_ pid: pid_t) {
    gAAChildLock.lock(); defer { gAAChildLock.unlock() }
    for i in 0..<kAAMaxChildPIDs where gAAChildPIDs[i] == pid { gAAChildPIDs[i] = 0 }
}

/// 信号处理器:SIGKILL 掉全部**仍在缓冲**的子进程 → 恢复默认处置 → 重抛(令宿主退出码反映信号)。
/// 只用 kill / signal / raise(均 async-signal-safe);不取锁、不触碰 Swift 运行时。
private let gAAChildSignalHandler: @convention(c) (Int32) -> Void = { sig in
    for i in 0..<kAAMaxChildPIDs {
        let pid = gAAChildPIDs[i]
        if pid > 0 { kill(pid, SIGKILL) }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

/// atexit 处理器:正常退出路径回收全部仍在缓冲的子进程(SIGKILL 保证确定性回收)。
private let gAAChildAtexitHandler: @convention(c) () -> Void = {
    for i in 0..<kAAMaxChildPIDs {
        let pid = gAAChildPIDs[i]
        if pid > 0 { kill(pid, SIGKILL) }
    }
}

// ============ ProcessPort 真实现 ============

/// 基于 Foundation `Process` 的 ProcessPort。持有句柄→Process 映射;并在进程级安装一次退出钩子确保零孤儿。
/// 兼作 `ProcessReaper`(08 崩溃自愈):按原始 pid 探活/强杀上一世代残留内核——同一份 Darwin 进程原语,两个关注点。
public final class SystemProcessPort: ProcessPort, ProcessReaper, @unchecked Sendable {
    /// 保护实例的 processes/nextID(与全局 pid 缓冲锁分离,避免在阻塞等待期间长持全局锁)。
    private let mapLock = NSLock()
    /// 句柄 → (Process, 拉起时捕获的 pid)。显式存 pid,避免依赖「进程退出后 processIdentifier 是否仍返回原 pid」的语义。
    private var processes: [UInt64: (proc: Process, pid: pid_t)] = [:]
    private var nextID: UInt64 = 1

    /// terminate 的 SIGTERM 优雅期与随后回收轮询上界(秒)。默认对内核足够、又不拖慢退出。
    private let sigtermGrace: Double
    private let reapWait: Double

    public init(sigtermGrace: Double = 1.5, reapWait: Double = 1.5) {
        self.sigtermGrace = sigtermGrace
        self.reapWait = reapWait
        SystemProcessPort.installHooksOnce()
    }

    // 进程级只装一次退出钩子(即使构造多个实例)。
    private static let hooksLock = NSLock()
    private static var hooksInstalled = false
    private static func installHooksOnce() {
        hooksLock.lock(); defer { hooksLock.unlock() }
        if hooksInstalled { return }
        hooksInstalled = true
        // async-signal-safety:先触碰全局 pid 缓冲,强制其惰性初始化(swift_once + allocate)在安装 handler **之前**完成。
        // 否则若信号落在首次 launch 之前,handler 内首次访问 gAAChildPIDs 会触发 swift_once/allocate(非 async-signal-safe)。
        gAAChildPIDs[0] = gAAChildPIDs[0]
        atexit(gAAChildAtexitHandler)
        signal(SIGTERM, gAAChildSignalHandler)
        signal(SIGINT, gAAChildSignalHandler)
        signal(SIGHUP, gAAChildSignalHandler)
    }

    public func launch(executablePath: String, arguments: [String]) throws -> ProcessHandle {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        try proc.run()  // 拉起失败(路径不存在/不可执行)抛错,交由上层降级
        let pid = proc.processIdentifier
        // 先登记进缓冲(退出钩子立即够得着),再入映射;二者次序不影响正确性(pid 一旦记入即受兜底保护)。
        aaRecordPID(pid)
        mapLock.lock()
        let id = nextID; nextID += 1
        processes[id] = (proc, pid)
        mapLock.unlock()
        return ProcessHandle(id: id)
    }

    /// 取句柄对应进程的原始 pid(08:接管时把内核 pid 持久化,供下次启动跨世代识别/回收)。
    /// 未知/已回收句柄返回 nil。
    public func processID(_ handle: ProcessHandle) -> Int32? {
        mapLock.lock(); let entry = processes[handle.id]; mapLock.unlock()
        return entry.map { Int32($0.pid) }
    }

    public func isAlive(_ handle: ProcessHandle) -> Bool {
        mapLock.lock(); let entry = processes[handle.id]; mapLock.unlock()
        guard let e = entry else { return false }
        if e.proc.isRunning { return true }
        // 已死(崩溃/被外部杀;Foundation 后台线程已 waitpid 回收僵尸并把 isRunning 置 false)。
        // 清掉这条陈旧句柄与其 pid,防 OS 复用该 pid 后退出钩子误杀无辜进程(pid 复用防误杀)。
        forget(handle: handle, pid: e.pid)
        return false
    }

    public func terminate(_ handle: ProcessHandle) {
        mapLock.lock(); let entry = processes[handle.id]; mapLock.unlock()
        guard let e = entry else { return }   // 未知/已清理句柄 → 幂等 no-op
        let p = e.proc
        let pid = e.pid

        if !p.isRunning {
            // 已死:仅回收记账(Foundation 已 reap)。
            forget(handle: handle, pid: pid)
            return
        }

        // 优雅终止:SIGTERM → 有界等待其退出 → 仍存活则 SIGKILL 兜底 → 等 Foundation 回收僵尸。
        // **关键(修孤儿洞):pid 在整个过程里都留在缓冲中,直到确认死亡后才 unrecord。**
        // 故即便本进程在等待中途自身退出,退出钩子的 SIGKILL 兜底仍够得着不理会 SIGTERM 的内核。
        kill(pid, SIGTERM)
        if !waitUntilExited(p, deadline: sigtermGrace) {
            kill(pid, SIGKILL)                      // SIGTERM-忽略型内核的兜底强杀
            _ = waitUntilExited(p, deadline: reapWait)
        }
        // 确认死亡(或已尽力 SIGKILL)后才摘除 pid + 清映射。
        forget(handle: handle, pid: pid)
    }

    /// 从实例映射删句柄、从全局缓冲清 pid(在确认进程已死后调用)。
    /// Foundation Process 负责真正的 waitpid/reap(其后台监控把 isRunning 置 false),故此处不自行 waitpid(避免与之抢 reap 破坏 isRunning)。
    private func forget(handle: ProcessHandle, pid: pid_t) {
        mapLock.lock(); processes[handle.id] = nil; mapLock.unlock()
        aaUnrecordPID(pid)
    }

    /// 轮询 p.isRunning 直到退出或超时。返回是否已退出。
    private func waitUntilExited(_ p: Process, deadline seconds: Double) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if !p.isRunning { return true }
            usleep(50_000)   // 50ms
        }
        return !p.isRunning
    }

    // ============ ProcessReaper 实现(08:跨世代按原始 pid 探活/身份核验/强杀)============

    /// 某原始 pid 的可执行映像绝对路径(`proc_pidpath`,libproc);pid 不存活 / 无权读取(EPERM,非本用户进程)/ 读失败 → nil。
    /// reap 前的**身份核验**据此:与持久化的内核路径逐字节相等才允许 SIGKILL,杜绝 pid 复用后误杀无辜进程。
    public func executablePath(pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE(4*MAXPATHLEN)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }                 // 死进程 / EPERM(非本用户进程)/ 读失败 → nil(= 不是可确认的我方内核)
        return String(cString: buf)
    }

    /// 某原始 pid 是否存活。`kill(pid, 0)==0` 才算存活;ESRCH(不存在)或 **EPERM(非本用户进程,不是我方内核)** 均视为不存活。
    /// pid <= 0 直接视为不存活。注意:aliveness 只用于 reap 后「等孤儿彻底消失」;是否 reap 由 executablePath 身份核验决定。
    public func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    /// 强杀某原始 pid(SIGKILL 兜底回收上一世代残留孤儿)。**调用方必须已身份核验**(见 selfHeal)。
    /// 孤儿已被 launchd 收养(非本进程子进程),故只发 SIGKILL、由 launchd 回收僵尸;本进程不 waitpid(waitpid 不到非亲生进程)。
    /// 幂等:pid<=0 或已不存在为 no-op。
    public func reap(pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
    }
}
