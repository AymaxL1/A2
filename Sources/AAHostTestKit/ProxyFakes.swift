// AAHostTestKit —— ProcessPort / HTTPPort 假件(让插件域逻辑在零真进程 / 零真网络下可单测)。
// 依赖边:AAHostTestKit → AAPluginSDK(Port 协议)、AAContracts。
//
// 06 票测试金字塔的次 seam:把「拉起/探活/回收」「HTTP 收发」两个 Port 换成可编程假件,
//   即可断言插件的内核编排与 status 组装逻辑(不依赖真 mihomo、真 socket)。
//   * 假 ProcessPort:launch 记录调用并置存活;terminate 记录调用并置死亡;另有 simulateDeath 模拟「外部被杀」。
//   * 假 HTTPPort:按 URL 后缀返回预置 JSON;记录请求序列。

import Foundation
import AAContracts
import AAPluginSDK

/// 可编程假 ProcessPort。记录 launch/terminate 调用序列;可模拟外部死亡(健康检查测试用)。
/// `@unchecked Sendable`:内部状态由 lock 串行化保护。
public final class FakeProcessPort: ProcessPort, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt64 = 1
    private var alive: [UInt64: Bool] = [:]
    /// 句柄 → 合成 pid(08:测试 processID 持久化 + 跨世代 reap 时可核验)。默认从 1000 起分配。
    private var pids: [UInt64: Int32] = [:]
    private var nextPID: Int32 = 1000

    /// 拉起调用记录(路径 + 参数),供断言「拉起被正确调用」。
    public private(set) var launchCalls: [(path: String, args: [String])] = []
    /// 回收调用记录,供反孤儿断言「回收被调用」。
    public private(set) var terminateCalls: [ProcessHandle] = []
    /// 下一次 launch 是否抛错(测拉起失败降级)。
    private var failNextLaunch = false

    public init() {}

    /// 编程:令下一次 launch 抛错。
    public func programNextLaunchToFail() {
        lock.lock(); defer { lock.unlock() }
        failNextLaunch = true
    }

    public enum FakeError: Error { case launchProgrammedToFail }

    public func launch(executablePath: String, arguments: [String]) throws -> ProcessHandle {
        lock.lock(); defer { lock.unlock() }
        if failNextLaunch { failNextLaunch = false; throw FakeError.launchProgrammedToFail }
        launchCalls.append((executablePath, arguments))
        let id = nextID; nextID += 1
        alive[id] = true
        let pid = nextPID; nextPID += 1
        pids[id] = pid
        return ProcessHandle(id: id)
    }

    public func isAlive(_ handle: ProcessHandle) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return alive[handle.id] ?? false
    }

    /// 取句柄的合成 pid(08:供持久化;未知句柄 nil)。
    public func processID(_ handle: ProcessHandle) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        return pids[handle.id]
    }

    public func terminate(_ handle: ProcessHandle) {
        lock.lock(); defer { lock.unlock() }
        terminateCalls.append(handle)
        alive[handle.id] = false
    }

    /// 测试助手:模拟进程「外部被杀」(不经 terminate),用于健康检查「内核死亡可检测」断言。
    public func simulateDeath(_ handle: ProcessHandle) {
        lock.lock(); defer { lock.unlock() }
        alive[handle.id] = false
    }
}

/// 可编程假 HTTPPort。按 URL 后缀(路径)+ 可选 method 返回预置响应;记录请求序列(含 body)。
/// `@unchecked Sendable`:内部状态由 lock 串行化保护。
public final class FakeHTTPPort: HTTPPort, @unchecked Sendable {
    private let lock = NSLock()
    /// 预置响应表:URL 后缀 + 可选 method(nil=任意方法)→ 响应。
    /// method 维度是 09 票新增:GET /configs 与 PUT /configs 后缀相同,靠 method 区分,避免误配。
    private var responses: [(suffix: String, method: HTTPMethod?, resp: HTTPResponse)] = []

    /// 请求记录(方法 + URL + body),供断言「REST 客户端确实按预期打了哪些路径 / 写了什么 body」。
    /// (09 票新增 body:mode.set / node.select 需核验 PUT body 内容,如 {"mode":"global"} / {"name":"NODE-B"}。)
    public private(set) var requests: [(method: HTTPMethod, url: String, body: Data?)] = []

    public init() {}

    /// 预置一个响应:URL 以 `pathSuffix` 结尾(且 method 匹配,nil=任意)时返回该 JSON。
    public func setResponse(pathSuffix: String, method: HTTPMethod? = nil, statusCode: Int = 200, json: String = "") {
        lock.lock(); defer { lock.unlock() }
        responses.append((pathSuffix, method, HTTPResponse(statusCode: statusCode, body: Data(json.utf8))))
    }

    public enum FakeError: Error, Equatable { case noPreset(String) }

    public func send(method: HTTPMethod, url: String, body: Data?) throws -> HTTPResponse {
        lock.lock(); defer { lock.unlock() }
        requests.append((method, url, body))
        // 按「路径」后缀匹配:先剥掉 query(如 /group/<g>/delay?url=&timeout= 的 ?… 部分),
        // 否则带 query 的 URL 不以 "/delay" 结尾会漏配。method 维度另做精确区分(GET/PUT 同路径)。
        let pathPart = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        for entry in responses where pathPart.hasSuffix(entry.suffix) && (entry.method == nil || entry.method == method) {
            return entry.resp
        }
        throw FakeError.noPreset(url)
    }
}
