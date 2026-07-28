// AAHostRuntime —— 能力注册表 + invoke 校验/路由(纯逻辑,零 AppKit / 零 UDS)。
// 呼应 07 票测试金字塔:Runtime 保持平台无关纯逻辑,可被 AAHostTestKit 假件驱动单测;
// 副作用(GUI 确认 / networksetup / 子进程)一律压到宿主具体层(AAHostMacOS)。
//
// 03 票:注册表从「只有 descriptor」升级为「descriptor + handler」。invoke 是宿主侧集中校验的唯一入口
// (客户端不可绕过):①未知能力 ②schema 校验(必填/类型)③按 risk 路由 ④业务错误结构化。
// safe/normal 直接执行 handler(normal 零 GUI 打断);dangerous 本票不做,留 seam 给 04 票(确认回调注入)。

import AAContracts

/// 能力处理器:纯闭包,吃 input(可空,已过 schema 校验)吐输出或业务错误。
/// - `@Sendable`:handler 不得捕获可变状态(demo 用不可变/值语义),从而 `Capability`/`Registry` 天然 Sendable。
public typealias CapabilityHandler = @Sendable (JSONValue?) -> Result<JSONValue, WireError>

/// 一个已注册能力 = 描述符 + 处理器。
public struct Capability: Sendable {
    public let descriptor: CapabilityDescriptor
    public let handler: CapabilityHandler

    public init(descriptor: CapabilityDescriptor, handler: @escaping CapabilityHandler) {
        self.descriptor = descriptor
        self.handler = handler
    }
}

/// invoke 的结构化结果(纯逻辑产物,由宿主具体层包成 WireResponse)。
public enum InvokeOutcome: Sendable, Equatable {
    /// 成功:能力输出(任意 JSON)。
    case success(JSONValue)
    /// 失败:结构化错误(code 决定退出码粗分类,见 `AAExitCode.forErrorCode`)。
    case failure(WireError)
}

/// 能力注册表。构造时收下一组 `Capability`(默认种入 demo 能力),对外暴露 `list()` / `describe(_:)` / `invoke(...)`。
///
/// 设计取舍:
/// - 构造注入(`init(capabilities:)`)、存储不可变、`final` + 全 Sendable 存储 → 天然 `Sendable`,
///   宿主可在多个连接处理线程并发 list/describe/invoke 而无数据竞争。
/// - 构造注入即「测试基建的 seam」:AAHostTestKit 可注入自定义能力集(含假 handler)直接驱动 invoke,
///   不起真宿主、不碰 UDS、不 import AppKit。
public final class Registry: Sendable {
    /// 03 票 demo 能力集:一条 safe(`demo.echo`)+ 一条 normal(`demo.note.set`)。
    /// 两者都带结构化 parameters,让 agent 经 describe 即可构造合法调用。dangerous demo 本票不注册
    /// (invoke 的 dangerous 分支仍留 seam,见下)。
    public static let demoCapabilities: [Capability] = [
        Capability(
            descriptor: CapabilityDescriptor(
                id: "demo.echo",
                risk: .safe,
                summary: "原样回显 message(纵切演示:safe 只读能力)",
                schemaSummary: "input: { message: String } → output: { echo: <message> }",
                parameters: [
                    ParameterSpec(name: "message", type: "string", required: true,
                                  description: "要回显的文本(必填);传 \"boom\" 触发演示用业务失败")
                ]
            ),
            handler: { input in
                // input 已过 invoke 的 schema 校验:必是含 message:string 的对象。
                guard let msg = input?.objectValue?["message"] else {
                    return .failure(WireError(code: WireErrorCode.invalidParams, detail: "内部错:input 缺 message"))
                }
                // 演示业务失败(→ 退出码 5):特定输入让能力「执行了但返回错误」。
                if msg.stringValue == "boom" {
                    return .failure(WireError(code: WireErrorCode.capabilityFailed,
                                              detail: "echo 业务失败:拒绝处理 'boom'(演示 capability_failed → 退出码 5)"))
                }
                return .success(.object(["echo": msg]))
            }
        ),
        Capability(
            descriptor: CapabilityDescriptor(
                id: "demo.note.set",
                risk: .normal,
                summary: "设置一条便签(纵切演示:normal 可逆状态变更,零 GUI 打断)",
                schemaSummary: "input: { key: String, value: String } → output: { set: true, key, value }",
                parameters: [
                    ParameterSpec(name: "key", type: "string", required: true, description: "便签键(必填)"),
                    ParameterSpec(name: "value", type: "string", required: true, description: "便签值(必填)")
                ]
            ),
            handler: { input in
                // 纯逻辑/无状态演示:normal 档「可逆状态变更」的形状与执行路径,零 GUI、零副作用、可 headless。
                // (真实的 normal 能力会落到 Host Port 之后做副作用;demo 只证明 normal 直执行、不弹窗打断。)
                guard let obj = input?.objectValue, let k = obj["key"], let v = obj["value"] else {
                    return .failure(WireError(code: WireErrorCode.invalidParams, detail: "内部错:input 缺 key/value"))
                }
                return .success(.object(["set": .bool(true), "key": k, "value": v]))
            }
        )
    ]

    private let capabilities: [Capability]
    private let byID: [String: Capability]

    /// - Parameter capabilities: 待注册的能力集,缺省为 `demoCapabilities`。
    public init(capabilities: [Capability] = Registry.demoCapabilities) {
        self.capabilities = capabilities
        var map = [String: Capability]()
        for c in capabilities { map[c.descriptor.id] = c }
        self.byID = map
    }

    /// 列出已注册能力的描述符(顺序即注册顺序)。
    public func list() -> [CapabilityDescriptor] {
        capabilities.map { $0.descriptor }
    }

    /// 取单个能力的描述符(含 parameters);未知能力返回 nil。
    public func describe(_ id: String) -> CapabilityDescriptor? {
        byID[id]?.descriptor
    }

    /// 宿主侧集中调用入口(不可绕过):校验 + 风险路由 + 执行。
    public func invoke(capabilityID: String, input: JSONValue?) -> InvokeOutcome {
        // ① 未知能力 → 协议/校验错(退出码 6)
        guard let cap = byID[capabilityID] else {
            return .failure(WireError(code: WireErrorCode.unknownCapability,
                                      detail: "未知能力: \(capabilityID)"))
        }
        // ② 按 descriptor.parameters 集中校验 input(必填缺失 / 类型不符 → 退出码 6)
        if let validationError = Registry.validate(input: input, against: cap.descriptor.parameters) {
            return .failure(validationError)
        }
        // ③ 按 risk 路由
        switch cap.descriptor.risk {
        case .safe, .normal:
            // safe/normal 直接执行 handler;normal 零 GUI 打断(副作用归 Host Port,demo 为纯逻辑)。
            switch cap.handler(input) {
            case .success(let output):
                return .success(output)
            case .failure(let bizErr):
                // ④ handler 返回业务错误(通常 code=capability_failed → 退出码 5)
                return .failure(bizErr)
            }
        case .dangerous:
            // 本票不做:dangerous 需宿主 GUI 最终确认。留 seam 给 04 票(注入确认回调后在此路由)。
            // 03 未注册任何 dangerous demo;此分支仅为防御性 seam(有人注入 dangerous 能力时明确不静默执行)。
            return .failure(WireError(code: WireErrorCode.notImplemented,
                                      detail: "dangerous 能力的宿主确认留待 04 票: \(capabilityID)"))
        }
    }

    // ============ 集中 schema 校验(纯逻辑,可单测)============

    /// 校验 input 是否满足 parameters 声明。通过返回 nil;不通过返回结构化 `WireError`(code → 退出码 6)。
    /// 规则:
    /// - 无参数声明(parameters 空)→ 放行任意 input(含 nil)。
    /// - 有参数声明 → input 须为对象;非对象(且提供了)→ `type_mismatch`;缺失/为 null 且有必填 → `missing_parameter`。
    /// - 逐参数:必填缺失/为 null → `missing_parameter`;存在但类型不符 → `type_mismatch`;可选缺省放行。
    ///
    /// V1 策略(有意的宽松取舍,非漏校验):**只拒绝「缺必填 / 类型不符」两类**;
    /// 对声明外的多余/未知输入字段一律**静默放行**(只遍历 params、不反向遍历 input 的键)。
    /// 理由:向前兼容(老宿主收到新客户端多带的字段不至于硬失败),且 V1 不上重量级 JSON Schema(YAGNI)。
    /// 若将来需要「拒绝未知字段」的严格模式,再在此加开关,不改现有调用方。
    static func validate(input: JSONValue?, against params: [ParameterSpec]) -> WireError? {
        if params.isEmpty { return nil }

        let obj: [String: JSONValue]
        switch input {
        case .some(.object(let o)):
            obj = o
        case .none, .some(.null):
            // input 整体缺失:若有任一必填参数即报缺参
            if let firstRequired = params.first(where: { $0.required }) {
                return WireError(code: WireErrorCode.missingParameter,
                                 detail: "缺少必填参数: \(firstRequired.name)")
            }
            obj = [:]
        default:
            // 提供了 input 但不是对象 → 无法按参数名取值
            return WireError(code: WireErrorCode.typeMismatch,
                             detail: "input 必须是 JSON 对象,实际为 \(input?.typeName ?? "null")")
        }

        for p in params {
            guard let value = obj[p.name] else {
                if p.required {
                    return WireError(code: WireErrorCode.missingParameter, detail: "缺少必填参数: \(p.name)")
                }
                continue // 可选参数缺省允许
            }
            if case .null = value {
                if p.required {
                    return WireError(code: WireErrorCode.missingParameter, detail: "必填参数为 null: \(p.name)")
                }
                continue // 可选参数显式 null 视为缺省
            }
            if !Registry.typeMatches(value: value, expected: p.type) {
                return WireError(code: WireErrorCode.typeMismatch,
                                 detail: "参数 \(p.name) 类型应为 \(p.type),实际为 \(value.typeName)")
            }
        }
        return nil
    }

    /// 值类型是否匹配 schema 声明的简单类型串。未知期望类型不阻断(schema 作者责任;V1 宽松)。
    static func typeMatches(value: JSONValue, expected: String) -> Bool {
        switch expected {
        case "string": if case .string = value { return true }
        case "number": if case .number = value { return true }
        case "bool":   if case .bool = value { return true }
        case "object": if case .object = value { return true }
        case "array":  if case .array = value { return true }
        default: return true
        }
        return false
    }
}
