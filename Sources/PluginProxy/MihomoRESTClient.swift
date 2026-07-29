// PluginProxy —— mihomo REST 子集客户端(业务面归插件)。
// 依赖边:PluginProxy → AAPluginSDK(HTTPPort)、AAContracts(JSONValue)。绝不 import 任何 Host*。
//
// 06 票:mihomo 内核暴露 external-controller REST。本客户端读其子集并解析成域模型:
//   * GET /version  —— 版本(兼作「API 可达」佐证)。
//   * GET /configs  —— 当前 mode(rule|global|direct)与监听端口(mixed-port,回退 port)。
//   * GET /proxies  —— 当前选中节点(best-effort:取首个有非空 `now` 的分组)。
// URL 构建与 JSON 解析是插件域逻辑——真 I/O 压在注入的 HTTPPort 之后,注入假件即可纯逻辑单测(无需真内核)。
//
// 09 票:控制面写/读三扩展(仍压 HTTPPort,注入假件可测),动词对齐真 mihomo external-controller REST:
//   * PATCH /configs         body {"mode":"rule|global|direct"} —— 切模式(2xx=成功)。
//       (真核约定:PATCH /configs 才是「改运行参数」;PUT /configs 是「从路径重载配置」,动词错会误触发重载,故用 PATCH。)
//   * PUT /proxies/<group>   body {"name":"<node>"}             —— 按组选节点(2xx=成功;真核选节点即 PUT)。
//   * GET /group/<group>/delay?url=&timeout= —— 按组测速,逐节点延迟;mihomo 对超时/失败节点**不返回其延迟**
//       (从 delay map 缺席),故「在候选内但结果缺席」= 超时,如实标注为 timeout(delayMs=nil),不臆造 0。
//   URL 构建 / body 编码 / 响应解析都是插件域逻辑,注入 FakeHTTPPort 预置响应即可纯逻辑单测。

import Foundation
import AAContracts
import AAPluginSDK

/// 一个「可切换分组」的域模型(09 票):名字 + 类型 + 当前选中(now)+ 候选节点(all)。
/// 仅由「带 `all` 候选列表」的 /proxies 条目构成(Selector / URLTest / Fallback / LoadBalance …);裸节点无 all,不入列。
public struct ProxyGroup: Sendable, Equatable {
    /// 分组名(如 PROXY / GLOBAL)。
    public let name: String
    /// 分组类型(原样透传:Selector / URLTest / …)。
    public let type: String
    /// 当前选中节点;空字符串归一为 nil(仅 Selector 有稳定 now)。
    public let now: String?
    /// 候选节点名列表。
    public let all: [String]
    public init(name: String, type: String, now: String?, all: [String]) {
        self.name = name
        self.type = type
        self.now = now
        self.all = all
    }
}

/// 单个节点的按组测速结果(09 票)。
public struct NodeLatency: Sendable, Equatable {
    /// 节点名。
    public let node: String
    /// 延迟毫秒;**nil = 超时/测速失败**(如实标注,绝不臆造 0)。
    public let delayMs: Int?
    /// 便捷:是否超时(delayMs 缺失即超时)。
    public var timedOut: Bool { delayMs == nil }
    public init(node: String, delayMs: Int?) {
        self.node = node
        self.delayMs = delayMs
    }
}

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

    // ============ 09 票:控制面写/读扩展 ============

    /// GET /proxies → 列出全部「可切换分组」(带 `all` 候选列表者)。按分组名排序,确保输出确定性。
    /// 缺 `proxies` 字段抛 missingField;裸节点(无 `all`)不入列。
    public func groups() throws -> [ProxyGroup] {
        let v = try getJSON("/proxies")
        guard let proxies = v.objectValue?["proxies"]?.objectValue else {
            throw MihomoRESTError.missingField("proxies")
        }
        var result: [ProxyGroup] = []
        for key in proxies.keys.sorted() {
            guard let entry = proxies[key]?.objectValue else { continue }
            // 仅「可切换分组」:必须带 all 候选列表(Selector/URLTest/Fallback/…);裸节点无 all,跳过。
            guard let allValue = entry["all"], case let .array(items) = allValue else { continue }
            let all = items.compactMap { $0.stringValue }
            let type = entry["type"]?.stringValue ?? "Unknown"
            var now: String? = nil
            if let n = entry["now"]?.stringValue, !n.isEmpty { now = n }
            result.append(ProxyGroup(name: key, type: type, now: now, all: all))
        }
        return result
    }

    /// PATCH /configs body `{"mode": mode}` —— 切模式(真核约定 PATCH,非 PUT)。2xx 视为成功;非 2xx 抛 httpStatus。
    /// (mode 的取值合法性由宿主 Registry 的 allowedValues 校验把关,本层只负责编码 + 发送 + 状态码判定。)
    public func setMode(_ mode: String) throws {
        let body = try JSONEncoder().encode(["mode": mode])
        try sendExpectingSuccess(method: HTTPMethod.patch, path: "/configs", body: body)
    }

    /// PUT /proxies/<group> body `{"name": node}` —— 按组选节点(真核约定 PUT)。2xx 视为成功;非 2xx 抛 httpStatus。
    /// group 作为路径段做百分号编码(容纳含空格/非 ASCII 的分组名)。
    public func selectNode(group: String, node: String) throws {
        let body = try JSONEncoder().encode(["name": node])
        try sendExpectingSuccess(method: HTTPMethod.put, path: "/proxies/" + Self.encodePathComponent(group), body: body)
    }

    /// PUT /configs body `{"path": path}` —— 从指定路径**重载**内核配置(10 票订阅激活/更新用)。2xx 视为成功;非 2xx 抛 httpStatus。
    /// 真核约定:**PUT /configs = 从路径重载配置**,区别于 `setMode` 的 **PATCH /configs = 改运行参数**(动词错会误触发重载或误改参数)。
    public func reloadConfig(path: String) throws {
        let body = try JSONEncoder().encode(["path": path])
        try sendExpectingSuccess(method: HTTPMethod.put, path: "/configs", body: body)
    }

    /// 按组测速:先读该组候选节点(GET /proxies),再 GET /group/<group>/delay 拿逐节点延迟。
    /// mihomo 对超时/失败节点**不返回其延迟**(从 delay map 缺席),故「在候选内但结果缺席」= 超时,如实标注(delayMs=nil)。
    /// - Parameters:
    ///   - group: 目标分组名(须存在;不存在抛 missingField → 上层收敛为业务失败)。
    ///   - testURL: 测试 URL(如 http://www.gstatic.com/generate_204)。
    ///   - timeoutMs: 单节点超时毫秒。
    /// - Returns: 逐候选节点的延迟(有序,与该组 `all` 一致);超时节点 delayMs=nil。
    public func testGroupLatency(group: String, testURL: String, timeoutMs: Int) throws -> [NodeLatency] {
        // ① 该组候选节点(用于「结果缺席即超时」的对齐基准)。
        let all = try groups()
        guard let g = all.first(where: { $0.name == group }) else {
            throw MihomoRESTError.missingField("group:\(group)")
        }
        // ② 逐节点延迟 map(key=节点名, value=延迟 ms)。
        let path = "/group/\(Self.encodePathComponent(group))/delay"
            + "?url=\(Self.encodeQueryValue(testURL))&timeout=\(timeoutMs)"
        let v = try getJSON(path)
        let delayMap = v.objectValue ?? [:]
        // ③ 逐候选节点对齐:结果里是数字 → 延迟;缺席/非数字 → 超时(如实标注,不臆造)。
        return g.all.map { name in
            if case let .number(n)? = delayMap[name] {
                return NodeLatency(node: name, delayMs: Int(n))
            }
            return NodeLatency(node: name, delayMs: nil)
        }
    }

    // ============ 私有助手 ============

    /// 发一个写请求(method 由调用方指定:切模式=PATCH,选节点=PUT)并要求 2xx;非 2xx 抛 httpStatus(mihomo 写成功常回 204 No Content)。
    private func sendExpectingSuccess(method: String, path: String, body: Data) throws {
        let resp = try http.send(method: method, url: baseURL + path, body: body)
        guard (200..<300).contains(resp.statusCode) else {
            throw MihomoRESTError.httpStatus(resp.statusCode)
        }
    }

    /// 单个 URL 路径段的百分号编码(编码 `/` 等分隔符,容纳含空格/非 ASCII 的分组名)。
    private static func encodePathComponent(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// query 取值的百分号编码(编码会破坏 query 结构的保留字符)。
    private static func encodeQueryValue(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?#+")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
