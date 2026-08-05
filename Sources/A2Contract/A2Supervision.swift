// A2Contract —— 存活监督面(对照 `wire.ts` 的 `ProxySupervisionEventSchema` / `ProxySupervisionResultSchema`)。
//
// 为什么在镜像范围内:`KernelSnapshot.supervision` 就是这份 result,而 `supervision` 是六族增量事件之一
// (「mihomo 死了」这条报警是壳要显示的东西)。07 票定的形状在 08 票**一字未改**,推送载荷 ≡ 查询载荷。

import Foundation

/// 实例归属(对照 `MihomoOwnerSchema`):`a2` = `com.a2.mihomo` 托管的那份;`foreign` = 别人的。
public enum A2MihomoOwner: String, Sendable, Codable, Equatable, CaseIterable {
    case a2
    case foreign
}

/// 「我这条命令是在跟谁说话」(对照 `ProxyEndpointSchema`)。
public struct A2ProxyEndpoint: Sendable, Equatable {
    public let owner: A2MihomoOwner
    /// external-controller 地址(恒为回环)。
    public let controller: String
    /// 这份归不归 a2 管(决定"换配置文件"类写面能不能发)。
    public let managed: Bool
    /// a2 自管那份的配置文件路径(收编档缺省 —— 那是别人的文件,内核不写)。
    public let configPath: String?

    public init(owner: A2MihomoOwner, controller: String, managed: Bool, configPath: String? = nil) {
        self.owner = owner
        self.controller = controller
        self.managed = managed
        self.configPath = configPath
    }
}

extension A2ProxyEndpoint: Codable {
    private enum CodingKeys: String, CodingKey { case owner, controller, managed, configPath }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owner = try container.decode(A2MihomoOwner.self, forKey: .owner)
        controller = try container.decodeNonEmptyString(forKey: .controller)
        managed = try container.decode(Bool.self, forKey: .managed)
        // 纯 `z.string().optional()`(没有 min(1)),照抄。
        configPath = try container.decodeIfPresent(String.self, forKey: .configPath)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(owner, forKey: .owner)
        try container.encode(controller, forKey: .controller)
        try container.encode(managed, forKey: .managed)
        try container.encodeIfPresent(configPath, forKey: .configPath)
    }
}

/// 一条存活观测事件的种类(对照 `ProxySupervisionEventSchema.kind`)。
public enum A2SupervisionEventKind: String, Sendable, Codable, Equatable, CaseIterable {
    /// daemon 起来了,开始盯着某个端点。
    case watchStarted = "watch_started"
    /// 之前不可达 → 现在可达。
    case instanceUp = "instance_up"
    /// 之前可达 → 现在不可达(**这就是报警**)。
    case instanceDown = "instance_down"
    /// 盯的对象换了。
    case targetChanged = "target_changed"
    /// daemon 要停了。
    case watchStopped = "watch_stopped"
}

/// 存活监督的一条观测事件(对照 `ProxySupervisionEventSchema`)。**内容即推送载荷**。
public struct A2ProxySupervisionEvent: Sendable, Equatable {
    public let at: String
    public let kind: A2SupervisionEventKind
    public let controller: String
    public let owner: A2MihomoOwner
    public let detail: String?
    /// `instance_down` 必带 —— 「人类如何完成」。
    public let guidance: A2Guidance?

    public init(
        at: String, kind: A2SupervisionEventKind, controller: String, owner: A2MihomoOwner,
        detail: String? = nil, guidance: A2Guidance? = nil
    ) {
        self.at = at
        self.kind = kind
        self.controller = controller
        self.owner = owner
        self.detail = detail
        self.guidance = guidance
    }
}

extension A2ProxySupervisionEvent: Codable {
    private enum CodingKeys: String, CodingKey { case at, kind, controller, owner, detail, guidance }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try container.decodeNonEmptyString(forKey: .at)
        kind = try container.decode(A2SupervisionEventKind.self, forKey: .kind)
        controller = try container.decodeNonEmptyString(forKey: .controller)
        owner = try container.decode(A2MihomoOwner.self, forKey: .owner)
        // 纯 `z.string().optional()`(没有 min(1)),照抄。
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        guidance = try container.decodeIfPresent(A2Guidance.self, forKey: .guidance)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(at, forKey: .at)
        try container.encode(kind, forKey: .kind)
        try container.encode(controller, forKey: .controller)
        try container.encode(owner, forKey: .owner)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(guidance, forKey: .guidance)
    }
}

/// `proxy.supervision.get` 的 output,同时是 `KernelSnapshot.supervision`(对照 `ProxySupervisionResultSchema`)。
public struct A2ProxySupervisionResult: Sendable, Equatable {
    /// daemon 里那条观测循环在不在跑。
    public let watching: Bool
    public let intervalMs: Int
    /// 起来之后一共探了多少次(证明它真在跑)。
    public let checks: Int
    public let target: A2ProxyEndpoint?
    public let alive: Bool?
    public let lastCheckAt: String?
    public let lastTransitionAt: String?
    /// 事件全量落这儿(NDJSON,一行一条)。
    public let logPath: String
    /// 最近若干条(新的在后)。
    public let events: [A2ProxySupervisionEvent]

    public init(
        watching: Bool, intervalMs: Int, checks: Int, target: A2ProxyEndpoint? = nil,
        alive: Bool? = nil, lastCheckAt: String? = nil, lastTransitionAt: String? = nil,
        logPath: String, events: [A2ProxySupervisionEvent]
    ) {
        self.watching = watching
        self.intervalMs = intervalMs
        self.checks = checks
        self.target = target
        self.alive = alive
        self.lastCheckAt = lastCheckAt
        self.lastTransitionAt = lastTransitionAt
        self.logPath = logPath
        self.events = events
    }
}

extension A2ProxySupervisionResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case watching, intervalMs, checks, target, alive, lastCheckAt, lastTransitionAt, logPath, events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        watching = try container.decode(Bool.self, forKey: .watching)
        intervalMs = try container.decodePositiveInt(forKey: .intervalMs)
        checks = try container.decodeNonNegativeInt(forKey: .checks)
        target = try container.decodeIfPresent(A2ProxyEndpoint.self, forKey: .target)
        alive = try container.decodeIfPresent(Bool.self, forKey: .alive)
        // 两个时刻字段同样是纯 `z.string().optional()`,照抄。
        lastCheckAt = try container.decodeIfPresent(String.self, forKey: .lastCheckAt)
        lastTransitionAt = try container.decodeIfPresent(String.self, forKey: .lastTransitionAt)
        logPath = try container.decodeNonEmptyString(forKey: .logPath)
        events = try container.decode([A2ProxySupervisionEvent].self, forKey: .events)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(watching, forKey: .watching)
        try container.encode(intervalMs, forKey: .intervalMs)
        try container.encode(checks, forKey: .checks)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encodeIfPresent(alive, forKey: .alive)
        try container.encodeIfPresent(lastCheckAt, forKey: .lastCheckAt)
        try container.encodeIfPresent(lastTransitionAt, forKey: .lastTransitionAt)
        try container.encode(logPath, forKey: .logPath)
        try container.encode(events, forKey: .events)
    }
}
