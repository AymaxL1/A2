// PluginProxy —— 代理插件的域逻辑(接管快照 / 崩溃自愈判定 / 订阅状态机 / 分级路由)。V1 骨架占位。
// 依赖边:PluginProxy → AAPluginSDK, AAContracts, AAUISystem。
//
// 铁律(01 票验收项):PluginProxy 绝不依赖任何 Host* target(AAHostRuntime / AAHostMacOS / AAHostTestKit)。
// 这条边界由编译期强制——本文件不得 `import` 任何 Host* 模块,check.sh 亦会以「仅给 SDK/Contracts/UISystem
// 的 -I 编译成功」+「源码级 grep 守卫」双重把关。所有副作用都要压到 Host Port 协议之后,由宿主侧实现,插件永不直连 macOS。

import AAContracts
import AAPluginSDK
import AAUISystem

/// V1 骨架占位。同时触达三条依赖边(Contracts / PluginSDK / UISystem),证明它们连通且插件无需任何 Host* 依赖。
public enum ProxyPlugin {
    /// 占位:给定一个风险档字符串,解析后返回其 UI 角标 —— 走通 AAContracts.parse + AAUISystem.badge。
    public static func riskBadge(for raw: String) -> String {
        let level = RiskLevel.parse(raw) ?? PluginSDK.defaultRisk
        return UISystem.badge(for: level)
    }
}
