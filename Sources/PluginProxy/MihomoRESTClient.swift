// PluginProxy —— mihomo REST 子集客户端(业务面归插件)。
// 依赖边:PluginProxy → AAPluginSDK(HTTPPort)、AAContracts(JSONValue)。绝不 import 任何 Host*。
//
// 06 票:mihomo 内核暴露 external-controller REST。本客户端读其子集并解析成域模型:
//   * GET /version  —— 版本(兼作「API 可达」佐证)。
//   * GET /configs  —— 当前 mode(rule|global|direct)与监听端口(mixed-port,回退 port)。
//   * GET /proxies  —— 当前选中节点(best-effort:取首个有非空 `now` 的分组)。
// URL 构建与 JSON 解析是插件域逻辑——真 I/O 压在注入的 HTTPPort 之后,注入假件即可纯逻辑单测(无需真内核)。

import Foundation
import AAContracts
import AAPluginSDK

/// mihomo `/configs` 的域模型子集。
public struct MihomoConfig: Sendable, Equatable {
    /// 运行模式:rule | global | direct(原样透传字符串,不强枚举——向前兼容内核新增模式)。
    public let mode: String
    /// 混合代理监听端口(mixed-port;为 0/缺失时回退到 port;仍无则 nil)。
    public let mixedPort: Int?
    public init(mode: String, mixedPort: Int?) {
        self.mode = mode
        self.mixedPort = mixedPort
    }
}

/// REST 客户端错误(域逻辑层;上层 status 用 `try?` 收敛为「该字段不可得」,不外泄退出码)。
public enum MihomoRESTError: Error, Equatable {
    case httpStatus(Int)
    case badBody
    case missingField(String)
}

/// mihomo REST 子集客户端。构造注入 `HTTPPort` + 控制端口;方法只做 URL 构建 + JSON 解析(纯逻辑,可单测)。
public struct MihomoRESTClient: Sendable {
    private let http: any HTTPPort
    private let baseURL: String

    /// - Parameters:
    ///   - http: 注入的 HTTP Port(真实现发 localhost HTTP;假件返回预置 JSON)。
    ///   - host: 控制面主机(默认 127.0.0.1;仅 localhost)。
    ///   - port: 控制面端口(mihomo external-controller 端口)。
    public init(http: any HTTPPort, host: String = "127.0.0.1", port: Int) {
        self.http = http
        self.baseURL = "http://\(host):\(port)"
    }

    /// GET 一个路径并解成 JSONValue;非 200 或不可解析即抛错。
    private func getJSON(_ path: String) throws -> JSONValue {
        let resp = try http.send(method: HTTPMethod.get, url: baseURL + path, body: nil)
        guard resp.statusCode == 200 else { throw MihomoRESTError.httpStatus(resp.statusCode) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: resp.body) else {
            throw MihomoRESTError.badBody
        }
        return value
    }

    /// GET /version → 版本串。缺 `version` 字段抛 missingField。
    public func version() throws -> String {
        let v = try getJSON("/version")
        guard let s = v.objectValue?["version"]?.stringValue else {
            throw MihomoRESTError.missingField("version")
        }
        return s
    }

    /// GET /configs → mode + 监听端口。缺 `mode` 抛 missingField;端口取 mixed-port,回退 port,均无则 nil。
    public func configs() throws -> MihomoConfig {
        let v = try getJSON("/configs")
        guard let obj = v.objectValue, let mode = obj["mode"]?.stringValue else {
            throw MihomoRESTError.missingField("mode")
        }
        var mixed: Int? = nil
        if case let .number(n)? = obj["mixed-port"], n > 0 {
            mixed = Int(n)
        } else if case let .number(n)? = obj["port"], n > 0 {
            mixed = Int(n)
        }
        return MihomoConfig(mode: mode, mixedPort: mixed)
    }

    /// GET /proxies → 当前选中节点(best-effort)。
    /// 取首个(按分组名排序,确保确定性)带非空 `now` 的分组的 `now` 值;无则 nil。
    public func currentNode() throws -> String? {
        let v = try getJSON("/proxies")
        guard let proxies = v.objectValue?["proxies"]?.objectValue else { return nil }
        for key in proxies.keys.sorted() {
            if let now = proxies[key]?.objectValue?["now"]?.stringValue, !now.isEmpty {
                return now
            }
        }
        return nil
    }
}
