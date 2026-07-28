// AAHostTestKit —— 宿主 Port 协议的假件(Fake host),让域逻辑在零 macOS 依赖下可单测(spec 测试金字塔次 seam)。V1 骨架占位。
// 依赖边:AAHostTestKit → AAHostRuntime。

import AAHostRuntime

/// V1 骨架占位。触达 `HostRuntime` 以在编译期证明依赖边连通。
public enum HostTestKit {
    /// 占位:回声其所依赖的运行时名。证明依赖边 AAHostTestKit → AAHostRuntime 连通。
    public static func runtimeName() -> String { HostRuntime.name }
}
