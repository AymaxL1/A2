// AAAgentSystem —— `AgentPort` 的生产实现(真进程 + 真进程组 + 真管道 + 反孤儿兜底)。
// 依赖边:AAAgentSystem → **AAAgentCore**(+ 系统 Foundation/Darwin)。
//   本文件是本 target 的全部源码,它一行 `import AAContracts` 都没有 —— 故 Package.swift 里也**不声明**
//   AAContracts(本仓口径:声明的依赖边必须与源码实际 import 一一对应,声明必须真连通,不留空头依赖)。
//   **绝不 import 任何 AAHost***(check.sh 断言组 3e 按目录 grep 把关):本 target 只是 AAAgentCore 的薄桥接层,
//   把「拉起 / 读流 / 探活 / 终止」四件副作用落到真 POSIX 上,纯逻辑核 AAAgentCore 一行系统调用都不碰。
//
// ============ 为什么不用 Foundation `Process`(本文件最要害的技术判断)============
// Foundation 的 `Process` **没有**设置子进程组的公开 API,子进程会**继承宿主的进程组**。
// 那样 `kill(-pgid, …)` 会连宿主自己一起杀掉 —— 票面要的「连带杀 agent 派生的子进程树」根本做不到。
// 故这里用 `posix_spawn` + `POSIX_SPAWN_SETPGROUP` + `posix_spawnattr_setpgroup(&attr, 0)`,
// 让子进程**自成进程组组长**(pgid == pid),之后 `kill(-pgid, SIGTERM/SIGKILL)` 才够得着整棵子树。
// 兜底核验:拉起后 `getpgid(pid) == pid` 且 `pid != getpgrp()` 才认「本端口拥有该组」(`ownsProcessGroup`);
//   一旦核验不过就**降级为按 pid 单杀**,绝不把信号发给一个可能是宿主自己的进程组(这是最不能错的一步)。
//
// ============ 反孤儿铁律(样板 = AAHostMacOS/SystemProcessPort.swift)============
// macOS 无 PR_SET_PDEATHSIG,宿主死后子进程会被 launchd 收养 → 由**父侧退出钩子**兜底:
//   * atexit —— 正常退出(含 exit(n))路径回收;
//   * signal(SIGTERM/SIGINT/SIGHUP) —— 被 kill/Ctrl-C 时回收后重抛(退出码反映信号)。
// 与样板的唯一差别:样板按 **pid** 发 SIGKILL,本端口按 **进程组**(`kill(-pgid, SIGKILL)`)—— 才连带杀子进程树。
// 信号处理器只能用异步信号安全原语:故把「要杀的目标」另存进一块顶层全局定长缓冲(kill/signal/raise 皆 async-signal-safe),
//   处理器只遍历它发 SIGKILL,不取锁、不分配、不碰 Swift 运行时对象。
// 缓冲里存的是**可直接交给 kill(2) 的目标值**:拥有进程组时存 `-pgid`(整组),降级时存 `pid`(单进程)。
//
// 记债(本票不修):宿主被 `kill -9` 强杀时 atexit 与信号钩子都不触发,此路径的孤儿兜底归「下次启动扫残留」
//   (04 票 `scanOrphans` 已按 meta.pid 判崩溃残留,07 票接线时可顺带清进程)。
//
// ============ 与既有 SystemProcessPort 的钩子共存 ============
// 两个 target 各自装一套退出钩子,`signal()` 后装的会**顶掉**先装的。故本处理器保存前一个处理器并在自己杀完后
//   **链式调用**它(见 gAAAgentSignalHandler),不让 AAHostMacOS 的内核反孤儿钩子被静默废掉。
//
// 记债(**两套反孤儿钩子的合流问题归 07 票** —— 第一次让 `SystemProcessPort` 与 `SystemAgentPort` 进同一进程的那张票):
//   本票只做得到**单侧**缓解:本端口保存前手并链式调用(上面那段)。但 `AAHostMacOS.SystemProcessPort` 那侧是
//   裸 `signal(SIGTERM/SIGINT/SIGHUP, handler)`、**不保存也不链式调用**前手。于是若它**后**初始化,
//   它会顶掉本票的信号钩子;而信号死亡路径**不跑 atexit**(atexit 只在 exit(3) 路径跑),
//   → 宿主被 kill/Ctrl-C 时本端口拉起的整棵 agent 进程树无人回收,整树成孤儿。
//   正解是给 `SystemProcessPort` 补对称的 save + chain(与本文件同款)—— 等 v1-core-proxy 的并行红线解冻后由 07 票做。
//   **本票绝不修改 AAHostMacOS**(并行红线),故此处只记债、不动手。
//
// ============ nextEvent 的阻塞语义(01 票 CR 钉死的硬要求)============
// 「进程还活着但此刻没有输出」→ **必须阻塞**到读出一整行或 EOF;**只有** EOF / 进程已死且缓冲读空 / 句柄未知 → nil。
// 写成「没数据就返回 nil」会让 05 票的看门狗把「暂无输出」误读成流终止。实现:对 stdout fd 做**阻塞** read(2),
//   内部维持逐句柄的行缓冲;读到 \n 切一行返回;read 返回 0(EOF)时把剩余不完整尾行(若非空)返回一次,之后恒 nil。
//
// ============ 并发结构(别写出自锁)============
// `nextEvent` 会长时间阻塞在 read 上,**绝不在阻塞期间持有端口的全局映射锁** —— 否则同期的 `terminate()`(取消路径)
//   会被卡死、取消失效。故:`mapLock` 只在查表的一瞬持有;`AgentProcessRecord` 是 final class,自带 ioLock/stateLock,
//   阻塞读发生在 mapLock 之外。`terminate` 全程不碰 ioLock,所以它永远不会被一个正阻塞的读者挡住。

import Foundation
import Darwin
import AAAgentCore

// ============ 反孤儿:全局「待杀目标」缓冲 + 单一共享锁 ============

/// 反孤儿目标缓冲容量(并发 agent 任务数远小于此)。
private let kAAAgentMaxTargets = 128

/// 已拉起且**尚未确认回收**的目标缓冲(0 = 空槽)。存的是可直接交给 kill(2) 的值:
/// 拥有进程组时为 `-pgid`(杀整组、连带子进程树),降级时为 `pid`(只杀那一个)。
/// 所有 record/unrecord 都在下面的**单一共享锁**内串行;信号处理器不取锁、只读遍历(异步信号安全:
/// pid_t 为对齐 32 位,读单值不撕裂;最坏漏杀一个已在别处回收的槽)。
private let gAAAgentTargets: UnsafeMutablePointer<pid_t> = {
    let p = UnsafeMutablePointer<pid_t>.allocate(capacity: kAAAgentMaxTargets)
    p.initialize(repeating: 0, count: kAAAgentMaxTargets)
    return p
}()

/// 安装钩子前保存的前一个信号处理器(按信号号索引;0 槽留空)。存原始位模式,便于在处理器里免 Equatable 比较。
/// 用途:本处理器杀完自己的进程组后**链式调用**它,避免顶掉 AAHostMacOS 的内核反孤儿钩子。
private let gAAAgentPrevHandlers: UnsafeMutablePointer<UInt> = {
    let p = UnsafeMutablePointer<UInt>.allocate(capacity: 64)
    p.initialize(repeating: 0, count: 64)
    return p
}()

/// 保护 gAAAgentTargets 全部 record/unrecord 的**单一共享锁**(模块级一把,非每实例各一把)。
private let gAAAgentTargetLock = NSLock()

/// 登记一个待杀目标(占一个空槽)。在共享锁内。
private func aaAgentRecordTarget(_ target: pid_t) {
    gAAAgentTargetLock.lock(); defer { gAAAgentTargetLock.unlock() }
    for i in 0..<kAAAgentMaxTargets where gAAAgentTargets[i] == 0 { gAAAgentTargets[i] = target; return }
}

/// 摘除目标(清所有匹配槽)。在共享锁内。**仅在确认目标已被回收后调用**。
/// 摘除时机的正确性论证见 `terminate`:leader 收尸前进程组不会被内核复用,故摘除窗口内不可能误伤别人。
private func aaAgentUnrecordTarget(_ target: pid_t) {
    gAAAgentTargetLock.lock(); defer { gAAAgentTargetLock.unlock() }
    for i in 0..<kAAAgentMaxTargets where gAAAgentTargets[i] == target { gAAAgentTargets[i] = 0 }
}

/// 信号处理器:SIGKILL 掉全部仍在缓冲的目标 → 链式调用前一个处理器(若有)→ 恢复默认处置 → 重抛。
/// 只用 kill / signal / raise 与一次函数指针调用(均 async-signal-safe);不取锁、不触碰 Swift 运行时。
private let gAAAgentSignalHandler: @convention(c) (Int32) -> Void = { sig in
    for i in 0..<kAAAgentMaxTargets {
        let t = gAAAgentTargets[i]
        if t != 0 { kill(t, SIGKILL) }
    }
    // 链式调用前一个处理器(典型是 AAHostMacOS 的内核反孤儿钩子):它会自己 SIG_DFL + raise 收尾。
    // 判据用裸位模式,避开 C 函数指针不可 Equatable:SIG_DFL=0 / SIG_IGN=1 / SIG_ERR=UInt.max,
    // 真实代码指针恒远大于 8。
    if sig > 0 && sig < 64 {
        let raw = gAAAgentPrevHandlers[Int(sig)]
        if raw > 8 && raw != UInt.max {
            let prev = unsafeBitCast(raw, to: (@convention(c) (Int32) -> Void).self)
            prev(sig)
        }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

/// atexit 处理器:正常退出路径回收全部仍在缓冲的目标(SIGKILL 保证确定性回收)。
private let gAAAgentAtexitHandler: @convention(c) () -> Void = {
    for i in 0..<kAAAgentMaxTargets {
        let t = gAAAgentTargets[i]
        if t != 0 { kill(t, SIGKILL) }
    }
}

// ============ 错误类型 ============

/// 拉起失败的成因(全部带 errno 与人读描述,便于 07 票把失败如实写进任务 meta.error)。
public enum SystemAgentPortError: Error, CustomStringConvertible {
    /// posix_spawn 失败(可执行不存在 / 不可执行 / 工作目录不存在 / fork 资源不足…)。
    case spawnFailed(path: String, code: Int32)
    /// 建管道失败(fd 耗尽等)。
    case pipeFailed(code: Int32)
    /// 子进程启动动作(file actions)注册失败 —— 典型是 ENOMEM。
    /// **必须抛,不能吞**:注册期失败会让对应 action 整条缺席,而 posix_spawn 本身照样成功 ——
    /// 于是 addchdir 缺席 = 子进程跑在**宿主的 cwd** 里、adddup2 缺席 = 子进程的 stdout 接到宿主自己的 fd 上。
    /// 「绝不静默换个目录干活」是本票的测试断言串明写的红线,故这里 fail-closed。
    case spawnSetupFailed(stage: String, code: Int32)

    public var description: String {
        switch self {
        case let .spawnFailed(path, code):
            return "拉起 agent 进程失败:\(path)(errno=\(code) \(String(cString: strerror(code))))"
        case let .pipeFailed(code):
            return "建管道失败(errno=\(code) \(String(cString: strerror(code))))"
        case let .spawnSetupFailed(stage, code):
            return "配置子进程启动动作失败:\(stage)(errno=\(code) \(String(cString: strerror(code))))"
        }
    }
}

// ============ 单个子进程的记账 ============

/// 一个已拉起子进程的全部状态(fd / pgid / 行缓冲 / 收尸标记)。
/// 刻意做成 final class:端口的 `mapLock` 只用于查表,取到本对象后一切阻塞操作都在**端口锁之外**发生。
final class AgentProcessRecord: @unchecked Sendable {
    /// 子进程 pid(== 进程组 id,子进程自成组长)。
    let pid: pid_t
    /// 进程组 id。`ownsGroup` 为真时等于 pid。
    let pgid: pid_t
    /// 是否确认本端口拥有该进程组(拉起后经 getpgid 核验)。为假时一切信号降级为按 pid 单发。
    let ownsGroup: Bool
    /// 反孤儿缓冲里登记的目标值(`ownsGroup ? -pgid : pid`)。
    var killTarget: pid_t { ownsGroup ? -pgid : pid }

    /// 只保护 stdout 读路径(nextLine 会长时间阻塞在 read 上;terminate 全程不碰这把锁,故不会被读者挡住)。
    private let ioLock = NSLock()
    /// 保护 fd / 标记等短临界区状态。
    private let stateLock = NSLock()

    private var stdoutFD: Int32
    private var stdinFD: Int32          // -1 = 无 stdin 管道 / 已关
    private var lineBuffer: [UInt8] = []
    private var eofReached = false      // 只在 ioLock 内读写
    private var stdoutClosed = false    // stateLock:stdout fd 是否已关(EOF 时由读侧自己关)
    /// stateLock:是否已经有人对 stdout 发起过 read(2)。**只增不减**。
    /// 唯一用途是 `closeAllFDs` 的安全判据:一旦有过读者,就可能此刻正阻塞在 read 上,那时**绝不能**在它背后关 fd。
    private var stdoutReadStarted = false
    private var reaped = false          // stateLock:leader 是否已 waitpid 收尸
    private var exitStatus: Int32?      // stateLock:收尸拿到的 raw status
    private var stderrBuffer: [UInt8] = []  // stateLock:stderr 排干线程的落点(有上界)
    /// stderr 内存上界:超出后丢最早的字节(诊断关心尾部)。07 票要落 logs/stderr.log 时改为边读边写文件即可。
    private static let stderrCap = 256 * 1024

    init(pid: pid_t, pgid: pid_t, ownsGroup: Bool, stdoutFD: Int32, stdinFD: Int32) {
        self.pid = pid
        self.pgid = pgid
        self.ownsGroup = ownsGroup
        self.stdoutFD = stdoutFD
        self.stdinFD = stdinFD
    }

    // ---- stdout 逐行读(阻塞语义的落点)----

    /// 读下一整行。**进程活着但暂无输出时阻塞**;EOF 后把不完整尾行返回一次,之后恒 nil。
    func nextLine() -> String? {
        ioLock.lock(); defer { ioLock.unlock() }
        while true {
            if let idx = lineBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: lineBuffer[0..<idx], as: UTF8.self)
                lineBuffer.removeFirst(idx + 1)
                return line
            }
            if eofReached {
                if lineBuffer.isEmpty { return nil }
                let tail = String(decoding: lineBuffer, as: UTF8.self)   // EOF 前最后一段没有换行的残行,交回一次
                lineBuffer.removeAll()
                return tail
            }
            stateLock.lock(); let fd = stdoutFD; stdoutReadStarted = true; stateLock.unlock()
            if fd < 0 { markStdoutEOF(); continue }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let n = chunk.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress, raw.count)     // **阻塞** read:没数据就等着,绝不返回「暂无」
            }
            if n > 0 {
                lineBuffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                markStdoutEOF()                          // 写端全关 = 真 EOF
            } else {
                if errno == EINTR { continue }           // 被信号打断,重试(不是流终止)
                markStdoutEOF()                          // 读错(fd 已关等)按 EOF 处置,不抛
            }
        }
    }

    /// 置 EOF 并立刻关掉 stdout 读端(读侧自己关,避免与阻塞中的 read 抢 fd)。仅在 ioLock 内调用。
    private func markStdoutEOF() {
        eofReached = true
        stateLock.lock()
        if !stdoutClosed, stdoutFD >= 0 { close(stdoutFD); stdoutFD = -1; stdoutClosed = true }
        stateLock.unlock()
    }

    /// stdout 的**读端**是否已到 EOF 并被关掉。
    ///
    /// 与 `nextLine() == nil` 的关系(两者**不等价**,别拿它当 drain 循环的条件):
    ///   本属性为真只说明「fd 已 EOF 且已关」;EOF 前那段**没有换行的尾行**此刻可能还在 `lineBuffer` 里等着被交回一次,
    ///   即「`isStdoutDrained == true` 但下一次 `nextLine()` 仍会交回一行」是合法状态。
    ///   反向也不成立:`nextLine()` 返回 nil 时本属性必为真,但要知道这一点就得先阻塞读一次。
    /// 故:**判断「流读完了没有」的唯一权威是 `nextLine()`(端口层是 `nextEvent`)返回 nil**;
    ///   本属性只作**非阻塞诊断**(看门狗/07 票想知道「输出是不是已经断了」又不想消费一行时用)。
    var isStdoutDrained: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stdoutClosed
    }

    // ---- stdin ----

    /// 关闭 stdin 写端(幂等)。Claude stream-json 的收尾动作:关掉写端,agent 才会走完终局。
    func closeStdin() {
        stateLock.lock(); defer { stateLock.unlock() }
        if stdinFD >= 0 { close(stdinFD); stdinFD = -1 }
    }

    var hasOpenStdin: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stdinFD >= 0
    }

    /// 把 payload 全量写进 stdin 写端(处理短写与 EINTR)。取 fd 的一瞬持 stateLock,写入本身在锁外
    /// (写可能阻塞,不该挡住并发的 closeStdin;最坏与 closeStdin 撞上时 write 返回 EBADF,按下面的 break 处置,不崩)。
    ///
    /// 已知上界:payload 超过管道缓冲(64KB)且子进程尚未开始读时会在此阻塞 —— V1 的一行 prompt 远小于该量级;
    /// 真要写大 payload 应改为后台线程分片写(07 票若遇到再改,本票不预支复杂度)。
    func writeToStdin(_ payload: String) {
        stateLock.lock(); let fd = stdinFD; stateLock.unlock()
        guard fd >= 0 else { return }
        let bytes = Array(payload.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if n > 0 { offset += n }
            else if n < 0 && errno == EINTR { continue }
            else { break }   // EPIPE(子进程已死)等:不抛,交由后续 isAlive / 终态判定如实反映
        }
    }

    // ---- 收尸记账 ----

    var isReaped: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return reaped
    }

    /// 记「已收尸」。`status` 为 nil = **拿不到真实退出状态**(典型:并发 terminate 里另一个调用方抢先收尸,
    /// 本次 waitpid 得 ECHILD)—— 此时必须让 `exitCode` 保持 nil 走 fail-closed,**绝不能**用 0 顶上去
    /// (0 会被 04 票 `AgentTaskState.resolve` 读成「正常退出 → completed」,把一次取消误报成成功)。
    ///
    /// **首写生效**:已收过尸就不再改写 status。两个线程同时越过 `terminate` 的 `guard !rec.isReaped`
    /// 是设计上被欢迎的(测试的 defer + 05 看门狗取消 + 07 清理都会调),其中必有一个拿到真状态、另一个拿到 ECHILD;
    /// 若允许覆盖,后到的那个 nil 会把先到的真状态(如 -15)抹掉。首写生效令结论单调:
    /// 先到 nil 时终局是 nil(fail-closed,最坏把成功误报成失败),先到真状态时终局是真状态 —— 两条都不产生「假成功」。
    func markReaped(status: Int32?) {
        stateLock.lock(); defer { stateLock.unlock() }
        let wasReaped = reaped
        reaped = true
        guard !wasReaped else { return }        // 首写生效:已收尸 → 一律不再动 exitStatus
        if let s = status { exitStatus = s }
    }

    /// 退出码:正常退出取 exit status;被信号杀返回**负的信号号**(与 04 票「退出码为负即被信号杀」口径一致)。
    var exitCode: Int32? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let s = exitStatus else { return nil }
        if (s & 0x7f) == 0 { return (s >> 8) & 0xff }    // WIFEXITED / WEXITSTATUS
        return -(s & 0x7f)                               // WIFSIGNALED / -WTERMSIG
    }

    // ---- stderr ----

    func appendStderr(_ bytes: [UInt8], count: Int) {
        stateLock.lock(); defer { stateLock.unlock() }
        stderrBuffer.append(contentsOf: bytes[0..<count])
        if stderrBuffer.count > AgentProcessRecord.stderrCap {
            stderrBuffer.removeFirst(stderrBuffer.count - AgentProcessRecord.stderrCap)
        }
    }

    var stderrText: String {
        stateLock.lock(); defer { stateLock.unlock() }
        return String(decoding: stderrBuffer, as: UTF8.self)
    }

    /// 释放尚未关闭的 fd(reclaim 路径;正常路径下 stdout 由读侧在 EOF 关、stderr 由排干线程在 EOF 关)。
    ///
    /// **stdout 只在「从未有人读过」时才由这里关**,别处一律不关 —— 这是与 `markStdoutEOF`
    /// 「读侧自己关,避免与阻塞中的 read 抢 fd」同一条铁律的另一半:
    ///   close(2) 在 macOS 上**不会唤醒**已经阻塞在该 fd 上的 read;而这个 fd 号会被下一次 `launch` 的 `pipe()`
    ///   立刻复用,那个仍阻塞着的读者于是会从**别的任务的管道**里读出数据(跨任务串流,且没有任何报错)。
    ///   宁可在「调用方违反契约(没读到 EOF 就 reclaim)」时漏一个 fd,也绝不制造串流。
    /// 契约侧的正解见 `SystemAgentPort.reclaim`:reclaim 必须在 `nextEvent` 读到 nil(EOF)之后调用,
    ///   那时 stdout 早已由读侧自己关好,这里本就无事可做。
    func closeAllFDs() {
        stateLock.lock(); defer { stateLock.unlock() }
        if stdinFD >= 0 { close(stdinFD); stdinFD = -1 }
        if !stdoutClosed, stdoutFD >= 0, !stdoutReadStarted {
            close(stdoutFD); stdoutFD = -1; stdoutClosed = true
        }
    }
}

// ============ AgentPort 真实现 ============

/// 基于 `posix_spawn` 的生产 `AgentPort`:真进程、真进程组、真管道,取消走进程组 SIGTERM→宽限→SIGKILL,
/// 宿主异常退出由 atexit / 信号钩子兜底 SIGKILL 整组 —— 零孤儿。
///
/// **句柄生命周期契约(调用方须知)**:
/// 1. 每个句柄最终都应调用一次 `terminate`(幂等,已死为 no-op)—— 它才是收尸(waitpid)与摘除反孤儿登记的地方;
/// 2. `terminate` **不关 stdout 读端、不丢句柄记账**:Claude 被中断后会先补 `[Request interrupted]` 再落终态
///    `result` 才退出(01 spike 实证),所以取消之后调用方**仍应把管道读到底**(drain 责任在 05/07 票)。
///    本端口只保证「进程死后 fd 仍能把缓冲读完再 EOF」;
/// 3. `reclaim` 的前置条件是「**`nextEvent` 已经读到 nil(EOF)**且已 `terminate`」——**不是**「terminate 之后即可」。
///    terminate 刻意不关 stdout,那之后往往仍有读者阻塞在 read 上;在它背后关 fd 会导致该 fd 号被下一次 launch
///    复用后串流(理由见 `AgentProcessRecord.closeAllFDs`)。不调 `reclaim` 也不漏 fd(读侧 EOF 时自己关)。
public final class SystemAgentPort: AgentPort, @unchecked Sendable {
    /// 保护 records/nextID。**只在查表的一瞬持有**,绝不跨越阻塞 read / waitpid 轮询(否则取消会被卡死)。
    private let mapLock = NSLock()
    private var records: [UInt64: AgentProcessRecord] = [:]
    private var nextID: UInt64 = 1

    /// SIGTERM 优雅期与随后回收轮询上界(秒)。默认对两家 agent 足够、又不拖慢取消。
    private let sigtermGrace: Double
    private let reapWait: Double

    public init(sigtermGrace: Double = 1.5, reapWait: Double = 1.5) {
        self.sigtermGrace = sigtermGrace
        self.reapWait = reapWait
        SystemAgentPort.installHooksOnce()
    }

    // ---- 进程级只装一次退出钩子(即使构造多个实例)----
    private static let hooksLock = NSLock()
    private static var hooksInstalled = false
    private static func installHooksOnce() {
        hooksLock.lock(); defer { hooksLock.unlock() }
        if hooksInstalled { return }
        hooksInstalled = true
        // async-signal-safety:先触碰两块全局缓冲,强制其惰性初始化(swift_once + allocate)在安装 handler **之前**完成。
        // 否则若信号落在首次 launch 之前,handler 内首次访问会触发 swift_once/allocate(非 async-signal-safe)。
        gAAAgentTargets[kAAAgentMaxTargets - 1] = gAAAgentTargets[kAAAgentMaxTargets - 1]
        gAAAgentPrevHandlers[0] = gAAAgentPrevHandlers[0]
        atexit(gAAAgentAtexitHandler)
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            let prev = signal(sig, gAAAgentSignalHandler)          // 保存前一个处理器,处理器里链式调用它
            gAAAgentPrevHandlers[Int(sig)] = unsafeBitCast(prev, to: UInt.self)
        }
    }

    // ---- launch ----

    public func launch(_ spec: AgentLaunchSpec) throws -> AgentProcessHandle {
        // ① 建三根管道(stdout/stderr 恒建;stdin 仅 writeThenKeepOpen 时建)。
        //    父侧两端一律置 FD_CLOEXEC:dup2 到子进程 0/1/2 时该标志会被清掉,故不影响子进程,
        //    但能防止这些 fd 泄漏进**后续**别的 posix_spawn 的子进程(泄漏一个写端就等于永远读不到 EOF)。
        //    注意 `pipe()` 与这里的 `fcntl` **不是原子的**:两次 launch 并发时,另一线程的 spawn 可能恰落在窗口内。
        //    该竞态由 ③ 的 `POSIX_SPAWN_CLOEXEC_DEFAULT` 从构造上封死;本圈 fcntl 保留作纵深防御(见 ③ 的说明)。
        var outFDs: [Int32] = [-1, -1]
        var errFDs: [Int32] = [-1, -1]
        var inFDs: [Int32] = [-1, -1]
        func closeAll() {
            for fd in outFDs + errFDs + inFDs where fd >= 0 { close(fd) }
        }
        guard pipe(&outFDs) == 0 else { throw SystemAgentPortError.pipeFailed(code: errno) }
        guard pipe(&errFDs) == 0 else { let e = errno; closeAll(); throw SystemAgentPortError.pipeFailed(code: e) }
        var wantsStdinPipe = false
        if case .writeThenKeepOpen = spec.stdin {
            wantsStdinPipe = true
            guard pipe(&inFDs) == 0 else { let e = errno; closeAll(); throw SystemAgentPortError.pipeFailed(code: e) }
        }
        for fd in outFDs + errFDs + inFDs where fd >= 0 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // 写 stdin 时不要因子进程先死而收 SIGPIPE 把宿主打死(write 改为返回 EPIPE)。
        if inFDs[1] >= 0 { _ = fcntl(inFDs[1], F_SETNOSIGPIPE, 1) }

        // ② file actions:接管子进程的 0/1/2。
        //    **每一步都判返回码**:posix_spawn_file_actions_* 直接返回 errno(不经全局 errno),注册期 ENOMEM 时
        //    对应 action 会整条缺席而 posix_spawn 依旧成功 —— addchdir 缺席 = 子进程在**宿主的 cwd** 里开跑,
        //    adddup2 缺席 = 子进程的 stdout 接到宿主自己的 fd 上。两者都是静默走偏,故一律 fail-closed 抛错。
        var fileActions: posix_spawn_file_actions_t?
        let faInitRC = posix_spawn_file_actions_init(&fileActions)
        guard faInitRC == 0 else {
            closeAll()
            throw SystemAgentPortError.spawnSetupFailed(stage: "file_actions_init", code: faInitRC)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        func requireAction(_ stage: String, _ rc: Int32) throws {
            guard rc == 0 else {
                closeAll()
                throw SystemAgentPortError.spawnSetupFailed(stage: stage, code: rc)
            }
        }
        try requireAction("adddup2(stdout→1)", posix_spawn_file_actions_adddup2(&fileActions, outFDs[1], 1))
        try requireAction("adddup2(stderr→2)", posix_spawn_file_actions_adddup2(&fileActions, errFDs[1], 2))
        switch spec.stdin {
        case .devNull:
            // Codex exec 若不给 stdin 会**静默挂起**(02 spike 实证),故直接把 /dev/null 接进去。
            try requireAction("addopen(/dev/null→0)",
                              posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0))
        case .writeThenKeepOpen:
            try requireAction("adddup2(stdin→0)", posix_spawn_file_actions_adddup2(&fileActions, inFDs[0], 0))
        }
        // 工作目录:posix_spawn 没有 POSIX 标准的 chdir,用 Darwin 的 _np 版(macOS 10.15+,本包 min target 13)。
        if !spec.workingDirectory.isEmpty {
            try requireAction("addchdir_np(\(spec.workingDirectory))",
                              posix_spawn_file_actions_addchdir_np(&fileActions, spec.workingDirectory))
        }

        // ③ attr:让子进程**自成进程组组长**(pgid == pid)。这一步是整张票的地基。
        //    另加 `POSIX_SPAWN_CLOEXEC_DEFAULT`(Darwin 专属;本实现已在用同为 Darwin 专属的 addchdir_np,无额外成本):
        //    除上面 file actions 里显式处理过的 fd 外,子进程一律不继承任何 fd。这封死的是 `pipe()` 与随后
        //    `fcntl(FD_CLOEXEC)` **非原子**留下的竞态窗口 —— 两次 launch 并发时,另一线程的 posix_spawn 可能恰好落在
        //    本次 pipe() 与 fcntl() 之间,把本次 stdout 的**写端**继承进一个无关子进程;那个子进程只要不退出,
        //    本任务的 stdout 就永远等不到 EOF(被无关进程钉住),drain 直接挂住。上面那圈 fcntl 保留不删(纵深防御:
        //    它还管着本进程内**其它**代码路径的 fork/spawn,例如 07 票合流后同进程里的 Foundation `Process`)。
        //    与 attr 的返回码口径:setflags/setpgroup 万一失败也不抛 —— 下面 ⑤ 有对 `getpgid` 的**运行时核验**,
        //    核验不过即降级按 pid 单杀,比抛错更保守也更如实(这是这两个调用与 file actions 的区别所在)。
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        _ = posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        _ = posix_spawnattr_setpgroup(&attr, 0)          // 0 = 用子进程自己的 pid 当 pgid

        // ④ argv / envp。环境**如实取自 spec.environment,不隐式继承宿主环境** ——
        //    「每任务独立 $CODEX_HOME」的前提就是调用方对环境有完全掌控;要继承什么由 07 票在 spec 里显式写明。
        var argv: [UnsafeMutablePointer<CChar>?] = ([spec.executablePath] + spec.arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = spec.environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, spec.executablePath, &fileActions, &attr, &argv, &envp)
        if rc != 0 {
            closeAll()
            throw SystemAgentPortError.spawnFailed(path: spec.executablePath, code: rc)
        }

        // ⑤ 核验进程组真的建起来了 —— 核验不过就降级按 pid 单杀,**绝不**把信号发给可能是宿主自己的组。
        //    getpgid 返回 -1 只说明子进程已经退出(无从核验),此时 pid 不可能等于宿主组 id,故仍可安全按组发。
        let actualPGID = getpgid(pid)
        let ownsGroup = (actualPGID == pid || actualPGID == -1) && pid != getpgrp()

        // ⑥ 先登记进反孤儿缓冲(退出钩子立刻够得着),再关子进程侧的管道端、建记账。
        let rec = AgentProcessRecord(pid: pid, pgid: pid, ownsGroup: ownsGroup,
                                     stdoutFD: outFDs[0], stdinFD: wantsStdinPipe ? inFDs[1] : -1)
        aaAgentRecordTarget(rec.killTarget)

        // 父侧必须关掉子进程那一端的写端,否则 stdout/stderr 永远等不到 EOF。
        close(outFDs[1]); outFDs[1] = -1
        close(errFDs[1]); errFDs[1] = -1
        if inFDs[0] >= 0 { close(inFDs[0]); inFDs[0] = -1 }

        // ⑦ stderr 必须有人排干,否则子进程写满管道缓冲(64KB)就整个卡住 —— 本票至少不能让它阻塞。
        //    专用线程阻塞读到 EOF 后自己关 fd(不与终止路径抢 fd);内容留在记账里,供 07 票落 logs/stderr.log。
        let errReadFD = errFDs[0]
        let drainThread = Thread { [weak rec] in
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = chunk.withUnsafeMutableBytes { raw -> Int in read(errReadFD, raw.baseAddress, raw.count) }
                if n > 0 { rec?.appendStderr(chunk, count: n) }
                else if n < 0 && errno == EINTR { continue }
                else { break }
            }
            close(errReadFD)
        }
        drainThread.name = "AAAgentSystem.stderr-drain"
        drainThread.start()

        // ⑧ stdin 处置:writeThenKeepOpen 写入一行后**保持写端打开**(Claude stream-json 下进程不自退,
        //    由适配层显式 closeStdin 收尾);devNull 已在 file actions 里接好,无事可做。
        if case let .writeThenKeepOpen(payload) = spec.stdin {
            rec.writeToStdin(payload.hasSuffix("\n") ? payload : payload + "\n")   // 补 \n,除非串已自带
        }

        mapLock.lock()
        let id = nextID; nextID += 1
        records[id] = rec
        mapLock.unlock()
        return AgentProcessHandle(id: id)
    }

    // ---- nextEvent ----

    /// 读下一条原始事件行。**进程活着但暂无输出时阻塞**到读出一整行或 EOF;
    /// 只有 EOF(且缓冲读空)/ 未知句柄才返回 nil —— 「无更多 ≠ 暂无」,这是 05 票看门狗不误判流终止的前提。
    public func nextEvent(_ handle: AgentProcessHandle) -> String? {
        mapLock.lock(); let rec = records[handle.id]; mapLock.unlock()   // 锁只在查表一瞬持有
        guard let rec = rec else { return nil }                          // 未知 / 已释放句柄
        return rec.nextLine()                                            // 阻塞读发生在**端口锁之外**
    }

    // ---- isAlive ----

    /// 句柄对应进程是否存活。未知 / 已回收句柄返回 false。
    /// **刻意不在这里收尸**:僵尸 leader 会把进程组 id 钉住,使后续 `kill(-pgid, …)` 绝无可能落到被复用的别人组上。
    public func isAlive(_ handle: AgentProcessHandle) -> Bool {
        mapLock.lock(); let rec = records[handle.id]; mapLock.unlock()
        guard let rec = rec else { return false }
        if rec.isReaped { return false }
        return !SystemAgentPort.leaderExitedWithoutReaping(rec.pid)
    }

    /// 「leader 是否已退出」但**不收尸**(waitid + WNOWAIT:留着僵尸)。
    private static func leaderExitedWithoutReaping(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        info.si_pid = 0
        let r = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if r == -1 { return true }        // ECHILD 等:已不是可等待的子进程 → 视为已退出
        return info.si_pid != 0           // WNOHANG 且无状态变化时 si_pid 保持 0
    }

    // ---- terminate ----

    /// 终止并回收句柄对应进程(**幂等**:已死 / 未知句柄为 no-op)。
    ///
    /// 顺序:关 stdin → `kill(-pgid, SIGTERM)` → 有界宽限期轮询 → 仍活则 `kill(-pgid, SIGKILL)` →
    ///      **再向整组补一刀 SIGKILL**(收拾不理 SIGTERM 的孙进程)→ waitpid 收尸 → 摘除反孤儿登记。
    ///
    /// 为什么补的那一刀绝不会误伤别人:此刻 leader 还没收尸(僵尸仍是该进程组的成员),内核就不会回收该 pgid,
    ///   故 `-pgid` 只可能落在我们自己的组上。收尸放在最后一步正是为了守住这个不变量。
    /// 摘除登记同理:SIGKILL 之后组里至多剩僵尸(SIGKILL 不可捕获),僵尸不需要也无法再被杀,故可无条件摘除。
    ///
    /// **注意**:本方法不关 stdout、不丢句柄记账 —— Claude 被中断后会先补 `[Request interrupted]` 再落终态
    ///   `result` 才退出(01 spike 实证),取消之后调用方仍应把管道读到底。
    public func terminate(_ handle: AgentProcessHandle) {
        mapLock.lock(); let rec = records[handle.id]; mapLock.unlock()
        guard let rec = rec else { return }          // 未知 / 已释放句柄 → 幂等 no-op
        rec.closeStdin()                             // 写端一并关(Claude stream-json 的收尾动作之一)
        guard !rec.isReaped else { return }          // 已收过尸 → 幂等 no-op(绝不重复发信号)

        let target = rec.killTarget                  // 拥有进程组时是 -pgid(整组),降级时是 pid
        kill(target, SIGTERM)
        if !waitLeaderExited(rec.pid, deadline: sigtermGrace) {
            kill(target, SIGKILL)                    // 不理会 SIGTERM 的进程的兜底强杀
            _ = waitLeaderExited(rec.pid, deadline: reapWait)
        }
        kill(target, SIGKILL)                        // 组内幸存的孙进程兜底(leader 未收尸,pgid 被钉住,不会误伤)

        // 有界收尸:SIGKILL 之后收不到只可能是内核不可中断态,绝不阻塞门禁/取消路径。
        //
        // `reapedStatus` 刻意是 Int32? 而不是复用初值 0 的 `status`:waitpid 返回 -1(典型是 **ECHILD** ——
        //   并发的另一个 terminate 已抢先收尸)时我们**根本没拿到**退出状态,此时必须交 nil 让 `exitCode` 保持 nil、
        //   由 04 票 `resolve` 走 fail-closed;若沿用 status 的初值 0,一次「被 SIGTERM 杀」会被记成 exitCode 0,
        //   即**把取消误报成成功** —— 04 票注释明文禁止的方向(宁可把成功误报为失败,绝不把失败误报为成功)。
        var status: Int32 = 0
        var reaped = false
        var reapedStatus: Int32?
        let end = Date().addingTimeInterval(reapWait)
        repeat {
            let r = waitpid(rec.pid, &status, WNOHANG)
            if r == rec.pid { reaped = true; reapedStatus = status; break }
            if r == -1 && errno != EINTR { reaped = true; reapedStatus = nil; break }  // ECHILD:已被别人回收,状态未知
            usleep(20_000)
        } while Date() < end

        if reaped {
            rec.markReaped(status: reapedStatus)     // 首写生效:后到的 nil 抹不掉先到的真状态
            aaAgentUnrecordTarget(target)            // 已确认回收才摘除;摘不掉的情况下退出钩子仍兜底
        }
    }

    /// 轮询 leader 是否退出(不收尸)。返回是否已退出。
    private func waitLeaderExited(_ pid: pid_t, deadline: Double) -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if SystemAgentPort.leaderExitedWithoutReaping(pid) { return true }
            usleep(20_000)   // 20ms
        }
        return SystemAgentPort.leaderExitedWithoutReaping(pid)
    }

    // ---- 协议之外的生产接线面(07 票要用;都对未知句柄安全 no-op)----

    /// 显式关闭 stdin 写端(幂等)。**Claude stream-json 的收尾路径**:适配层写完 prompt 后由它决定何时关;
    /// `terminate` 也会一并关闭,故取消路径不必额外调用。
    public func closeStdin(_ handle: AgentProcessHandle) {
        mapLock.lock(); let rec = records[handle.id]; mapLock.unlock()
        rec?.closeStdin()
    }

    /// 子进程 pid(04 票 `AgentTaskMeta.pid` 的来源:宿主重启后句柄没了,只剩 pid 能判崩溃残留)。
    public func processIdentifier(_ handle: AgentProcessHandle) -> Int32? {
        mapLock.lock(); let rec = records[handle.id]; mapLock.unlock()
        return rec?.pid
    }

    /// 子进程组 id(正常情况下 == pid,子进程自成组长)。诊断 / 测试用:`kill(-pgid, 0)`、`ps -g` 可核验整组无残留。
    public func processGroupIdentifier(_ handle: AgentProcessHandle) -> Int32? {
        mapLock.lock(); let rec = records[handle.id]; mapLock.unlock()
        return rec?.pgid
    }

    /// 是否确认拥有该进程组(SETPGROUP 真生效)。为假表示已降级为按 pid 单杀,连带杀子进程树的保证不成立。
    public func ownsProcessGroup(_ handle: AgentProcessHandle) -> Bool {
        mapLock.lock(); let rec = records[handle.id]; mapLock.unlock()
        return rec?.ownsGroup ?? false
    }

    /// 退出码(须已 `terminate` 收尸才有值):正常退出为 exit status,被信号杀为**负的信号号**
    /// —— 与 04 票 `AgentTaskState.resolve`「退出码为负即被信号杀 → cancelled」的口径一致。
    public func exitCode(_ handle: AgentProcessHandle) -> Int32? {
        mapLock.lock(); let rec = records[handle.id]; mapLock.unlock()
        return rec?.exitCode
    }

    /// 已排干的 stderr 文本(供 07 票落 `logs/stderr.log`;超过 256KB 时保留尾部)。
    public func drainedStderr(_ handle: AgentProcessHandle) -> String {
        mapLock.lock(); let rec = records[handle.id]; mapLock.unlock()
        return rec?.stderrText ?? ""
    }

    /// stdout 的读端是否已到 EOF(**非阻塞诊断**面)。
    ///
    /// 与 `nextEvent` 的关系 —— 两者**不等价**,别拿它当 drain 循环的条件:
    ///   为真只说明「fd 已 EOF 且已关」,EOF 前那段没有换行的尾行此刻可能还在行缓冲里等着被 `nextEvent` 交回一次;
    ///   反向则成立:`nextEvent` 返回 nil 时本方法必为真。
    ///   **判断「流读完了没有」的唯一权威是 `nextEvent` 返回 nil**(它也是 `reclaim` 的前置条件);
    ///   本方法只回答「输出是不是已经断了」而不消费一行(看门狗/诊断用)。未知句柄返回 true。
    public func isStdoutDrained(_ handle: AgentProcessHandle) -> Bool {
        mapLock.lock(); let rec = records[handle.id]; mapLock.unlock()
        return rec?.isStdoutDrained ?? true
    }

    /// 释放句柄记账(关掉仍开着的 fd 并从映射删除)。之后 `isAlive` 恒 false、`nextEvent` 恒 nil、
    /// `terminate` 为 no-op —— 语义不变,只是退出码 / stderr 不再取得回。
    ///
    /// **调用时机的硬契约:必须在 `nextEvent` 读到 nil(EOF)之后**(且已 `terminate`)。
    ///   不是「terminate 之后即可」——terminate 刻意不关 stdout,此刻很可能还有读者阻塞在 read 上。
    ///   本方法只清内存记账,不回收进程(那是 `terminate` 的事);对 stdout 也刻意**不**在有读者时强关:
    ///   close 不唤醒阻塞中的 read,而该 fd 号会被下一次 launch 复用,读者就会读到别的任务的管道(见 `closeAllFDs`)。
    ///   故违反契约(没读到 EOF 就 reclaim)的代价是漏一个 fd,而不是串流 —— 这是刻意选的那一边。
    public func reclaim(_ handle: AgentProcessHandle) {
        mapLock.lock(); let rec = records.removeValue(forKey: handle.id); mapLock.unlock()
        rec?.closeAllFDs()
    }

    // ---- 收尸记账的测试探针(仅供门禁断言组 1h 消费)----

    /// **纯内存**的收尸记账探针:不 fork、不开 fd、不发信号,只在内存里造记账对象复现两条并发收尸写序。
    /// 存在的理由:`AgentProcessRecord` 是 target 内部类型,而这两条不变量恰恰是「并发 terminate 把取消误报成成功」
    /// 那个 🔴 的落点,必须能被外部套件逐条断言,又不该为此把内部类型整个 public 出去。
    ///
    /// 返回三元组:
    /// - `echild`:只经历「拿不到状态(ECHILD)」的收尸 → 必须是 **nil**(fail-closed),**绝不能是 0**;
    /// - `real`:拿到真状态(被 SIGTERM 杀)的收尸 → 必须是 **-15**(负值=被信号杀,04 票口径);
    /// - `afterNil`:在上一步之后再补一次 `markReaped(status: nil)` → 必须仍是 **-15**(首写生效,不被抹掉)。
    public static func reapAccountingProbe() -> (echild: Int32?, real: Int32?, afterNil: Int32?) {
        let a = AgentProcessRecord(pid: -1, pgid: -1, ownsGroup: false, stdoutFD: -1, stdinFD: -1)
        a.markReaped(status: nil)                    // 复现 ECHILD 分支
        let echild = a.exitCode

        let b = AgentProcessRecord(pid: -1, pgid: -1, ownsGroup: false, stdoutFD: -1, stdinFD: -1)
        b.markReaped(status: Int32(SIGTERM))         // WIFSIGNALED 的 raw status:低 7 位即信号号
        let real = b.exitCode
        b.markReaped(status: nil)                    // 并发里后到的那一手(ECHILD)
        return (echild, real, b.exitCode)
    }
}
