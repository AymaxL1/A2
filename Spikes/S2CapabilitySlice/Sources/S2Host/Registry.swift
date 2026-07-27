// PROTOTYPE — 极简能力注册表。纯 Swift 逻辑，不依赖 AppKit（呼应 07 票：Runtime 纯逻辑可单测，宿主注入 GUI 确认）。
import Foundation

/// 能力元数据。风险分级见 ADR 0004：safe / normal / dangerous 三档；本 spike 只用 safe 与 dangerous 两档。
struct Capability {
    let id: String
    let risk: String        // "safe" | "dangerous"
    let summary: String     // 用户可读摘要（同时兼作 agent 可读短描述）
}

/// 能力注册表。硬编码注册两个 demo 能力，并按风险档路由。
/// 响应约定（线协议为逐行 JSON）：
///   成功 -> {"ok":true,"result":{...}}
///   拒绝 -> {"ok":false,"error":"denied"}
///   其它 -> {"ok":false,"error":"<码>","detail":"<说明>"}
final class Registry {
    let capabilities: [Capability] = [
        Capability(id: "demo.echo", risk: "safe",
                   summary: "原样回显输入 JSON 并附时间戳"),
        Capability(id: "demo.wipe", risk: "dangerous",
                   summary: "危险操作演示：需宿主确认后返回 approved")
    ]

    /// dangerous 确认回调：由宿主（AppDelegate）注入，实现为主线程 NSAlert。
    /// 返回 true=用户确认执行，false=拒绝。注册表本身不含任何 GUI 代码。
    var confirmDangerous: ((Capability) -> Bool)?

    func capability(id: String) -> Capability? {
        capabilities.first { $0.id == id }
    }

    /// 路由并执行一次调用，返回响应字典。
    func invoke(capabilityID: String, input: Any?) -> [String: Any] {
        // 内置查询：能力清单（不是领域能力，故用下划线前缀区分）
        if capabilityID == "_list" {
            let list = capabilities.map {
                ["id": $0.id, "risk": $0.risk, "summary": $0.summary]
            }
            return ["ok": true, "result": ["capabilities": list]]
        }

        guard let cap = capability(id: capabilityID) else {
            return ["ok": false, "error": "unknown_capability",
                    "detail": "未注册能力: \(capabilityID)"]
        }

        // dangerous 档：先经宿主确认，拒绝即短路
        if cap.risk == "dangerous" {
            let approved = confirmDangerous?(cap) ?? false
            guard approved else {
                return ["ok": false, "error": "denied"]
            }
            return ["ok": true, "result": ["approved": true]]
        }

        // safe 档：直接执行
        switch cap.id {
        case "demo.echo":
            return ["ok": true,
                    "result": ["capability": "demo.echo",
                               "echo": input ?? NSNull(),
                               "timestamp": isoNow()]]
        default:
            return ["ok": false, "error": "not_implemented", "detail": cap.id]
        }
    }
}
