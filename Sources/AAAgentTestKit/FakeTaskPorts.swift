// AAAgentTestKit —— 任务生命周期三个端口的假件(内存文件系统 / 可编程墙钟 / 可编程 pid 探活)。
// 依赖边:AAAgentTestKit → AAAgentCore、AAContracts(+ 系统 Foundation)。
//
// 有了这三个,04 票的全部断言都跑在纯内存上:**零真实文件系统、零真实时钟、零真实进程**。
//   任何在测试里真去碰 `~/.aa/` 或真读系统时间的写法都是错的 —— 那既让门禁在别人机器上飘,
//   也没法稳定构造「pid 已死」这种关键分支。
//
// 并发约定与写法照 `FakeAgentPort.swift`:`@unchecked Sendable` + `NSLock` 串行化内部状态。

import Foundation
import AAAgentCore

/// 内存文件系统假件。整棵树就是两个集合:路径→内容 的文件字典 + 目录集合。
///
/// 相比「真建个临时目录」的好处不只是快:
/// - 可以**逐路径查写入次数**(`writeCount(at:)` / `appendCount(at:)`)——「标 orphaned 时其余文件一个字节都没动」
///   这类断言才有得证;
/// - 可以**编程某个路径写入必失败**(`programWriteFailure(at:)`),测错误传播不必真去 chmod;
/// - raw.ndjson 与 normalized.ndjson 各自的内容随时取得出,「永不互写」这条红线才验得了。
public final class FakeFileSystem: AgentFileSystemPort, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: String] = [:]
    private var directories: Set<String> = []
    private var failingWrites: Set<String> = []
    private var writeCounts: [String: Int] = [:]
    private var appendCounts: [String: Int] = [:]

    public init() {}

    public enum FakeFileSystemError: Error, Equatable {
        /// 读一个不存在的文件 / 列一个不存在的目录 / 删一个不存在的目录(三处都与真 `FileManager` 同严)。
        case notFound(String)
        /// 往一个父目录还不存在的路径写 —— 真 `FileManager` 也会失败,假件同样不放水
        /// (放水就等于替被测代码把「忘了建目录」这个 bug 藏起来)。
        case parentDirectoryMissing(String)
        /// 被 `programWriteFailure(at:)` 点名的路径。
        case programmedFailure(String)
    }

    // MARK: - 编程 / 探针(测试专用)

    /// 编程:该路径上的 `write` / `append` 一律抛错(测错误传播、测「抛错时磁盘未变」)。
    public func programWriteFailure(at path: String) {
        lock.lock(); defer { lock.unlock() }
        failingWrites.insert(Self.normalize(path))
    }

    /// 探针:删掉某个**文件**(目录请走 `removeDirectory`)。
    /// 用途是构造「meta 写成功但 report.html 没了」这类半截现场 —— 现实里它由「上一次写报告时崩了」
    /// 或「用户手工删了报告」产生,是 `finish` 同态幂等自愈路径的被测输入。
    /// 刻意**不**回退 `writeCount`:补写出来的报告应当让该路径的写次数从 1 变成 2,断言才看得见「真的补写了」。
    public func removeFile(at path: String) {
        lock.lock(); defer { lock.unlock() }
        files.removeValue(forKey: Self.normalize(path))
    }

    /// 取某文件当前内容(不存在为 nil)。
    public func contents(at path: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return files[Self.normalize(path)]
    }

    /// 该路径被**覆盖写**过几次。
    public func writeCount(at path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return writeCounts[Self.normalize(path)] ?? 0
    }

    /// 该路径被**追加**过几次。
    public func appendCount(at path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return appendCounts[Self.normalize(path)] ?? 0
    }

    /// 当前存在的全部文件路径(已排序),供「多出了不该有的文件」这类断言。
    public func allFilePaths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return files.keys.sorted()
    }

    /// 当前存在的全部目录路径(已排序)。
    public func allDirectoryPaths() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return directories.sorted()
    }

    // MARK: - AgentFileSystemPort

    public func createDirectory(at path: String) throws {
        lock.lock(); defer { lock.unlock() }
        // 契约:创建中间目录、已存在为 no-op。
        for ancestor in Self.ancestors(of: Self.normalize(path)) { directories.insert(ancestor) }
    }

    public func write(_ text: String, to path: String) throws {
        let p = Self.normalize(path)
        lock.lock(); defer { lock.unlock() }
        if failingWrites.contains(p) { throw FakeFileSystemError.programmedFailure(p) }
        try requireParentDirectory(of: p)
        files[p] = text
        writeCounts[p] = (writeCounts[p] ?? 0) + 1
    }

    public func append(_ line: String, to path: String) throws {
        let p = Self.normalize(path)
        lock.lock(); defer { lock.unlock() }
        if failingWrites.contains(p) { throw FakeFileSystemError.programmedFailure(p) }
        try requireParentDirectory(of: p)
        // 契约(AgentFileSystemPort.append):真实现负责补行尾换行符;**文件不存在则创建**(此处即 `?? ""` 那半)。
        files[p] = (files[p] ?? "") + line + "\n"
        appendCounts[p] = (appendCounts[p] ?? 0) + 1
    }

    public func read(at path: String) throws -> String {
        let p = Self.normalize(path)
        lock.lock(); defer { lock.unlock() }
        guard let text = files[p] else { throw FakeFileSystemError.notFound(p) }
        return text
    }

    public func exists(at path: String) -> Bool {
        let p = Self.normalize(path)
        lock.lock(); defer { lock.unlock() }
        return files[p] != nil || directories.contains(p)
    }

    public func listDirectory(at path: String) throws -> [String] {
        let p = Self.normalize(path)
        lock.lock(); defer { lock.unlock() }
        guard directories.contains(p) else { throw FakeFileSystemError.notFound(p) }
        let prefix = p + "/"
        var names = Set<String>()
        for candidate in files.keys where candidate.hasPrefix(prefix) {
            if let first = candidate.dropFirst(prefix.count).split(separator: "/").first { names.insert(String(first)) }
        }
        for candidate in directories where candidate.hasPrefix(prefix) {
            if let first = candidate.dropFirst(prefix.count).split(separator: "/").first { names.insert(String(first)) }
        }
        return names.sorted()
    }

    public func removeDirectory(at path: String) throws {
        let p = Self.normalize(path)
        lock.lock(); defer { lock.unlock() }
        // 真 `FileManager.removeItem` 删不存在的路径是**抛错**的,假件同样不放水:
        // 假件比真件宽,就等于替被测代码把「删了个不存在的目录还以为删成了」这类 bug 藏起来。
        guard directories.contains(p) else { throw FakeFileSystemError.notFound(p) }
        let prefix = p + "/"
        // 先收集再删:直接边遍历 keys 边 removeValue 是在迭代中改容器。
        let doomed = files.keys.filter { $0 == p || $0.hasPrefix(prefix) }
        for key in doomed { files.removeValue(forKey: key) }
        directories = directories.filter { $0 != p && !$0.hasPrefix(prefix) }
    }

    // MARK: - 内部

    /// 写之前要求父目录已存在(与真 `FileManager` 同款严格,见 `parentDirectoryMissing` 注释)。
    private func requireParentDirectory(of path: String) throws {
        guard let slash = path.lastIndex(of: "/") else { return }
        let parent = String(path[path.startIndex..<slash])
        guard parent.isEmpty || directories.contains(parent) else {
            throw FakeFileSystemError.parentDirectoryMissing(parent)
        }
    }

    /// 去掉末尾多余的 `/`(`/a/b/` 与 `/a/b` 是同一个目录)。
    private static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// 一个路径自身 + 它的全部祖先(用于模拟 `withIntermediateDirectories: true`)。
    private static func ancestors(of path: String) -> [String] {
        var out: [String] = []
        var current = path
        while true {
            out.append(current)
            guard let slash = current.lastIndex(of: "/") else { break }
            let parent = String(current[current.startIndex..<slash])
            if parent.isEmpty { break }
            current = parent
        }
        return out
    }
}

/// 可编程墙钟假件。按预置序列逐次弹出;**弹完后停在最后一格**(不崩、不回绕)——
/// 测试关心的是「哪几次调用拿到哪个时刻」,多调几次不该把套件打挂。
public final class FakeClock: AgentClockPort, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [AgentWallClock]
    private var index = 0
    private var calls = 0

    /// 按序列编程(至少一格;空序列会退化成一个固定的占位时刻,避免调用方拿不到值)。
    public init(_ script: [AgentWallClock]) {
        self.script = script.isEmpty
            ? [AgentWallClock(stamp: "20260101-0000", iso8601: "2026-01-01T00:00:00Z", epochSeconds: 1_767_225_600)]
            : script
    }

    /// 便利:恒定返回同一个时刻。
    public convenience init(stamp: String, iso8601: String, epochSeconds: Int) {
        self.init([AgentWallClock(stamp: stamp, iso8601: iso8601, epochSeconds: epochSeconds)])
    }

    /// `now()` 被调用过几次(供「finish 只取一次现在」这类断言)。
    public func callCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    public func now() -> AgentWallClock {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        let value = script[min(index, script.count - 1)]
        if index < script.count - 1 { index += 1 }
        return value
    }
}

/// 可编程 pid 探活假件。只有登记为「活着」的 pid 才返回 true,其余一律 false(默认全死)。
public final class FakeLiveness: AgentProcessLivenessPort, @unchecked Sendable {
    private let lock = NSLock()
    private var alivePIDs: Set<Int32>
    private var queried: [Int32] = []

    public init(alive: Set<Int32> = []) { self.alivePIDs = alive }

    /// 编程:替换「活着的 pid」集合。
    public func programAlive(_ pids: Set<Int32>) {
        lock.lock(); defer { lock.unlock() }
        alivePIDs = pids
    }

    /// 被查询过的 pid 序列(供「扫描确实按 pid 探活过」这类断言)。
    public func queriedPIDs() -> [Int32] {
        lock.lock(); defer { lock.unlock() }
        return queried
    }

    public func isAlive(pid: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        queried.append(pid)
        return alivePIDs.contains(pid)
    }
}
