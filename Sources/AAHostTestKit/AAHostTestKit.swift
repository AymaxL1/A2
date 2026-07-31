// AAHostTestKit —— 宿主域逻辑的测试基建 / 假件(让 Runtime 在零 macOS 依赖下可单测,spec 测试金字塔次 seam)。
// 依赖边:AAHostTestKit → AAHostRuntime(→ AAContracts)。
//
// 本票(03)在 02 的 list 纯逻辑测试上追加:
//   * invoke 全路径:未知能力 / 缺必填 / 类型不符 / 业务失败 / safe 成功 / normal 成功(零 GUI);
//   * describe 拿到 parameters;JSONValue 经 Codable 往返稳定;退出码映射表(AAExitCode.forErrorCode)逐码正确。
//
// 04 票追加(dangerous 宿主确认的纯逻辑证明,不起宿主 / 不碰 GUI):确认策略是 Runtime 纯逻辑,可用假件驱动三分支——
//   * 假 confirm 返 true  → dangerous invoke 执行 handler 成功;
//   * 假 confirm 返 false → denied,且 handler 绝不执行;
//   * confirm 为 nil(无 GUI 可用)→ fail-closed denied,且 handler 绝不执行(安全保底断言)。
// 「绝不执行」用注入计数器的假 handler 反证(拒绝分支计数须为 0)。
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
        runDangerousConfirmTests(&report)
        runAllowedValuesTests(&report)
        runContractRoundTripTests(&report)
        runExitCodeMappingTests(&report)
        return report
    }

    // ④' 09 票:ParameterSpec.allowedValues 取值域校验(集中在 Registry.validate,纯逻辑,可假件驱动)。
    //    非空 allowedValues + 入参不在其中 → invalid_params(→ 退出码 6);在其中 → 放行执行 handler。
    private static func runAllowedValuesTests(_ report: inout TestReport) {
        let cap = Capability(
            descriptor: CapabilityDescriptor(
                id: "fake.mode", risk: .normal, summary: "假件:带 allowedValues 的枚举参数",
                parameters: [
                    ParameterSpec(name: "mode", type: "string", required: true, description: "枚举",
                                  allowedValues: ["rule", "global", "direct"])
                ]
            ),
            handler: { input in .success(.object(["mode": input?.objectValue?["mode"] ?? .null])) }
        )
        let registry = Registry(capabilities: [cap])

        // 非法取值 → invalid_params(退出码 6),且 handler 不执行(返回的是失败)。
        report.check(errorCode(registry.invoke(capabilityID: "fake.mode", input: .object(["mode": .string("bogus")])))
                        == WireErrorCode.invalidParams,
                     "09 allowedValues:非法取值(bogus)→ invalid_params(退出码6)")
        report.check(AAExitCode.forErrorCode(WireErrorCode.invalidParams) == AAExitCode.protocolError,
                     "09 allowedValues:invalid_params 映射退出码 6")

        // 合法取值 → 放行执行。
        switch registry.invoke(capabilityID: "fake.mode", input: .object(["mode": .string("global")])) {
        case .success(let out):
            report.check(out.objectValue?["mode"]?.stringValue == "global", "09 allowedValues:合法取值(global)放行执行")
        case .failure:
            report.check(false, "09 allowedValues:合法取值不应失败")
        case .pending:
            report.check(false, "09 allowedValues:safe 能力不应 pending")
        }

        // 无 allowedValues 的参数(向后兼容):任意 string 取值放行(不因加法而收紧既有能力)。
        let free = Registry(capabilities: [
            Capability(descriptor: CapabilityDescriptor(id: "fake.free", risk: .safe, summary: "无取值域约束",
                        parameters: [ParameterSpec(name: "x", type: "string", required: true, description: "自由")]),
                       handler: { _ in .success(.object(["ok": .bool(true)])) })
        ])
        switch free.invoke(capabilityID: "fake.free", input: .object(["x": .string("anything")])) {
        case .success: report.check(true, "09 allowedValues:未声明 allowedValues 的参数不约束取值(向后兼容)")
        case .failure: report.check(false, "09 allowedValues:无约束参数任意取值应放行")
        case .pending: report.check(false, "09 allowedValues:safe 能力不应 pending")
        }
    }

    // ① list:默认注册表 + 假件 seam 透传
    private static func runListTests(_ report: inout TestReport) {
        let caps = Registry().list()
        report.check(!caps.isEmpty, "默认注册表 list() 非空")
        report.check(caps.contains { $0.id == "demo.echo" }, "list() 含 demo.echo")
        report.check(caps.contains { $0.id == "demo.note.set" }, "list() 含 demo.note.set(normal demo)")
        report.check(caps.contains { $0.id == "demo.wipe" && $0.risk == .dangerous },
                     "list() 含 demo.wipe(dangerous demo,04 票新增)")
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
        case .pending:
            report.check(false, "invoke demo.echo(safe)不应 pending")
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
        case .pending:
            report.check(false, "invoke demo.note.set(normal)不应 pending")
        }
    }

    // ④ dangerous 宿主确认(04 票安全核):确认策略是 Runtime 纯逻辑,用假 confirm 驱动三分支。
    //    「绝不执行」用注入计数器的假 handler 反证:拒绝分支计数须为 0,批准分支计数须为 1。
    private static func runDangerousConfirmTests(_ report: inout TestReport) {
        // 构造一个 dangerous 假件:handler 每被调一次即 bump 计数,并回执哨兵成功值。
        func makeRegistry(confirm: ConfirmDangerous?, counter: CallCounter) -> Registry {
            let cap = Capability(
                descriptor: CapabilityDescriptor(id: "fake.danger", risk: .dangerous, summary: "假件危险能力"),
                handler: { _ in counter.bump(); return .success(.object(["executed": .bool(true)])) }
            )
            return Registry(capabilities: [cap], confirmDangerous: confirm)
        }

        // 分支①:假 confirm 返 true → 批准 → 执行 handler 成功,且恰执行一次。
        let c1 = CallCounter()
        switch makeRegistry(confirm: { _, _, reply in reply(true) }, counter: c1).invoke(capabilityID: "fake.danger", input: nil) {
        case .success(let out):
            report.check(out.objectValue?["executed"] == .bool(true), "dangerous + 假 confirm=true → 执行 handler 成功")
        case .failure:
            report.check(false, "dangerous + 假 confirm=true 应成功执行")
        case .pending:
            report.check(false, "同步假 confirm=true 不应 pending")
        }
        report.check(c1.count == 1, "假 confirm=true 时 handler 恰执行一次")

        // 分支②:假 confirm 返 false → denied,且 handler 绝不执行。
        let c2 = CallCounter()
        report.check(errorCode(makeRegistry(confirm: { _, _, reply in reply(false) }, counter: c2).invoke(capabilityID: "fake.danger", input: nil))
                        == WireErrorCode.denied, "dangerous + 假 confirm=false → denied")
        report.check(c2.count == 0, "假 confirm=false 时 handler 绝不执行(未被绕过)")

        // 分支③(安全保底):confirm 为 nil(无 GUI 可用)→ fail-closed denied,且 handler 绝不执行。
        let c3 = CallCounter()
        report.check(errorCode(makeRegistry(confirm: nil, counter: c3).invoke(capabilityID: "fake.danger", input: nil))
                        == WireErrorCode.denied, "dangerous + confirm=nil → fail-closed denied(无 GUI 可用时拒绝执行)")
        report.check(c3.count == 0, "confirm=nil 时 handler 绝不执行(fail-closed 保底)")

        // 分支④(10 票 F2:确认回调确实收到 input → 不再盲批)。invoke 把本次请求 input 透传给确认回调。
        let c4 = CallCounter()
        let received = ReceivedInputBox()
        let reg4 = makeRegistry(confirm: { _, input, reply in received.value = input; reply(true) }, counter: c4)
        _ = reg4.invoke(capabilityID: "fake.danger", input: .object(["target": .string("disk9")]))
        report.check(received.value == .object(["target": .string("disk9")]),
                     "10 F2:dangerous 确认回调确实收到本次请求的 input(不再盲批)")
        report.check(c4.count == 1, "10 F2:批准后 handler 执行一次(input 透传不影响执行语义)")

        // Delayed GUI-style confirmation must not hold the invoking request open.
        let c5 = CallCounter()
        let delayed = ConfirmationReplyBox()
        let reg5 = makeRegistry(confirm: { _, _, reply in delayed.reply = reply }, counter: c5)
        let pendingID: String?
        switch reg5.invoke(capabilityID: "fake.danger", input: nil) {
        case .pending(let id): pendingID = id
        default: pendingID = nil
        }
        report.check(pendingID != nil, "dangerous 异步确认 → invoke 立即返回 pending requestId")
        if let id = pendingID {
            report.check(reg5.invocationStatus(requestID: id) == .pending,
                         "结果查询:用户决定前状态为 pending")
            delayed.reply?(true)
            switch reg5.invocationStatus(requestID: id) {
            case .completed(.success(let output)):
                report.check(output.objectValue?["executed"] == .bool(true),
                             "结果查询:批准后返回能力输出")
            default:
                report.check(false, "结果查询:批准后应 completed(success)")
            }
        }
        report.check(c5.count == 1, "异步批准后 handler 恰执行一次")
    }

    /// 捕获确认回调收到的 input(证明不再盲批)。`@unchecked Sendable`:测试同步单线程驱动。
    private final class ReceivedInputBox: @unchecked Sendable {
        var value: JSONValue?
    }

    private final class ConfirmationReplyBox: @unchecked Sendable {
        var reply: (@Sendable (Bool) -> Void)?
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

    /// 执行计数器(证明 dangerous handler「是否真被执行」)。
    /// `@unchecked Sendable`:测试同步单线程驱动,无并发访问;仅为满足 `@Sendable` handler 可捕获引用类型。
    private final class CallCounter: @unchecked Sendable {
        private(set) var count = 0
        func bump() { count += 1 }
    }

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
