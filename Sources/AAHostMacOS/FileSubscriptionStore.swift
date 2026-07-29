// AAHostMacOS —— SubscriptionStore 真实现(文件后端,原子写)。10 票订阅清单/配置的持久化落点。
// 依赖边:AAHostMacOS → AAPluginSDK(SubscriptionStore 协议)、Foundation。
//
// 10 票:把「订阅清单」与「按 id 物化的配置字节」持久化到 baseDir 下:
//   * 清单 catalog = `<baseDir>/catalog.json`;
//   * 物化配置    = `<baseDir>/configs/<id>.conf`(configPath 返回其绝对路径,传给内核 reloadConfig)。
//   全部走**临时文件 + rename 原子替换**(照抄 FileTakeoverStateStore),杜绝崩溃/断电留半截文件。
//   schema 决策在域层(PluginProxy.Subscription/SubscriptionCatalog);本层只认字节。
//
// ⚠️ 生产 baseDir 落真实 Application Support(AAPaths.subscriptionsDirectory);E2E 一律经 env seam
//    AA_SUBSCRIPTION_DIR 指向 $BUILD 临时区,绝不污染真实 AppSupport。

import Foundation
import AAPluginSDK

/// 文件后端订阅持久化(原子写:临时文件 + rename)。
public final class FileSubscriptionStore: SubscriptionStore, @unchecked Sendable {
    private let baseURL: URL
    private let configsURL: URL
    private let lock = NSLock()

    /// - Parameter baseDir: 订阅数据目录(catalog.json 与 configs/ 都落其下)。
    public init(baseDir: String) {
        self.baseURL = URL(fileURLWithPath: baseDir, isDirectory: true)
        self.configsURL = baseURL.appendingPathComponent("configs", isDirectory: true)
    }

    private var catalogURL: URL { baseURL.appendingPathComponent("catalog.json") }

    private func configURL(id: String) -> URL {
        configsURL.appendingPathComponent("\(id).conf")
    }

    // ============ 清单 ============

    public func loadCatalog() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: catalogURL)
    }

    public func saveCatalog(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        try Self.atomicWrite(data, to: catalogURL)
    }

    // ============ 物化配置 ============

    public func saveConfig(id: String, _ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        try Self.atomicWrite(data, to: configURL(id: id))
    }

    public func loadConfig(id: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: configURL(id: id))
    }

    public func removeConfig(id: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: configURL(id: id))
    }

    public func configPath(id: String) -> String {
        configURL(id: id).path
    }

    // ============ 原子写(临时文件 + rename;照抄 FileTakeoverStateStore) ============

    /// 原子写入:先写同目录下的临时文件,再 `replaceItemAt` rename 覆盖目标(POSIX rename 原子,杜绝半截文件)。
    /// 目标父目录不存在则创建;rename/replace 失败务必清理残留临时文件(否则泄漏堆积)。
    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: tmp, options: .atomic)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
