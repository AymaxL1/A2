// AAHostTestKit —— 宿主域逻辑的测试基建 / 假件(让 Runtime 在零 macOS 依赖下可单测,spec 测试金字塔次 seam)。
// 依赖边:AAHostTestKit → AAHostRuntime(→ AAContracts)。
//
// 本票(03)在 02 的 list 纯逻辑测试上追加:
//   * invoke 全路径:未知能力 / 缺必填 / 类型不符 / 业务失败 / safe 成功 / normal 成功(零 GUI);
//   * describe 拿到 parameters;dangerous 分支返回 not_implemented(留 seam 给 04);
//   * JSONValue 经 Codable 往返稳定;退出码映射表(AAExitCode.forErrorCode)逐码正确。
// 全程不起真宿主、不碰 UDS、不 import AppKit。

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

/// `Registry` 的纯逻辑一致性测试(list + describe + invoke 全路径 + 契约往返 + 退出码映射)。
public enum RegistryConformanceTests {
    public static func run() -> TestReport {
        var report = TestReport()
        runListTests(&report)
        runDescribeTests(&report)
        runInvokeTests(&report)
        runDangerousSeamTest(&report)
        runContractRoundTripTests(&report)
        runExitCodeMappingTests(&report)
        return report
    }

    // ① list:默认注册表 + 假件 seam 透传
    private static func runListTests(_ report: inout TestReport) {
        let caps = Registry().list()
        report.check(!caps.isEmpty, "默认注册表 list() 非空")
        report.check(caps.contains { $0.id == "demo.echo" }, "list() 含 demo.echo")
        report.check(caps.contains { $0.id == "demo.note.set" }, "list() 含 demo.note.set(normal demo)")
        if let echo = caps.first(where: { $0.id == "demo.echo" }) {
            report.check(echo.risk == .safe, "demo.echo 风险档为 safe")
            report.check(echo.schemaSummary != nil, "demo.echo 携带 schemaSummary")
            report.check(!echo.parameters.isEmpty, "demo.echo 携带结构化 parameters")
        } else {
            report.check(false, "定位 demo.echo 描述符")
        }
        if let note = caps.first(where: { $0.id == "demo.note.set" }) {
            report.check(note.risk == .normal, "demo.note.set 风险档为 normal")
        }

        // 假件 seam:构造注入自定义能力集,断言 list() 原样透传(含顺序,不碰 UDS / AppKit)
        let fake = Registry(capabilities: [
            fakeCapability(id: "fake.alpha", risk: .normal),
            fakeCapability(id: "fake.beta", risk: .safe)
        ]).list()
        report.check(fake.count == 2, "假件注册表 list() 数量与注入一致(2)")
        report.check(fake.map { $0.id } == ["fake.alpha", "fake.beta"], "假件能力集被 list() 原样透传(含顺序)")
    }

    // ② describe:拿得到 parameters(name/type/required),足以构造调用
    private static func runDescribeTests(_ report: inout TestReport) {
        let registry = Registry()
        report.check(registry.describe("demo.nope") == nil, "describe 未知能力返回 nil")
        if let d = registry.describe("demo.echo") {
            let msg = d.parameters.first { $0.name == "message" }
            report.check(msg != nil, "describe demo.echo 含参数 message")
            report.check(msg?.type == "string", "describe demo.echo 参数 message 类型为 string")
            report.check(msg?.required == true, "describe demo.echo 参数 message 为必填")
        } else {
            report.check(false, "describe demo.echo 非空")
        }
    }

    // ③ invoke:未知/缺必填/类型不符/业务失败/safe 成功/normal 成功
    private static func runInvokeTests(_ report: inout TestReport) {
        let registry = Registry()

        // 未知能力 → unknown_capability(→ 退出码 6)
        report.check(errorCode(registry.invoke(capabilityID: "demo.nope", input: .object([:])))
                        == WireErrorCode.unknownCapability, "invoke 未知能力 → unknown_capability")

        // 缺必填 → missing_parameter
        report.check(errorCode(registry.invoke(capabilityID: "demo.echo", input: .object([:])))
                        == WireErrorCode.missingParameter, "invoke 缺必填 message → missing_parameter")

        // 类型不符(message 给数字)→ type_mismatch
        report.check(errorCode(registry.invoke(capabilityID: "demo.echo", input: .object(["message": .number(1)])))
                        == WireErrorCode.typeMismatch, "invoke message 类型不符 → type_mismatch")

        // safe 成功:回显
        switch registry.invoke(capabilityID: "demo.echo", input: .object(["message": .string("hi")])) {
        case .success(let out):
            report.check(out.objectValue?["echo"]?.stringValue == "hi", "invoke demo.echo 成功且回显 message")
        case .failure:
            report.check(false, "invoke demo.echo(合法 input)应成功")
        }

        // 业务失败:message=="boom" → capability_failed(→ 退出码 5)
        report.check(errorCode(registry.invoke(capabilityID: "demo.echo", input: .object(["message": .string("boom")])))
                        == WireErrorCode.capabilityFailed, "invoke demo.echo boom → capability_failed(业务失败)")

        // normal 成功(零 GUI:纯逻辑直执行,无弹窗)
        switch registry.invoke(capabilityID: "demo.note.set",
                               input: .object(["key": .string("k"), "value": .string("v")])) {
        case .success(let out):
            report.check(out.objectValue?["set"] == JSONValue.bool(true), "invoke demo.note.set(normal)成功、零 GUI 直执行")
        case .failure:
            report.check(false, "invoke demo.note.set(合法 input)应成功")
        }
    }

    // ④ dangerous seam:注入一个 dangerous 假件,invoke 到它返回 not_implemented(留给 04)
    private static func runDangerousSeamTest(_ report: inout TestReport) {
        let registry = Registry(capabilities: [fakeCapability(id: "fake.danger", risk: .dangerous)])
        report.check(errorCode(registry.invoke(capabilityID: "fake.danger", input: nil))
                        == WireErrorCode.notImplemented,
                     "invoke dangerous 能力 → not_implemented(04 票 seam)")
    }

    // ⑤ 契约往返:RiskLevel 与 JSONValue 经 JSON 编解码稳定
    private static func runContractRoundTripTests(_ report: inout TestReport) {
        report.check(riskLevelRoundTrips(), "RiskLevel 三档经 JSON 编解码往返稳定")
        report.check(jsonValueRoundTrips(), "JSONValue 各类型经 JSON 编解码往返稳定")
    }

    // ⑥ 退出码映射:每个 error.code → 期望退出码
    private static func runExitCodeMappingTests(_ report: inout TestReport) {
        report.check(AAExitCode.forErrorCode(WireErrorCode.capabilityFailed) == AAExitCode.capabilityFailure,
                     "映射: capability_failed → 5")
        report.check(AAExitCode.forErrorCode(WireErrorCode.denied) == AAExitCode.denied,
                     "映射: denied → 2(04 票)")
        report.check(AAExitCode.forErrorCode(WireErrorCode.unknownCapability) == AAExitCode.protocolError,
                     "映射: unknown_capability → 6")
        report.check(AAExitCode.forErrorCode(WireErrorCode.missingParameter) == AAExitCode.protocolError,
                     "映射: missing_parameter → 6")
        report.check(AAExitCode.forErrorCode(WireErrorCode.typeMismatch) == AAExitCode.protocolError,
                     "映射: type_mismatch → 6")
        report.check(AAExitCode.forErrorCode("some_unknown_code") == AAExitCode.protocolError,
                     "映射: 未知 code → 6(保守)")
    }

    // ============ 助手 ============

    /// 构造一个只用于 list/seam 测试的假件能力(handler 回显固定值)。
    private static func fakeCapability(id: String, risk: RiskLevel) -> Capability {
        Capability(
            descriptor: CapabilityDescriptor(id: id, risk: risk, summary: "假件 \(id)"),
            handler: { _ in .success(.object(["fake": .string(id)])) }
        )
    }

    /// 取 InvokeOutcome 的 error.code(成功则返回 nil)。
    private static func errorCode(_ outcome: InvokeOutcome) -> String? {
        if case let .failure(err) = outcome { return err.code }
        return nil
    }

    private static func riskLevelRoundTrips() -> Bool {
        for level in RiskLevel.allCases {
            guard let data = try? JSONEncoder().encode(level),
                  let back = try? JSONDecoder().decode(RiskLevel.self, from: data),
                  back == level else { return false }
        }
        return true
    }

    private static func jsonValueRoundTrips() -> Bool {
        let samples: [JSONValue] = [
            .null, .bool(true), .bool(false), .number(42), .string("hi"),
            .array([.number(1), .string("x"), .null]),
            .object(["a": .string("b"), "n": .number(3), "flag": .bool(false), "nested": .array([.bool(true)])])
        ]
        for v in samples {
            guard let data = try? JSONEncoder().encode(v),
                  let back = try? JSONDecoder().decode(JSONValue.self, from: data),
                  back == v else { return false }
        }
        return true
    }
}
