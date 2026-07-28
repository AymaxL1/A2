// AAHostMacOS —— macOS 宿主具体实现层(菜单栏 / NSPanel 窗口 / networksetup / 子进程等副作用落地)。V1 骨架占位。
// 依赖边:AAHostMacOS → AAHostRuntime(仅经运行时内核触达平台无关逻辑)。

import AAHostRuntime

/// V1 骨架占位。触达 `HostRuntime` 以在编译期证明依赖边连通。
public enum HostMacOS {
    /// 占位:回声其所依赖的运行时名。证明依赖边 AAHostMacOS → AAHostRuntime 连通。
    public static func runtimeName() -> String { HostRuntime.name }
}
