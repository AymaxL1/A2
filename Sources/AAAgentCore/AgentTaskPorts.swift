// AAAgentCore —— 任务生命周期需要的三个副作用端口(墙钟 / 文件系统 / 按 pid 探活)。
// 依赖边:本文件零 import(全部类型来自 stdlib)。模块级红线同 AgentPort.swift:
//   AAAgentCore 绝不 import 任何 Host* / AAPluginSDK / PluginProxy(check.sh 断言组 3d 用 grep 强制)。
//
// 为什么这三个也要压成端口(而不是在域逻辑里直接 `Date()` / `FileManager` / `kill(pid,0)`):
//   任务状态机与工作区落盘是本适配层**最需要反复回归**的一块(状态迁移合法性、raw≠normalized、
//   残留判定、prune 不误删)。这三样若直接调系统,测试就必须真建目录、真读钟、真起进程——
//   那既慢又不可重复,且「pid 已死」这种关键分支根本没法稳定构造。压到端口之后,
//   04 全票的断言都跑在 `FakeFileSystem` / `FakeClock` / `FakeLiveness` 上:零真实文件系统、零真实时钟、零真实进程。
//
// 与 `AgentPort` 的分工:`AgentPort` 管**一次执行**(拉起 / 读流 / 探活句柄 / 终止);
//   本文件三个端口管**一个任务的生命周期证据**(什么时候、落在哪、进程还在不在)。二者不重叠。

/// 墙钟时刻(已按日历分解成串)。
///
/// **为什么端口交回的是「分解好的串」而不是一个时间戳**:日历换算与时区是副作用中最容易在测试里失控的一类
///   (同一个 epoch 在不同 TZ 下 stamp 不同)。把换算压到端口之后,域逻辑只吃这三个已经定死的值,
///   任务 id 的时间前缀与 meta.json 的时间字段就都是**可逐字断言**的。
public struct AgentWallClock: Sendable, Equatable {
    /// `YYYYMMDD-HHmm` —— task-id 的时间前缀(让 `ls` 天然按时间排序,提案 §1)。
    public let stamp: String
    /// ISO8601 串 —— meta.json 的 `created_at` / `started_at` / `finished_at`。
    public let iso8601: String
    /// Unix 秒 —— 05 票看门狗算静默时长用(本票只落盘,不解释)。
    public let epochSeconds: Int

    public init(stamp: String, iso8601: String, epochSeconds: Int) {
        self.stamp = stamp
        self.iso8601 = iso8601
        self.epochSeconds = epochSeconds
    }
}

/// 墙钟端口。真实现(06/07 票)基于 `Date` + `DateFormatter`;假件 `AAAgentTestKit.FakeClock` 回放可编程序列。
public protocol AgentClockPort: Sendable {
    /// 取当前墙钟时刻(三种表示一次给全,避免调用方各自换算出不一致的时间)。
    func now() -> AgentWallClock
}

/// 工作区落盘的**最小**文件系统面。
///
/// 刻意只有这七个方法:多一个方法就多一份真实现负担、多一处「测试里没覆盖到的系统调用」。
/// 语义契约(真实现必须满足,假件据此模拟):
/// - `createDirectory`:**创建中间目录**(等价 `withIntermediateDirectories: true`);目录已存在为 no-op,不抛。
/// - `write`:**覆盖**写整个文件(meta.json / prompt.md / report.html / changes.md);父目录不存在则抛错。
/// - `append`:**追加一行**——真实现负责补行尾换行符(两个 ndjson 与 stderr.log);父目录不存在则抛错。
///   **文件本身不存在时:创建之**(内容即这一行),不抛。这条不是废话:`create` 虽会先把三个日志文件建成空的,
///   但用户手滑删掉一个日志文件不该让整条落盘路径开始抛错(丢一行日志远轻于把任务打挂);
///   且 06 票若用 `FileHandle(forWritingAtPath:)` 实现追加,文件不存在时它返回 nil / 抛错 ——
///   真实现必须自己补上「不存在则先建空文件」这一步,别让契约与实现各说各话。
/// - `read`:读整个文件为 UTF-8 串;不存在则抛错。
/// - `exists`:文件或目录是否存在(不区分二者:调用方按路径自知)。
/// - `listDirectory`:只返回**条目名**(不含路径、不递归);目录不存在则抛错。
/// - `removeDirectory`:递归删除目录(prune 用);**目录不存在则抛错**(与真 `FileManager.removeItem` 同严)。
public protocol AgentFileSystemPort: Sendable {
    func createDirectory(at path: String) throws
    func write(_ text: String, to path: String) throws
    func append(_ line: String, to path: String) throws
    func read(at path: String) throws -> String
    func exists(at path: String) -> Bool
    func listDirectory(at path: String) throws -> [String]
    func removeDirectory(at path: String) throws
}

/// 按 **pid** 探活 —— 崩溃残留(orphaned)判定的唯一依据。
///
/// **与 `AgentPort.isAlive(句柄)` 不是一回事,不能合并**:句柄只在本次宿主进程的生命周期内有意义,
///   宿主重启(或崩溃)后句柄早没了,磁盘上只剩 meta.json 里记着的 `pid`。
///   残留扫描发生的恰恰是「宿主刚起来、什么句柄都没有」的时刻,故必须有这条**按 pid** 的路。
public protocol AgentProcessLivenessPort: Sendable {
    /// 该 pid 的进程是否仍存活。未知 / 已回收 → false。
    func isAlive(pid: Int32) -> Bool
}
