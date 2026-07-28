// AAHostRuntime —— 宿主运行时(注册表 / 分级确认策略 / 路由)的平台无关内核。V1 骨架占位。
// 依赖边:AAHostRuntime → AAContracts。

import AAContracts

/// V1 骨架占位。`import AAContracts` 并触达 `RiskLevel`,在编译期证明依赖边连通。
public enum HostRuntime {
    /// 供下游 Host* 层触达的稳定标识(String,便于 AAHostMacOS/AAHostTestKit 不必透传 AAContracts 类型)。
    public static let name = "AAHostRuntime"

    /// 占位:注册表可路由的最高风险档。证明可引用 AAContracts.RiskLevel。
    public static let highestRisk: RiskLevel = .dangerous
}
