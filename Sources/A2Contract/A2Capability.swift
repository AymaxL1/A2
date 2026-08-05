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

/// 能力 manifest(对照 `CapabilityDescriptorSchema`)。
public struct A2CapabilityDescriptor: Sendable, Equatable {
    public let id: String
    public let risk: A2RiskLevel
    public let summary: String
    public let parameters: [A2ParameterSpec]
    /// 域子命令写法(有序 token:`["proxy","on"]` ⇒ `a2 proxy on`);缺省 = 只能用 `capabilities call` 调。
    public let cliAlias: [String]?

    public init(
        id: String, risk: A2RiskLevel, summary: String, parameters: [A2ParameterSpec],
        cliAlias: [String]? = nil
    ) {
        self.id = id
        self.risk = risk
        self.summary = summary
        self.parameters = parameters
        self.cliAlias = cliAlias
    }
}

extension A2CapabilityDescriptor: Codable {
    private enum CodingKeys: String, CodingKey { case id, risk, summary, parameters, cliAlias }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeNonEmptyString(forKey: .id)
        risk = try container.decode(A2RiskLevel.self, forKey: .risk)
        summary = try container.decodeNonEmptyString(forKey: .summary)
        // 参数表**可以为空**(无参能力),与 `z.array(...)`(无 min)一致。
        parameters = try container.decode([A2ParameterSpec].self, forKey: .parameters)
        // 契约是 `z.array(z.string().min(1)).min(1).optional()` —— **元素也带 min(1)**,两级都要镜像。
        cliAlias = try container.decodeNonEmptyStringArrayIfPresent(forKey: .cliAlias)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(risk, forKey: .risk)
        try container.encode(summary, forKey: .summary)
        try container.encode(parameters, forKey: .parameters)
        try container.encodeIfPresent(cliAlias, forKey: .cliAlias)
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
