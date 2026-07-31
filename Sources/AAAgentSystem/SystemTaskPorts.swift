// AAAgentSystem —— 任务生命周期三个端口的**生产实现**(真文件系统 / 真墙钟 / 真 pid 探活)。
// 依赖边:AAAgentSystem → AAAgentCore(+ 系统 Foundation/Darwin)。**绝不 import 任何 AAHost***
//   (check.sh 断言组 3e 按目录 grep 把关)。
//
// 为什么落在本 target 而不是 CLI 里:本 target 的定位就是「把副作用落到真 POSIX 上的薄桥接层」
//   (`SystemAgentPort` 是它的第一件产物)。这三个端口同属副作用,且将来 GUI 宿主(12 票起)也要用 ——
//   放进 aa-agent 可执行里就只有那一个进程用得到了。纯逻辑核 AAAgentCore 依旧一行系统调用都不碰。
//
// 三个实现都**严格按 `AgentTaskPorts.swift` 里写死的语义契约**来,一处都不放宽:
//   假件(FakeFileSystem)比真件宽或窄,都会让 04 全套断言变成自欺 —— 断言绿了、生产上炸了。

import Foundation
import Darwin
import AAAgentCore

/// 真文件系统端口(FileManager / FileHandle)。
///
/// 并发约定:`append` 用一把实例锁串行化。理由很具体 —— 07 票的 run 循环里,读流线程在往
///   `logs/raw.ndjson` / `logs/normalized.ndjson` 追加,而 stderr 是另一条线程排干后落盘的;
///   两条线程若同时对同一个 FileHandle 做「seekToEnd + write」,行与行会互相插进对方中间,
///   ndjson 的「每行一条记录」当场破功。锁的代价是可忽略的(追加是短临界区),破功的代价是日志不可解析。
public final class SystemFileSystem: AgentFileSystemPort, @unchecked Sendable {
    private let lock = NSLock()

    public init() {}

    /// 建目录(含中间目录);已存在为 no-op、不抛(`withIntermediateDirectories: true` 的既有语义)。
    public func createDirectory(at path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    /// 覆盖写整个文件。父目录不存在时如实抛(与契约一致 —— 不替调用方偷偷建目录)。
    ///
    /// 用 `atomically: true`:写 meta.json 时若中途断电 / 崩溃,磁盘上要么是旧的完整一份、要么是新的完整一份,
    ///   绝不会是半截 JSON。meta.json 是任务元数据的唯一真相源,半截即等于整个任务不可读。
    public func write(_ text: String, to path: String) throws {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 写凭据副本:**以 0600 一次性创建**(契约见 `AgentFileSystemPort.writePrivate`)。
    ///
    /// 次序是承重的:**不能**「先 write 再 chmod」—— 那中间存在一个窗口,文件已经带着 umask 默认的
    ///   0644 躺在磁盘上,同机其它用户在这个窗口里就能把 token 读走。`createFile(attributes:)`
    ///   在创建的那一刻就带上权限位,没有这个窗口。
    /// 已存在则先删:`createFile` 对已存在的文件**不会重设权限位**,不删就可能沿用上一次的宽权限。
    public func writePrivate(_ text: String, to path: String) throws {
        guard let data = text.data(using: .utf8) else { throw SystemFileSystemError.notUTF8(path) }
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        guard FileManager.default.createFile(
            atPath: path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            // 失败的典型成因同样是父目录不存在 —— 与契约要求的「父目录不存在则抛错」对上。
            throw SystemFileSystemError.privateWriteFailed(path)
        }
    }

    /// 追加一行(**本实现负责补行尾换行符**,契约明写)。
    ///
    /// 文件不存在时**先建空文件**再追加:契约里专门写了这一条 —— `FileHandle(forWritingAtPath:)` 对不存在的
    ///   文件返回 nil,若不补这一步,用户手滑删掉一个日志文件就会让整条落盘路径开始抛错
    ///   (丢一行日志远轻于把任务打挂)。父目录仍不存在时如实抛。
    public func append(_ line: String, to path: String) throws {
        let payload = line.hasSuffix("\n") ? line : line + "\n"
        guard let data = payload.data(using: .utf8) else {
            throw SystemFileSystemError.notUTF8(path)
        }
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: data) else {
                // createFile 失败的典型成因就是父目录不存在 —— 与契约要求的「父目录不存在则抛错」对上。
                throw SystemFileSystemError.appendFailed(path)
            }
            return
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw SystemFileSystemError.appendFailed(path)
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// 读整个文件为 UTF-8 串;不存在则抛。
    public func read(at path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    public func exists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// 只返回条目名(不含路径、不递归);目录不存在则抛。
    public func listDirectory(at path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }

    /// 递归删除目录;**目录不存在则抛**(与真 `FileManager.removeItem` 同严,假件也是这么模拟的)。
    public func removeDirectory(at path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }
}

/// 真文件系统端口自己的错误(只在 FileManager/FileHandle 不给具体 Error 的两处出现)。
public enum SystemFileSystemError: Error, CustomStringConvertible {
    case notUTF8(String)
    case appendFailed(String)
    case privateWriteFailed(String)

    public var description: String {
        switch self {
        case let .notUTF8(path):            return "写入内容不是合法 UTF-8:\(path)"
        case let .appendFailed(path):       return "追加写失败(父目录可能不存在):\(path)"
        case let .privateWriteFailed(path): return "凭据副本写入失败(父目录可能不存在):\(path)"
        }
    }
}

/// 真墙钟端口。三种表示**一次取全**,避免调用方各自换算出不一致的时间。
///
/// `stamp`(`YYYYMMDD-HHmm`)刻意用**本地时区**:它是 task-id 的时间前缀,给人 `ls` 时认的
///   ——「我下午三点跑的那个任务」应该显示成 15xx,而不是 UTC 的 07xx。
/// `iso8601` 则带时区偏移,是机器面的绝对时刻,两者各司其职。
public final class SystemClock: AgentClockPort, @unchecked Sendable {
    private let stampFormatter: DateFormatter
    private let isoFormatter: ISO8601DateFormatter

    public init() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // 不受用户区域设置影响(阿拉伯数字、公历)
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyyMMdd-HHmm"
        stampFormatter = f
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        isoFormatter = iso
    }

    public func now() -> AgentWallClock {
        let date = Date()
        return AgentWallClock(
            stamp: stampFormatter.string(from: date),
            iso8601: isoFormatter.string(from: date),
            epochSeconds: Int(date.timeIntervalSince1970)
        )
    }
}

/// 真 pid 探活端口(`kill(pid, 0)`)。
///
/// `EPERM` 也算活着:进程存在但不属于当前用户时 `kill` 会以 EPERM 失败 —— 那恰恰证明它还在。
///   把 EPERM 当「已死」会让残留扫描把一个活着的任务标成 `orphaned`(推测覆盖事实,最坏的方向)。
/// 已知限制(与 04 票 `scanForOrphans` 的注释一致):pid 会被系统复用,故这只是「尽力而为」的判据;
///   真正的权威是 run 进程手里的一手证据,04 已放行 `orphaned → 证据终态` 让它能被纠正回来。
public struct SystemProcessLiveness: AgentProcessLivenessPort {
    public init() {}

    public func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
