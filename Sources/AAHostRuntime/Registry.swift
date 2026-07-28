// AAHostRuntime —— 能力注册表(纯逻辑,零 AppKit / 零 UDS)。
// 呼应 07 票测试金字塔:Runtime 保持平台无关纯逻辑,可被 AAHostTestKit 假件驱动单测;
// 副作用(GUI 确认 / networksetup / 子进程)一律压到宿主具体层(AAHostMacOS)。
//
// 本票(02)注册表只做「注册 + list」最小切面;invoke / 分级确认路由归 03 票,这里不实现。

import AAContracts

/// 能力注册表。构造时收下一组 `CapabilityDescriptor`(默认种入 demo 能力),对外只暴露 `list()`。
///
/// 设计取舍:
/// - 用构造注入(`init(capabilities:)`)而非运行时可变注册 —— 存储不可变,`final` + 全 Sendable 存储 → 天然 `Sendable`,
///   宿主可在多个连接处理线程并发 `list()` 而无数据竞争(02 票注册表在 init 后不再变更)。
/// - 构造注入同时就是「测试基建的 seam」:AAHostTestKit 可注入自定义能力集直接驱动 `list()`,不起真宿主、不碰 UDS。
public final class Registry: Sendable {
    /// 02 票的 demo 能力集:一条 `demo.echo`(safe 档,带 schemaSummary 速览)。
    /// 03 票起会替换/追加真实域能力(proxy.status 等);清单层只携带 schemaSummary,完整 schema 归 describe。
    public static let demoCapabilities: [CapabilityDescriptor] = [
        CapabilityDescriptor(
            id: "demo.echo",
            risk: .safe,
            summary: "原样回显输入并附时间戳(纵切演示能力)",
            schemaSummary: "input: { message: String } → output: { echo: String, timestamp: String }"
        )
    ]

    private let descriptors: [CapabilityDescriptor]

    /// - Parameter capabilities: 待注册的能力集,缺省为 `demoCapabilities`。
    public init(capabilities: [CapabilityDescriptor] = Registry.demoCapabilities) {
        self.descriptors = capabilities
    }

    /// 列出已注册能力(顺序即注册顺序)。02 票唯一对外行为。
    public func list() -> [CapabilityDescriptor] {
        descriptors
    }
}
