// AAContracts —— 零依赖契约底座。
// 宿主(Host*)、插件(PluginProxy)、CLI(aa)三方共用的词汇都定在这里,以免循环依赖(spec 用户故事 12)。
//
// 本文件放的是 V1 的第一颗真实种子:风险三档 RiskLevel。这不是废占位——
// 它是 spec 锁定的真实契约(spec:风险三档 safe/normal/dangerous),后续能力注册表与分级确认都挂在它上面。

import Foundation

/// 能力风险三档(spec §风险三档):
/// - `safe`:只读,无副作用(如 proxy.status / groups.list / latency.test)。
/// - `normal`:可逆状态变更(如开关系统代理 / 切模式 / 选节点 / 更新已有订阅)。
/// - `dangerous`:信任面变更(如新增或替换订阅源 / 覆写内核配置),须经宿主 GUI 最终确认,CLI 永不交互阻塞。
/// - `Codable`:线协议(逐行 JSON)里 `CapabilityDescriptor.risk` 就是它。
///   String 原始值枚举自动获得 Codable,编码即其 rawValue("safe"/"normal"/"dangerous"),
///   反解由 `init(from:)` 走 rawValue 匹配(与 `parse(_:)` 的宽松解析分工:线协议要严格,入口要宽松)。
public enum RiskLevel: String, Sendable, CaseIterable, Codable {
    case safe
    case normal
    case dangerous

    /// 从字符串解析风险档位。
    /// - 规则:去首尾空白 + 大小写不敏感;无法识别时返回 `nil`(由调用方决定如何降级/报错)。
    /// - 用途:manifest 载入、CLI 参数解析、IPC 协议反序列化等入口处的统一解析口。
    public static func parse(_ raw: String) -> RiskLevel? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return RiskLevel(rawValue: key)
    }
}
