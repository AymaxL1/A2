// A2Contract —— 能力 manifest 与内核运行态(对照 `wire.ts` 的「能力 manifest」与 `StatusResultSchema`)。
//
// 为什么这两族在 09 票的镜像范围内:它们是**快照的组成部分** —— `KernelSnapshot.status` 与
// `KernelSnapshot.capabilities`,确认请求里还嵌着完整的 `CapabilityDescriptor`。
// 壳(10 票)要投影它们,所以必须有对照物;而各能力自己的 result 形状(proxy.* / service.* / mihomo.*)
// **不在镜像范围**,理由见 `A2ContractMirror`。

import Foundation

/// 风险三档(对照 `RiskLevelSchema`)。取值即契约,未知取值必须解码失败(有 invalid 金标守着)。
public enum A2RiskLevel: String, Sendable, Codable, Equatable, CaseIterable {
    /// 只读,直通。
    case safe
    /// 可逆写,直通(不打断、零确认)。
    case normal
    /// 需真人在场证明,走三层仲裁。
    case dangerous
}

/// 参数类型词汇表(对照 `ParameterTypeSchema`)。取的是 **JSON Schema 的词**(`boolean` 而非 `bool`)。
public enum A2ParameterType: String, Sendable, Codable, Equatable, CaseIterable {
    case string
    case number
    case boolean
    case object
    case array
}

/// 单个参数的声明(对照 `ParameterSpecSchema`)。
public struct A2ParameterSpec: Sendable, Equatable {
    public let name: String
    public let type: A2ParameterType
    public let required: Bool
    public let description: String
    /// 仅对 string 生效;缺省 = 不约束取值。
    public let allowedValues: [String]?

    public init(
        name: String, type: A2ParameterType, required: Bool, description: String,
        allowedValues: [String]? = nil
    ) {
        self.name = name
        self.type = type
        self.required = required
        self.description = description
        self.allowedValues = allowedValues
    }
}

extension A2ParameterSpec: Codable {
    private enum CodingKeys: String, CodingKey { case name, type, required, description, allowedValues }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeNonEmptyString(forKey: .name)
        type = try container.decode(A2ParameterType.self, forKey: .type)
        required = try container.decode(Bool.self, forKey: .required)
        description = try container.decodeNonEmptyString(forKey: .description)
        allowedValues = try container.decodeNonEmptyArrayIfPresent([String].self, forKey: .allowedValues)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(required, forKey: .required)
        try container.encode(description, forKey: .description)
        try container.encodeIfPresent(allowedValues, forKey: .allowedValues)
    }
}

/// dangerous 能力的**确认模式**(对照 `ConfirmationModeSchema`,url-router 施工 04 票)。
///
/// **词表封闭**:未知取值必须解码失败(有 invalid 金标守着)。这一条比别的词表更要紧 ——
/// 它挡的是最坏的一种漂移:有人用一个新取值把 dangerous 的确认整个关掉,而壳装作看懂了。
public enum A2ConfirmationMode: String, Sendable, Codable, Equatable, CaseIterable {
    /// **缺省**:ADR 0005 第 4 条那三层,人在**菜单栏壳的确认框**上点头。
    case confirmAgent = "confirm-agent"
    /// 确认由**操作系统自己的弹框**承载(内核下发执行指令帧 → 壳调系统 API → OS 弹框 → 人点)。
    case osDialog = "os-dialog"
}

/// 能力 manifest(对照 `CapabilityDescriptorSchema`)。
public struct A2CapabilityDescriptor: Sendable, Equatable {
    public let id: String
    public let risk: A2RiskLevel
    public let summary: String
    public let parameters: [A2ParameterSpec]
    /// 域子命令写法(有序 token:`["proxy","on"]` ⇒ `a2 proxy on`);缺省 = 只能用 `capabilities call` 调。
    public let cliAlias: [String]?
    /// 这条 dangerous 的确认由谁承载。**缺省(nil)= `confirm-agent`**,即现状。
    public let confirmation: A2ConfirmationMode?

    public init(
        id: String, risk: A2RiskLevel, summary: String, parameters: [A2ParameterSpec],
        cliAlias: [String]? = nil, confirmation: A2ConfirmationMode? = nil
    ) {
        self.id = id
        self.risk = risk
        self.summary = summary
        self.parameters = parameters
        self.cliAlias = cliAlias
        self.confirmation = confirmation
    }

    /// 缺省归一后的确认模式。**「缺省是什么」只该有一个地方说了算**(内核那侧是
    /// `confirmationModeOf`,这边是它)—— 各处 `?? .confirmAgent` 迟早会有一处写反。
    public var effectiveConfirmation: A2ConfirmationMode { confirmation ?? .confirmAgent }
}

extension A2CapabilityDescriptor: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, risk, summary, parameters, cliAlias, confirmation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeNonEmptyString(forKey: .id)
        risk = try container.decode(A2RiskLevel.self, forKey: .risk)
        summary = try container.decodeNonEmptyString(forKey: .summary)
        // 参数表**可以为空**(无参能力),与 `z.array(...)`(无 min)一致。
        parameters = try container.decode([A2ParameterSpec].self, forKey: .parameters)
        // 契约是 `z.array(z.string().min(1)).min(1).optional()` —— **元素也带 min(1)**,两级都要镜像。
        cliAlias = try container.decodeNonEmptyStringArrayIfPresent(forKey: .cliAlias)
        // 缺席是合法的(= confirm-agent);**带了个不认识的取值必须炸**,不许悄悄退回缺省 ——
        // 那等于把"确认模式变了"这件事当成"没写"。
        confirmation = try container.decodeIfPresent(A2ConfirmationMode.self, forKey: .confirmation)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(risk, forKey: .risk)
        try container.encode(summary, forKey: .summary)
        try container.encode(parameters, forKey: .parameters)
        try container.encodeIfPresent(cliAlias, forKey: .cliAlias)
        try container.encodeIfPresent(confirmation, forKey: .confirmation)
    }
}

/// `status.get` 的 result(对照 `StatusResultSchema`)—— 也是快照的第一块。
public struct A2StatusResult: Sendable, Equatable {
    /// 恒为 `"running"`:能应答就说明活着(不可达是客户端侧的错误分支,不是一种 status 值)。
    public let state: String
    public let version: String
    public let networkProtocol: Int
    public let pid: Int
    public let startedAt: String
    public let uptimeMs: Int
    public let home: String
    public let socketPath: String

    public init(
        state: String = "running", version: String, networkProtocol: Int = A2Protocol.version,
        pid: Int, startedAt: String, uptimeMs: Int, home: String, socketPath: String
    ) {
        self.state = state
        self.version = version
        self.networkProtocol = networkProtocol
        self.pid = pid
        self.startedAt = startedAt
        self.uptimeMs = uptimeMs
        self.home = home
        self.socketPath = socketPath
    }
}

extension A2StatusResult: Codable {
    // 线上的键名是 `protocol` —— Swift 的保留字,故属性叫 networkProtocol,键名在这里对回去。
    private enum CodingKeys: String, CodingKey {
        case state, version, pid, startedAt, uptimeMs, home, socketPath
        case networkProtocol = "protocol"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawState = try container.decodeNonEmptyString(forKey: .state)
        guard rawState == "running" else {
            throw DecodingError.dataCorruptedError(
                forKey: .state, in: container, debugDescription: "state 恒为 running,实际 \(rawState)")
        }
        state = rawState
        version = try container.decodeNonEmptyString(forKey: .version)
        networkProtocol = try container.decodeProtocolVersion(forKey: .networkProtocol)
        pid = try container.decodePositiveInt(forKey: .pid)
        startedAt = try container.decodeNonEmptyString(forKey: .startedAt)
        uptimeMs = try container.decodeNonNegativeInt(forKey: .uptimeMs)
        home = try container.decodeNonEmptyString(forKey: .home)
        socketPath = try container.decodeNonEmptyString(forKey: .socketPath)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(version, forKey: .version)
        try container.encode(networkProtocol, forKey: .networkProtocol)
        try container.encode(pid, forKey: .pid)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(uptimeMs, forKey: .uptimeMs)
        try container.encode(home, forKey: .home)
        try container.encode(socketPath, forKey: .socketPath)
    }
}

/// 「有人改了状态」事件的载荷(对照 `CapabilityEventSchema`)。
///
/// 它带着能力自己的 `output`,订阅者**直接投影**、不必回头再查一次 —— 那正是「零轮询」的实质。
/// `output` 是任意 JSON:各能力的 result 形状**有意不在镜像范围内**(见 `A2ContractMirror`)。
public struct A2CapabilityEvent: Sendable, Equatable {
    public let capability: String
    public let risk: A2RiskLevel
    public let output: A2JSON

    public init(capability: String, risk: A2RiskLevel, output: A2JSON) {
        self.capability = capability
        self.risk = risk
        self.output = output
    }
}

/// 「**能力全集变了**」事件的载荷(对照 `CapabilitySetEventSchema`,11 票)。
///
/// 与 `A2CapabilityEvent` 是两件事:那条说"有人改了状态",这条说"**能调的东西本身变了**"
/// (agent 现场装/卸了一个插件)。载荷里带**变化后的全集**,所以客户端拿到就整份替换 ——
/// 不必自己按 added/removed 做加减法(与 `arbitration` 事件"整份推"同一种处置)。
///
/// **壳(a2-panel)不会因此长出新菜单项**:菜单只投影 `proxy.*`(有断言钉着)。
/// 它镜像这条事件是为了**能把整帧解开**:未知 kind 会让 `A2KernelEvent` 解码失败、整帧被丢弃。
public struct A2CapabilitySetEvent: Sendable, Equatable {
    public let action: A2PluginAction
    public let plugin: String
    public let added: [A2CapabilityDescriptor]
    public let removed: [String]
    public let capabilities: [A2CapabilityDescriptor]

    public init(
        action: A2PluginAction, plugin: String, added: [A2CapabilityDescriptor],
        removed: [String], capabilities: [A2CapabilityDescriptor]
    ) {
        self.action = action
        self.plugin = plugin
        self.added = added
        self.removed = removed
        self.capabilities = capabilities
    }
}

/// 插件装载动作(对照 `PluginActionSchema`,**词表封闭**:未知取值必须解码失败,有 invalid 金标守着)。
public enum A2PluginAction: String, Sendable, Codable, Equatable, CaseIterable {
    /// 头一回装上。
    case added
    /// 同名再装 = 替换(工件换掉,插件名不变)。
    case replaced
    /// 卸掉:它的能力当场从注册表消失。
    case removed
}

extension A2CapabilitySetEvent: Codable {
    private enum CodingKeys: String, CodingKey { case action, plugin, added, removed, capabilities }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(A2PluginAction.self, forKey: .action)
        plugin = try container.decodeNonEmptyString(forKey: .plugin)
        // 三张表都**可以为空**(卸载时 added 为空、首装时 removed 为空),与契约的 `z.array(...)` 一致。
        added = try container.decode([A2CapabilityDescriptor].self, forKey: .added)
        // 元素带 min(1)、数组本身可空:头一回装插件时 removed 就是空的。
        removed = try container.decodeStringArrayWithNonEmptyElements(forKey: .removed)
        capabilities = try container.decode([A2CapabilityDescriptor].self, forKey: .capabilities)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encode(plugin, forKey: .plugin)
        try container.encode(added, forKey: .added)
        try container.encode(removed, forKey: .removed)
        try container.encode(capabilities, forKey: .capabilities)
    }
}

extension A2CapabilityEvent: Codable {
    private enum CodingKeys: String, CodingKey { case capability, risk, output }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capability = try container.decodeNonEmptyString(forKey: .capability)
        risk = try container.decode(A2RiskLevel.self, forKey: .risk)
        output = try container.decodeRequiredJSON(forKey: .output)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(capability, forKey: .capability)
        try container.encode(risk, forKey: .risk)
        try container.encode(output, forKey: .output)
    }
}
