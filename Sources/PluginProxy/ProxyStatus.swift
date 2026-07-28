// PluginProxy —— `proxy.status` 的状态组装(插件域逻辑,纯逻辑可单测)。
// 依赖边:PluginProxy → AAPluginSDK(ProcessPort/ProcessHandle)、AAContracts(JSONValue)。绝不 import Host*。
//
// 06 票核心语义:
//   * 健康检查以 ProcessPort 探活为准(内核死亡可检测,状态反映真实存活)。
//   * 内核未运行(无句柄 / 探活为假)→ 如实返回 `{ running: false }`,**而不是报错/退出码非零**。
//   * 内核存活 → running:true,并 best-effort 经 REST 补 version/mode/mixedPort/node;REST 不可达时
//     running 仍为 true(进程活着),仅 apiReachable:false(如内核刚起、控制面尚未就绪)。
// 把「探活 + REST 读」的组装抽成纯函数,注入假 ProcessPort/假 HTTPPort 即可断言「存活→反映真实 / 死亡→如实未运行」。

import AAContracts
import AAPluginSDK

/// `proxy.status` 的状态组装(纯逻辑)。
public enum ProxyStatus {
    /// 组装内核状态 JSON。
    /// - Parameters:
    ///   - processPort: 探活用的进程 Port(真实现或假件)。
    ///   - handle: 当前内核句柄;nil 表示宿主未拉起内核(未配置/未运行)。
    ///   - rest: mihomo REST 客户端(存活时才查;不可达以 try? 收敛,绝不外抛)。
    /// - Returns: `{ running: Bool, [apiReachable, version, mode, mixedPort, node] }`;绝不抛错。
    public static func statusJSON(processPort: any ProcessPort,
                                  handle: ProcessHandle?,
                                  rest: MihomoRESTClient) -> JSONValue {
        let alive = handle.map { processPort.isAlive($0) } ?? false
        guard alive else {
            // 内核未运行:如实返回未运行状态(供上层包成 .success → 退出码 0),不报错。
            return .object(["running": .bool(false)])
        }

        var obj: [String: JSONValue] = ["running": .bool(true)]

        // 版本 + API 可达性(存活但控制面可能尚未就绪 → apiReachable:false,running 仍为 true)。
        if let v = try? rest.version() {
            obj["version"] = .string(v)
            obj["apiReachable"] = .bool(true)
        } else {
            obj["apiReachable"] = .bool(false)
        }
        // 模式 + 监听端口(best-effort)。
        if let cfg = try? rest.configs() {
            obj["mode"] = .string(cfg.mode)
            if let p = cfg.mixedPort { obj["mixedPort"] = .number(Double(p)) }
        }
        // 当前节点(best-effort)。try? 会摊平 currentNode() 的 String? 返回(Swift 5 语义),故直接得 String?。
        if let n = try? rest.currentNode() {
            obj["node"] = .string(n)
        }
        return .object(obj)
    }
}
