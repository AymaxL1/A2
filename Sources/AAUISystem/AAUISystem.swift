// AAUISystem —— 跨宿主复用的 UI 系统(设计系统 / 可复用视图构件)。V1 骨架占位。
// 依赖边:AAUISystem → AAContracts。

import AAContracts

/// V1 骨架占位。`import AAContracts` 并触达 `RiskLevel`,在编译期证明依赖边连通。
public enum UISystem {
    /// 占位:按风险档给出一个角标文案示例。证明可引用 AAContracts.RiskLevel。
    public static func badge(for level: RiskLevel) -> String {
        switch level {
        case .safe: return "只读"
        case .normal: return "可逆"
        case .dangerous: return "需确认"
        }
    }
}
