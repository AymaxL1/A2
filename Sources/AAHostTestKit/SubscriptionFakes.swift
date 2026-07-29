// AAHostTestKit —— 订阅管理假件(10 票):让订阅状态机在零真文件 / 零真网络下可纯逻辑单测。
// 依赖边:AAHostTestKit → AAPluginSDK(SubscriptionStore / SubscriptionSourcePort)。
//
// 10 票测试金字塔次 seam:把「订阅清单/配置持久化」「订阅源拉取」两个 Port 换成可编程内存假件,
//   即可断言订阅状态机的 list/activate/update(含失败回滚)/add(含 upsert 替换源、失败不留痕)全链路,
//   不碰真 AppSupport、不碰真网络。

import Foundation
import AAPluginSDK

/// 内存假 SubscriptionStore。catalog 存内存字节 + 按 id 的 config 字节;记录 saveConfig 调用序列(供回滚断言)。
/// `configPath` 返回合成路径 `mem://<id>`(重载失败测试只关心「被调了几次」,不关心路径真实性)。
/// `@unchecked Sendable`:内部状态由 lock 串行化保护。
public final class FakeSubscriptionStore: SubscriptionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var catalogBlob: Data?
    private var configs: [String: Data]

    /// saveConfig 调用序列(id + 写入字节),供回滚断言:更新回滚后应见 [新, 旧] 两次写、且末次是旧字节。
    public private(set) var saveConfigCalls: [(id: String, data: Data)] = []
    /// saveConfig 尝试次数(含失败的;供「第 N 次 saveConfig 抛错」编程)。
    public private(set) var saveConfigAttempts = 0
    /// saveCatalog 调用次数。
    public private(set) var saveCatalogCount = 0
    /// removeConfig 调用序列。
    public private(set) var removeConfigCalls: [String] = []
    /// 编程:第 N 次(1-based)saveConfig 抛错(测 F6「回滚写旧配置也失败」)。nil = 从不失败。
    public var saveConfigFailAtCall: Int?

    public enum FakeStoreError: Error, Equatable { case programmedSaveConfigFailure }

    public init(catalog: Data? = nil, configs: [String: Data] = [:]) {
        self.catalogBlob = catalog
        self.configs = configs
    }

    public func loadCatalog() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return catalogBlob
    }

    public func saveCatalog(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        catalogBlob = data
        saveCatalogCount += 1
    }

    public func saveConfig(id: String, _ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        saveConfigAttempts += 1
        if let n = saveConfigFailAtCall, saveConfigAttempts == n {
            throw FakeStoreError.programmedSaveConfigFailure   // 不记入 saveConfigCalls(失败)
        }
        configs[id] = data
        saveConfigCalls.append((id, data))
    }

    public func loadConfig(id: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return configs[id]
    }

    public func removeConfig(id: String) {
        lock.lock(); defer { lock.unlock() }
        configs[id] = nil
        removeConfigCalls.append(id)
    }

    public func configPath(id: String) -> String { "mem://\(id)" }

    /// 测试助手:当前某 id 已物化的配置字节(断言回滚后 == 旧字节)。
    public func currentConfig(id: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return configs[id]
    }
}

/// 可编程内存假 SubscriptionSourcePort。按 source 预置一队 `Result<Data, Error>`,可编排「先好后坏 / 抛错 / 空内容」。
/// 每次 fetch 弹出队首(队列仅剩一个时重复返回它,便于稳定单响应);未编程的 source → 抛 notProgrammed。
/// `@unchecked Sendable`:内部状态由 lock 串行化保护。
public final class FakeSubscriptionSourcePort: SubscriptionSourcePort, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String: [Result<Data, Error>]]
    /// fetch 调用的 source 序列(断言「失败/拒绝时未多余拉取」等)。
    public private(set) var fetchCalls: [String] = []

    public enum FakeError: Error, Equatable { case notProgrammed(String) }

    public init(_ results: [String: [Result<Data, Error>]] = [:]) {
        self.results = results
    }

    /// 编程某 source 的响应队列(覆盖既有)。
    public func program(source: String, _ queue: [Result<Data, Error>]) {
        lock.lock(); defer { lock.unlock() }
        results[source] = queue
    }

    public func fetch(source: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        fetchCalls.append(source)
        guard var queue = results[source], !queue.isEmpty else {
            throw FakeError.notProgrammed(source)
        }
        let r = queue.count > 1 ? queue.removeFirst() : queue[0]
        results[source] = queue
        switch r {
        case .success(let d): return d
        case .failure(let e): throw e
        }
    }
}
