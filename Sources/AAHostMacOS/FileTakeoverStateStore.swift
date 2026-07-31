// AAHostMacOS —— TakeoverStateStore 真实现(文件后端,原子写)。08 崩溃自愈的持久化落点。
// 依赖边:AAHostMacOS → AAPluginSDK(TakeoverStateStore 协议)、Foundation。
//
// 08 票:把「接管态清单」的不透明字节持久化到一个 JSON 文件(路径来自 AAPaths.takeoverStatePath,
//   或 test-only env seam AA_TAKEOVER_STATE_PATH 覆盖到临时区)。写入走**临时文件 + rename 原子替换**——
//   杜绝崩溃/断电留下半截文件(半截会让下次启动的自愈误判)。schema 决策在域层(PluginProxy.TakeoverState),
//   本层只认字节。
//
// ⚠️ 生产路径落在真实 Application Support;E2E 一律经 AA_TAKEOVER_STATE_PATH 指向 $BUILD 临时区,绝不污染真实 AppSupport。

import Foundation
import AAPluginSDK

/// 文件后端接管态持久化(原子写:临时文件 + rename)。
public final class FileTakeoverStateStore: TakeoverStateStore, @unchecked Sendable {
    private let url: URL
    private let recoveryURL: URL
    private let tombstoneURL: URL
    private let lock = NSLock()

    public init(path: String) {
        self.url = URL(fileURLWithPath: path)
        self.recoveryURL = URL(fileURLWithPath: path + ".recovery")
        self.tombstoneURL = URL(fileURLWithPath: path + ".cleared")
    }

    /// 文件不存在返回 nil；存在但不可读时抛错，绝不能与“无残留”混为一谈。
    public func load() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: tombstoneURL.path) { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// 独立恢复副本；与主文件分开原子写，主文件损坏/不可读时仍可取回完整快照。
    public func loadRecovery() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: tombstoneURL.path) { return nil }
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return nil }
        return try Data(contentsOf: recoveryURL)
    }

    /// 原子写入:先写同目录下的临时文件,再 `replaceItemAt` rename 覆盖目标(POSIX rename 原子,杜绝半截文件)。
    /// rename/replace 失败务必清理残留临时文件(否则临时文件泄漏堆积)。
    public func save(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 先落恢复副本、再落主文件；任一步失败都会抛错，调用方因而不会开始系统代理写入。
        try atomicWrite(data, to: recoveryURL)
        try atomicWrite(data, to: url)
        if FileManager.default.fileExists(atPath: tombstoneURL.path) {
            try FileManager.default.removeItem(at: tombstoneURL)
        }
    }

    private func atomicWrite(_ data: Data, to target: URL) throws {
        let dir = target.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(target.lastPathComponent).tmp-\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: tmp, options: .atomic)
        do {
            // 目标已存在 → replaceItemAt 原子替换;不存在 → 直接 move。二者都以 rename 收尾,读者永远看到完整文件。
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)   // 清理残留临时文件,防泄漏堆积
            throw error
        }
    }

    /// 先原子落 tombstone，再尽力删除恢复副本与主文件。单边删除失败时残留会被 tombstone 屏蔽；
    /// 两份均删除成功后再移除 tombstone。tombstone 写失败会抛错，且不会开始删除任何证据。
    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: tombstoneURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try atomicWrite(Data("cleared".utf8), to: tombstoneURL)
        var allRemoved = true
        for target in [recoveryURL, url] where FileManager.default.fileExists(atPath: target.path) {
            do { try FileManager.default.removeItem(at: target) }
            catch { allRemoved = false }
        }
        if allRemoved { try? FileManager.default.removeItem(at: tombstoneURL) }
    }
}
