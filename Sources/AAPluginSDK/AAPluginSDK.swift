// AAPluginSDK —— 插件开发方(如 PluginProxy)面向平台契约的 SDK 层。V1 骨架占位。
// 依赖边:AAPluginSDK → AAContracts。

import AAContracts

/// V1 骨架占位。此处 `import AAContracts` 并触达 `RiskLevel`,用于在编译期证明依赖边真的连通。
public enum PluginSDK {
    /// 插件能力默认档位示例(占位):证明可以引用 AAContracts.RiskLevel。
    public static let defaultRisk: RiskLevel = .safe
}
