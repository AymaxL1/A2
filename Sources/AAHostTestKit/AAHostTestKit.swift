// AAHostTestKit —— 宿主域逻辑的测试基建 / 假件(让 Runtime 在零 macOS 依赖下可单测,spec 测试金字塔次 seam)。
// 依赖边:AAHostTestKit → AAHostRuntime(→ AAContracts)。
//
// 本票(02)提供 `Registry` 的纯逻辑一致性测试:构造注册表(含经构造注入的「假件能力集」),
// 断言 `list()` 行为,全程不起真宿主、不碰 UDS、不 import AppKit。
// 03 票会在此追加宿主 Port(dangerous 确认回调)的假件,驱动 invoke/路由的纯逻辑测试。

import Foundation
import AAContracts
import AAHostRuntime

/// 极简断言累加器(不依赖 XCTest —— 本机工具链坏,swift test 不可用;由 check.sh 的 runner 执行)。
public struct TestReport: Sendable {
    public private(set) var passed = 0
    public private(set) var failed = 0
    public private(set) var lines: [String] = []

    public init() {}

    /// 记一条断言。
    public mutating func check(_ condition: Bool, _ description: String) {
        if condition {
            passed += 1
            lines.append("PASS: \(description)")
        } else {
            failed += 1
            lines.append("FAIL: \(description)")
        }
    }
}

/// `Registry` 的纯逻辑一致性测试。经 AAHostTestKit 的构造注入(假件能力集)驱动,证明:
/// 1) 默认注册表 `list()` 含 demo 能力,且其风险档 / schemaSummary 符合契约;
/// 2) 注册表把「注入的能力集」原样透传给 `list()`(假件 seam 通路);
/// 3) `RiskLevel` 经 JSON 编解码往返稳定(契约级覆盖:清单里的 risk 字段就走这一遭)。
public enum RegistryConformanceTests {
    public static func run() -> TestReport {
        var report = TestReport()

        // ① 默认注册表(种入 demoCapabilities)
        let registry = Registry()
        let caps = registry.list()
        report.check(!caps.isEmpty, "默认注册表 list() 非空")
        report.check(caps.contains { $0.id == "demo.echo" }, "list() 含 demo.echo")
        if let echo = caps.first(where: { $0.id == "demo.echo" }) {
            report.check(echo.risk == .safe, "demo.echo 风险档为 safe")
            report.check(echo.schemaSummary != nil, "demo.echo 携带 schemaSummary")
        } else {
            report.check(false, "定位 demo.echo 描述符")
        }

        // ② 假件 seam:构造注入自定义能力集,断言 list() 原样透传(不碰 UDS / AppKit)
        let fakeCaps = [
            CapabilityDescriptor(id: "fake.alpha", risk: .normal, summary: "假件能力 A", schemaSummary: nil),
            CapabilityDescriptor(id: "fake.beta", risk: .dangerous, summary: "假件能力 B", schemaSummary: "s")
        ]
        let injected = Registry(capabilities: fakeCaps).list()
        report.check(injected.count == 2, "假件注册表 list() 数量与注入一致(2)")
        report.check(injected.map { $0.id } == ["fake.alpha", "fake.beta"], "假件能力集被 list() 原样透传(含顺序)")

        // ③ 契约级:RiskLevel 经 JSON 往返稳定(清单响应里的 risk 字段走的正是这条编解码路径)
        report.check(riskLevelRoundTrips(), "RiskLevel 三档经 JSON 编解码往返稳定")

        return report
    }

    /// 断言每一档 RiskLevel 都能编码为其 rawValue 字符串并原样解回。
    private static func riskLevelRoundTrips() -> Bool {
        for level in RiskLevel.allCases {
            guard let data = try? JSONEncoder().encode(level),
                  let back = try? JSONDecoder().decode(RiskLevel.self, from: data),
                  back == level else {
                return false
            }
        }
        return true
    }
}
