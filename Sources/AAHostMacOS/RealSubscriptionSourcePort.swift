// AAHostMacOS —— SubscriptionSourcePort 真实现(file:// / 裸绝对路径 / http(s):// 拉取)。10 票订阅源拉取的真 I/O 落点。
// 依赖边:AAHostMacOS → AAPluginSDK(SubscriptionSourcePort 协议)、Foundation。
//
// 10 票:订阅源拉取的「真副作用」压在宿主。
//   * `file://<path>` 或裸绝对路径 → 直接读文件字节(F10:含空格/中文的 file:// 用手工剥前缀兜底,URL(string:) 会失败)。
//   * `http(s)://…`               → 同步 URLSession(信号量)取字节;F7:禁本地缓存(update 的意义就是取新内容);
//                                   F11:响应体大小上限(防 OOM/DoS);非 2xx / 传输失败抛错(域层收敛为业务失败)。
//   Host 层允许真网络(与 06 的 SocketHTTPPort 同口径:真副作用归宿主);E2E 用本地 file:// 与本地 http.server 假源驱动,
//   绝不依赖公网。取失败一律抛 SubscriptionSourceError.fetchFailed,域层收敛为业务失败(退出码 5),绝不崩。

import Foundation
import AAPluginSDK

/// 订阅源拉取真实现(file / http(s))。
public final class RealSubscriptionSourcePort: SubscriptionSourcePort, @unchecked Sendable {
    /// http(s) 拉取超时秒数(防慢源拖死调用线程)。
    private let timeoutSeconds: TimeInterval
    /// 响应体大小上限(F11:防 OOM/DoS)。默认 10MiB。
    private let maxBytes: Int

    public init(timeoutSeconds: TimeInterval = 15, maxBytes: Int = 10 * 1024 * 1024) {
        self.timeoutSeconds = timeoutSeconds
        self.maxBytes = maxBytes
    }

    public func fetch(source: String) throws -> Data {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SubscriptionSourceError.fetchFailed("订阅源为空")
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return try fetchHTTP(trimmed)
        }
        // file:// 或裸绝对路径 → 读文件。
        return try fetchFile(trimmed)
    }

    // ============ file:// / 裸绝对路径(F10) ============

    private func fetchFile(_ source: String) throws -> Data {
        let path: String
        if source.lowercased().hasPrefix("file://") {
            if let url = URL(string: source), url.isFileURL {
                path = url.path
            } else {
                // 含空格/中文等 → URL(string:) 解析失败,会把整串(含 scheme)当裸路径。手工剥 `file://` 前缀兜底。
                //   标准形态 file:///abs → 剥后得 /abs;若源里是百分号转义(file:///a%20b)则解码回真实路径。
                let stripped = String(source.dropFirst("file://".count))
                path = stripped.removingPercentEncoding ?? stripped
            }
        } else {
            path = source
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw SubscriptionSourceError.fetchFailed("无法读取文件订阅源: \(path)")
        }
        // F11:文件也设上限(本地文件虽用户可控,但避免误配巨文件把配置塞爆内存/下游)。
        guard data.count <= maxBytes else {
            throw SubscriptionSourceError.fetchFailed("订阅源过大(\(data.count) 字节 > 上限 \(maxBytes)): \(path)")
        }
        return data
    }

    // ============ http(s)://(F7 禁缓存 + F11 大小上限) ============

    /// 同步取 http(s) 字节(信号量把异步 dataTask 拉直)。非 2xx / 传输失败 / 超时 / 超限抛 fetchFailed。
    private func fetchHTTP(_ source: String) throws -> Data {
        guard let url = URL(string: source) else {
            throw SubscriptionSourceError.fetchFailed("非法订阅源 URL: \(source)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds
        // F7:禁用本地缓存——update 的全部意义就是取新内容,绝不能拿 URLSession 磁盘缓存的陈旧副本却报成功。
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let sem = DispatchSemaphore(value: 0)
        var outData: Data?
        var outError: String?
        let cap = maxBytes

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if let error = error {
                outError = "传输失败: \(error.localizedDescription)"
                return
            }
            if let http = response as? HTTPURLResponse {
                if !(200..<300).contains(http.statusCode) {
                    outError = "HTTP 状态码 \(http.statusCode)"
                    return
                }
                // F11:若服务端声明了超限的 Content-Length,直接拒(不必等收完)。
                if http.expectedContentLength > Int64(cap) {
                    outError = "响应体过大(声明 \(http.expectedContentLength) 字节 > 上限 \(cap))"
                    return
                }
            }
            if let data = data, data.count > cap {
                outError = "响应体过大(\(data.count) 字节 > 上限 \(cap))"
                return
            }
            outData = data
        }
        task.resume()

        // 信号量兜底等待(比 URLSession 超时略宽,避免二者竞态时永久阻塞)。
        if sem.wait(timeout: .now() + timeoutSeconds + 5) == .timedOut {
            task.cancel()
            throw SubscriptionSourceError.fetchFailed("拉取超时: \(source)")
        }
        if let outError = outError {
            throw SubscriptionSourceError.fetchFailed("\(outError)(\(source))")
        }
        guard let data = outData else {
            throw SubscriptionSourceError.fetchFailed("无响应体: \(source)")
        }
        return data
    }
}
