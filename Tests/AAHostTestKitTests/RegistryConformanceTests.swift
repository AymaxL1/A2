// 17 票:从 `AAHostTestKit.RegistryConformanceTests`(手写 TestReport)迁到 swift-testing。
//
// 迁移口径(全仓统一,只写这一遍,其余文件不再复述):
//   ① **一条旧 `report.check(cond, "文案")` = 一条 `#expect(cond, "文案")`**(或 `#require` / `Issue.record`)。
//      文案逐字保留 —— 它既是失败时的人读诊断,也是「没有静默丢断言」的机械可核验证据(数得出来)。
//   ② 凡是 `Scripts/check/*.sh` 拿 `assert_contains` grep 的那些文案,**必须成为某个 `@Test` 的名字**:
//      swift-testing 会把用例名打进 `swift test` 的输出(`◇ Test "…" started.` / `✔ Test "…" passed`),
//      于是那 98 条 shell 断言一个字都不用改就继续成立。改这些 `@Test` 名等于改门禁,不许顺手润色。
//   ③ 旧 runner 打印的 `XXX_TESTS passed=` 汇总行被 shell grep 当「本套件确实跑了」的证据。
//      swift-testing 里等价且更强的证据是 `✔ Suite "…" passed`,故把那个标记原样嵌进 `@Suite` 名。
//
// 依赖边:AAHostTestKitTests → AAHostRuntime / AAContracts(+ AAHostTestKit 的假件,本文件用不到)。

import Foundation
import Testing
import AAContracts
import AAHostRuntime

@Suite("02–04 Registry 纯逻辑(list / describe / invoke 全路径 / dangerous 确认 / 契约往返 / 退出码映射)—— REGISTRY_TESTS passed=(逐条 @Test)")
struct RegistryConformanceTests {

    // ============ ① list:默认注册表 + 假件 seam 透传 ============

    @Test("默认注册表 list() 含 demo.echo / demo.note.set / demo.wipe,且各自风险档正确")
    func listDefaultRegistry() {
        let caps = Registry().list()
        #expect(!caps.isEmpty, "默认注册表 list() 非空")
        #expect(caps.contains { $0.id == "demo.echo" }, "list() 含 demo.echo")
        #expect(caps.contains { $0.id == "demo.note.set" }, "list() 含 demo.note.set(normal demo)")
        #expect(caps.contains { $0.id == "demo.wipe" && $0.risk == .dangerous },
                "list() 含 demo.wipe(dangerous demo,04 票新增)")
        if let echo = caps.first(where: { $0.id == "demo.echo" }) {
            #expect(echo.risk == .safe, "demo.echo 风险档为 safe")
            #expect(echo.schemaSummary != nil, "demo.echo 携带 schemaSummary")
            #expect(!echo.parameters.isEmpty, "demo.echo 携带结构化 parameters")
        } else {
            Issue.record("定位 demo.echo 描述符")
        }
        if let note = caps.first(where: { $0.id == "demo.note.set" }) {
            #expect(note.risk == .normal, "demo.note.set 风险档为 normal")
        }
    }

    @Test("假件 seam:注入的能力集被 list() 原样透传(含顺序,不碰 UDS / AppKit)")
    func listFakeSeam() {
        let fake = Registry(capabilities: [
            Self.fakeCapability(id: "fake.alpha", risk: .normal),
            Self.fakeCapability(id: "fake.beta", risk: .safe)
        ]).list()
        #expect(fake.count == 2, "假件注册表 list() 数量与注入一致(2)")
        #expect(fake.map { $0.id } == ["fake.alpha", "fake.beta"], "假件能力集被 list() 原样透传(含顺序)")
    }

    // ============ ② describe:拿得到 parameters(name/type/required),足以构造调用 ============

    @Test("describe:未知能力返回 nil;demo.echo 交回可构造调用的 parameters")
    func describe() {
        let registry = Registry()
        #expect(registry.describe("demo.nope") == nil, "describe 未知能力返回 nil")
        if let d = registry.describe("demo.echo") {
            let msg = d.parameters.first { $0.name == "message" }
            #expect(msg != nil, "describe demo.echo 含参数 message")
            #expect(msg?.type == "string", "describe demo.echo 参数 message 类型为 string")
            #expect(msg?.required == true, "describe demo.echo 参数 message 为必填")
        } else {
            Issue.record("describe demo.echo 非空")
        }
    }

    // ============ ③ invoke:未知 / 缺必填 / 类型不符 / 业务失败 / safe 成功 / normal 成功 ============

    @Test("invoke 校验层:未知能力 / 缺必填 / 类型不符各自收敛到对的 error.code")
    func invokeValidation() {
        let registry = Registry()
        #expect(Self.errorCode(registry.invoke(capabilityID: "demo.nope", input: .object([:])))
                == WireErrorCode.unknownCapability, "invoke 未知能力 → unknown_capability")
        #expect(Self.errorCode(registry.invoke(capabilityID: "demo.echo", input: .object([:])))
                == WireErrorCode.missingParameter, "invoke 缺必填 message → missing_parameter")
        #expect(Self.errorCode(registry.invoke(capabilityID: "demo.echo", input: .object(["message": .number(1)])))
                == WireErrorCode.typeMismatch, "invoke message 类型不符 → type_mismatch")
    }

    @Test("invoke 执行层:safe 回显 / 业务失败 / normal 零 GUI 直执行")
    func invokeExecution() {
        let registry = Registry()

        switch registry.invoke(capabilityID: "demo.echo", input: .object(["message": .string("hi")])) {
        case .success(let out):
            #expect(out.objectValue?["echo"]?.stringValue == "hi", "invoke demo.echo 成功且回显 message")
        case .failure:
            Issue.record("invoke demo.echo(合法 input)应成功")
        case .pending:
            Issue.record("invoke demo.echo(safe)不应 pending")
        }

        #expect(Self.errorCode(registry.invoke(capabilityID: "demo.echo", input: .object(["message": .string("boom")])))
                == WireErrorCode.capabilityFailed, "invoke demo.echo boom → capability_failed(业务失败)")

        switch registry.invoke(capabilityID: "demo.note.set",
                               input: .object(["key": .string("k"), "value": .string("v")])) {
        case .success(let out):
            #expect(out.objectValue?["set"] == JSONValue.bool(true), "invoke demo.note.set(normal)成功、零 GUI 直执行")
        case .failure:
            Issue.record("invoke demo.note.set(合法 input)应成功")
        case .pending:
            Issue.record("invoke demo.note.set(normal)不应 pending")
        }
    }

    // ============ ④ dangerous 宿主确认(04 票安全核):三分支 + 计数器反证 ============

    @Test("假 confirm=true 时 handler 恰执行一次")
    func dangerousConfirmApproved() {
        let c1 = CallCounter()
        switch Self.makeRegistry(confirm: { _, _, reply in reply(true) }, counter: c1)
            .invoke(capabilityID: "fake.danger", input: nil) {
        case .success(let out):
            #expect(out.objectValue?["executed"] == .bool(true), "dangerous + 假 confirm=true → 执行 handler 成功")
        case .failure:
            Issue.record("dangerous + 假 confirm=true 应成功执行")
        case .pending:
            Issue.record("同步假 confirm=true 不应 pending")
        }
        #expect(c1.count == 1, "假 confirm=true 时 handler 恰执行一次")
    }

    @Test("dangerous + 假 confirm=false → denied,且 handler 绝不执行")
    func dangerousConfirmDenied() {
        let c2 = CallCounter()
        #expect(Self.errorCode(Self.makeRegistry(confirm: { _, _, reply in reply(false) }, counter: c2)
                    .invoke(capabilityID: "fake.danger", input: nil)) == WireErrorCode.denied,
                "dangerous + 假 confirm=false → denied")
        #expect(c2.count == 0, "假 confirm=false 时 handler 绝不执行(未被绕过)")
    }

    @Test("confirm=nil 时 handler 绝不执行(fail-closed 保底)")
    func dangerousConfirmMissingIsFailClosed() {
        let c3 = CallCounter()
        #expect(Self.errorCode(Self.makeRegistry(confirm: nil, counter: c3)
                    .invoke(capabilityID: "fake.danger", input: nil)) == WireErrorCode.denied,
                "dangerous + confirm=nil → fail-closed denied(无 GUI 可用时拒绝执行)")
        #expect(c3.count == 0, "confirm=nil 时 handler 绝不执行(fail-closed 保底)")
    }

    @Test("10 F2:dangerous 确认回调确实收到本次请求的 input(不再盲批)")
    func dangerousConfirmReceivesInput() {
        let c4 = CallCounter()
        let received = ReceivedInputBox()
        let reg4 = Self.makeRegistry(confirm: { _, input, reply in received.value = input; reply(true) }, counter: c4)
        _ = reg4.invoke(capabilityID: "fake.danger", input: .object(["target": .string("disk9")]))
        #expect(received.value == .object(["target": .string("disk9")]),
                "10 F2:dangerous 确认回调确实收到本次请求的 input(不再盲批)")
        #expect(c4.count == 1, "10 F2:批准后 handler 执行一次(input 透传不影响执行语义)")
    }

    @Test("延迟的 GUI 式确认不占住调用请求:invoke 立即 pending,结果经 invocationStatus 查询")
    func dangerousConfirmAsyncPending() {
        let c5 = CallCounter()
        let delayed = ConfirmationReplyBox()
        let reg5 = Self.makeRegistry(confirm: { _, _, reply in delayed.reply = reply }, counter: c5)
        let pendingID: String?
        switch reg5.invoke(capabilityID: "fake.danger", input: nil) {
        case .pending(let id): pendingID = id
        default: pendingID = nil
        }
        #expect(pendingID != nil, "dangerous 异步确认 → invoke 立即返回 pending requestId")
        if let id = pendingID {
            #expect(reg5.invocationStatus(requestID: id) == .pending, "结果查询:用户决定前状态为 pending")
            delayed.reply?(true)
            switch reg5.invocationStatus(requestID: id) {
            case .completed(.success(let output)):
                #expect(output.objectValue?["executed"] == .bool(true), "结果查询:批准后返回能力输出")
            default:
                Issue.record("结果查询:批准后应 completed(success)")
            }
        }
        #expect(c5.count == 1, "异步批准后 handler 恰执行一次")
    }

    // ============ ④' 09 票:ParameterSpec.allowedValues 取值域校验 ============

    @Test("09 allowedValues:非法取值(bogus)→ invalid_params(退出码6)")
    func allowedValuesRejectsIllegal() {
        let registry = Registry(capabilities: [Self.allowedValuesCapability()])
        #expect(Self.errorCode(registry.invoke(capabilityID: "fake.mode", input: .object(["mode": .string("bogus")])))
                == WireErrorCode.invalidParams,
                "09 allowedValues:非法取值(bogus)→ invalid_params(退出码6)")
        #expect(AAExitCode.forErrorCode(WireErrorCode.invalidParams) == AAExitCode.protocolError,
                "09 allowedValues:invalid_params 映射退出码 6")
    }

    @Test("09 allowedValues:合法取值(global)放行执行")
    func allowedValuesAcceptsLegal() {
        let registry = Registry(capabilities: [Self.allowedValuesCapability()])
        switch registry.invoke(capabilityID: "fake.mode", input: .object(["mode": .string("global")])) {
        case .success(let out):
            #expect(out.objectValue?["mode"]?.stringValue == "global", "09 allowedValues:合法取值(global)放行执行")
        case .failure:
            Issue.record("09 allowedValues:合法取值不应失败")
        case .pending:
            Issue.record("09 allowedValues:safe 能力不应 pending")
        }
    }

    @Test("09 allowedValues:未声明 allowedValues 的参数不约束取值(向后兼容)")
    func allowedValuesBackwardCompatible() {
        let free = Registry(capabilities: [
            Capability(descriptor: CapabilityDescriptor(id: "fake.free", risk: .safe, summary: "无取值域约束",
                        parameters: [ParameterSpec(name: "x", type: "string", required: true, description: "自由")]),
                       handler: { _ in .success(.object(["ok": .bool(true)])) })
        ])
        switch free.invoke(capabilityID: "fake.free", input: .object(["x": .string("anything")])) {
        case .success:
            #expect(Bool(true), "09 allowedValues:未声明 allowedValues 的参数不约束取值(向后兼容)")
        case .failure:
            Issue.record("09 allowedValues:无约束参数任意取值应放行")
        case .pending:
            Issue.record("09 allowedValues:safe 能力不应 pending")
        }
    }

    // ============ ⑤ 契约往返 ============

    @Test("契约往返:RiskLevel 与 JSONValue 经 JSON 编解码稳定")
    func contractRoundTrip() {
        #expect(Self.riskLevelRoundTrips(), "RiskLevel 三档经 JSON 编解码往返稳定")
        #expect(Self.jsonValueRoundTrips(), "JSONValue 各类型经 JSON 编解码往返稳定")
    }

    // ============ ⑥ 退出码映射:每个 error.code → 期望退出码 ============

    @Test("退出码映射:每个 error.code 逐码映射正确(未知 code 保守归 6)")
    func exitCodeMapping() {
        #expect(AAExitCode.forErrorCode(WireErrorCode.capabilityFailed) == AAExitCode.capabilityFailure,
                "映射: capability_failed → 5")
        #expect(AAExitCode.forErrorCode(WireErrorCode.denied) == AAExitCode.denied,
                "映射: denied → 2(04 票)")
        #expect(AAExitCode.forErrorCode(WireErrorCode.unknownCapability) == AAExitCode.protocolError,
                "映射: unknown_capability → 6")
        #expect(AAExitCode.forErrorCode(WireErrorCode.missingParameter) == AAExitCode.protocolError,
                "映射: missing_parameter → 6")
        #expect(AAExitCode.forErrorCode(WireErrorCode.typeMismatch) == AAExitCode.protocolError,
                "映射: type_mismatch → 6")
        #expect(AAExitCode.forErrorCode("some_unknown_code") == AAExitCode.protocolError,
                "映射: 未知 code → 6(保守)")
    }

    // ============ 助手(与旧套件逐字同源)============

    /// 执行计数器(证明 dangerous handler「是否真被执行」)。
    /// `@unchecked Sendable`:测试同步单线程驱动,无并发访问;仅为满足 `@Sendable` handler 可捕获引用类型。
    final class CallCounter: @unchecked Sendable {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    /// 捕获确认回调收到的 input(证明不再盲批)。`@unchecked Sendable`:测试同步单线程驱动。
    final class ReceivedInputBox: @unchecked Sendable {
        var value: JSONValue?
    }

    final class ConfirmationReplyBox: @unchecked Sendable {
        var reply: (@Sendable (Bool) -> Void)?
    }

    /// 构造一个 dangerous 假件:handler 每被调一次即 bump 计数,并回执哨兵成功值。
    static func makeRegistry(confirm: ConfirmDangerous?, counter: CallCounter) -> Registry {
        let cap = Capability(
            descriptor: CapabilityDescriptor(id: "fake.danger", risk: .dangerous, summary: "假件危险能力"),
            handler: { _ in counter.bump(); return .success(.object(["executed": .bool(true)])) }
        )
        return Registry(capabilities: [cap], confirmDangerous: confirm)
    }

    /// 带 allowedValues 的枚举参数假件。
    static func allowedValuesCapability() -> Capability {
        Capability(
            descriptor: CapabilityDescriptor(
                id: "fake.mode", risk: .normal, summary: "假件:带 allowedValues 的枚举参数",
                parameters: [
                    ParameterSpec(name: "mode", type: "string", required: true, description: "枚举",
                                  allowedValues: ["rule", "global", "direct"])
                ]
            ),
            handler: { input in .success(.object(["mode": input?.objectValue?["mode"] ?? .null])) }
        )
    }

    /// 构造一个只用于 list/seam 测试的假件能力(handler 回显固定值)。
    static func fakeCapability(id: String, risk: RiskLevel) -> Capability {
        Capability(
            descriptor: CapabilityDescriptor(id: id, risk: risk, summary: "假件 \(id)"),
            handler: { _ in .success(.object(["fake": .string(id)])) }
        )
    }

    /// 取 InvokeOutcome 的 error.code(成功则返回 nil)。
    static func errorCode(_ outcome: InvokeOutcome) -> String? {
        if case let .failure(err) = outcome { return err.code }
        return nil
    }

    static func riskLevelRoundTrips() -> Bool {
        for level in RiskLevel.allCases {
            guard let data = try? JSONEncoder().encode(level),
                  let back = try? JSONDecoder().decode(RiskLevel.self, from: data),
                  back == level else { return false }
        }
        return true
    }

    static func jsonValueRoundTrips() -> Bool {
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
