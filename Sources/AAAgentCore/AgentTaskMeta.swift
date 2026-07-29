// AAAgentCore —— `meta.json` 的强类型承载(任务元数据的**唯一真相源**)。
// 依赖边:AAAgentCore → AAContracts(为 `JSONValue`:承载未知字段的保留区;见下 `extras`)。绝不 import 任何 Host* / SDK / PluginProxy。
//
// 字段严格照 03 票《任务工作区结构提案》§3 的 schema(不自由发挥):
//   schema_version / task_id / state / agent / model / workdir / initiator /
//   created_at / started_at / finished_at / pid / exit_code / session_id / error
//
// Codable 约定(与 `AgentMessage` 同款**手写** CodingKeys + encode/init):
//   * 键名走 snake_case —— 磁盘格式是给人和 `jq` 看的,不是 Swift 的私事;
//   * 可选字段一律 `encodeIfPresent`,nil 时**整键省略**(不产 `"model":null`),
//     与 `AAContracts.WireResponse` / `AgentMessage` 一致;
//   * 读侧一律 `decodeIfPresent` —— **必须容忍未知字段**(提案「演进规则」:字段只增不改义、
//     旧任务目录**永不迁移**、读侧向后兼容)。KeyedDecodingContainer 天然忽略未声明的键,
//     本类型不做任何 `allKeys` 校验,故一份多了 `"future_key":1` 的 meta.json 照样解得出。
//   * **未知字段还必须被写回去**(见 `extras`):只「读得出」不算兼容 —— `updateMeta` 是读-改-写,
//     若未知键在写回时被静默剥掉,新版本刚写下的 `retry_count` 会被旧版本的一次 `session_id` 更新抹掉,
//     那是**旧写侧单方面毁掉新版本的数据**,与「只增不改义」的承诺正相反。
//
// 一处**刻意的严格**:`state` 仍按枚举严格解码,未知状态值直接抛。理由是演进规则担保的是「字段只增」,
//   并没有担保「状态值只增」;真碰上不认识的状态,与其猜一个(猜成活态可能重复拉起、猜成终态可能吞掉证据),
//   不如让读操作显式失败——`scanForOrphans` / `prune` 会把解不出的目录**跳过而非删除**,证据不销毁。
// 同理 `initiator` 保持 String 而不枚举化:提案只说「预留 cli/gui/plugin」,将来多一种来源不该让旧读侧抛错。

import AAContracts

/// 一个委托任务的元数据(即磁盘上的 `meta.json`)。**单写者**:只有 `AgentTaskWorkspace` 能写它。
public struct AgentTaskMeta: Codable, Sendable, Equatable {
    /// 当前 schema 版本。顶层递增(提案「演进规则」);写侧恒写这个值。
    public static let currentSchemaVersion = 1

    /// schema 版本号。
    public var schemaVersion: Int
    /// 任务 id —— **同时就是目录名**(提案 §1:对外唯一标识,零查表)。
    public var taskID: String
    /// job 级状态(七值,见 `AgentTaskState`)。
    public var state: AgentTaskState
    /// agent 名(`claude` / `codex`)。
    public var agent: String
    /// 模型名;未指定为 nil(nil 时整键省略)。
    public var model: String?
    /// agent 的工作目录:缺省是任务目录下的 `work/`,委托指定外部目录时即该目录。
    public var workdir: String
    /// 委托发起方,提案 §3 预留 `cli` / `gui` / `plugin`。
    public var initiator: String
    /// 创建时刻(ISO8601,经 `AgentClockPort`)。
    public var createdAt: String
    /// 拉起成功时刻;尚未拉起为 nil。
    public var startedAt: String?
    /// 进入终态的时刻;未终结为 nil。**残留扫描不填它**(见 `scanForOrphans`:不知道它何时死的,不臆造时间戳)。
    public var finishedAt: String?
    /// agent 子进程 pid —— 崩溃残留判定的唯一依据(宿主重启后句柄没了,只剩这个)。
    public var pid: Int32?
    /// 子进程退出码;未退出为 nil。
    public var exitCode: Int32?
    /// agent 会话标识(Claude `session_id` / Codex `thread_id`)——**拿到即写**(提案 §3,为将来 resume 留门)。
    public var sessionID: String?
    /// 失败理由(原生串保真);无错为 nil。
    public var error: String?

    /// **未知字段保留区**:读进来的 meta.json 里本版本不认识的顶层键,原样存着、`encode` 时原样写回。
    ///
    /// 私有是刻意的:它不是给调用方读写的字段,而是「读-改-写不丢别人的数据」这条兼容义务的实现细节。
    /// 参与 `Equatable`(round-trip 全等的含义就该包含它:少写回一个未知键就不是同一份 meta)。
    private var extras: [String: JSONValue]

    public init(
        schemaVersion: Int = AgentTaskMeta.currentSchemaVersion,
        taskID: String,
        state: AgentTaskState,
        agent: String,
        model: String? = nil,
        workdir: String,
        initiator: String,
        createdAt: String,
        startedAt: String? = nil,
        finishedAt: String? = nil,
        pid: Int32? = nil,
        exitCode: Int32? = nil,
        sessionID: String? = nil,
        error: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.state = state
        self.agent = agent
        self.model = model
        self.workdir = workdir
        self.initiator = initiator
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.pid = pid
        self.exitCode = exitCode
        self.sessionID = sessionID
        self.error = error
        self.extras = [:]   // 本版本自己造的 meta 没有未知字段;只有从磁盘解出来的才可能有。
    }

    // —— 手写 Codable:snake_case 键名 + nil 键省略(与 AgentMessage 同款约定)——

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case taskID = "task_id"
        case state
        case agent
        case model
        case workdir
        case initiator
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case pid
        case exitCode = "exit_code"
        case sessionID = "session_id"
        case error
    }

    /// 任意字符串键(只为遍历 / 写回**未知**顶层键;`CodingKeys` 是闭集,`allKeys` 永远看不见未知键)。
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue s: String) { stringValue = s }
        init?(intValue: Int) { nil }
    }

    /// 本版本认识的全部顶层键(判断「什么算未知」的唯一出处;加字段时这里天然跟着 `CodingKeys` 走)。
    private static let knownKeys: Set<String> = Set(
        [CodingKeys.schemaVersion, .taskID, .state, .agent, .model, .workdir, .initiator,
         .createdAt, .startedAt, .finishedAt, .pid, .exitCode, .sessionID, .error].map(\.stringValue)
    )

    public func encode(to encoder: Encoder) throws {
        // **先**写未知字段,已知字段随后写 —— 同名时已知键覆盖之(已知键优先:未来的键绝不能改写本版本的语义)。
        // 两次 `container(keyedBy:)` 落在同一个底层对象上(JSONEncoder 的既定行为),故这是一次编码、不是两份。
        if !extras.isEmpty {
            var raw = encoder.container(keyedBy: AnyKey.self)
            for key in extras.keys.sorted() {           // 排序:同一份 meta 每次落盘逐字节一致
                try raw.encode(extras[key]!, forKey: AnyKey(key))
            }
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        // 七个必填键恒被编码(schema_version/task_id/state/agent/workdir/initiator/created_at;缺了就不是一份可用的 meta)。
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(taskID, forKey: .taskID)
        try c.encode(state, forKey: .state)
        try c.encode(agent, forKey: .agent)
        try c.encode(workdir, forKey: .workdir)
        try c.encode(initiator, forKey: .initiator)
        try c.encode(createdAt, forKey: .createdAt)
        // 其余一律 encodeIfPresent:nil 时整键省略,磁盘上不出现 "model":null 这种噪音。
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try c.encodeIfPresent(pid, forKey: .pid)
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
        try c.encodeIfPresent(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(error, forKey: .error)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // schema_version 用 decodeIfPresent + 默认值:V0 时代若真有一份没写版本号的旧目录,也读得出来
        //   (提案:旧任务目录**永不迁移**,读侧负责向后兼容)。
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? AgentTaskMeta.currentSchemaVersion
        self.taskID = try c.decode(String.self, forKey: .taskID)
        self.state = try c.decode(AgentTaskState.self, forKey: .state)
        self.agent = try c.decode(String.self, forKey: .agent)
        self.workdir = try c.decode(String.self, forKey: .workdir)
        self.initiator = try c.decode(String.self, forKey: .initiator)
        self.createdAt = try c.decode(String.self, forKey: .createdAt)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        self.finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt)
        self.pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        self.exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        self.sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        self.error = try c.decodeIfPresent(String.self, forKey: .error)

        // 刻意**不**校验 allKeys:未知键一律不打崩读侧(演进规则的读侧兼容义务)——
        // 但也**不丢**:整份对象再解一遍、去掉全部已知键,剩下的原样存进 `extras`,写回时一字不少。
        // 解不动的未知值(理论上不该出现:JSONValue 覆盖全部 JSON 型)会让整次读失败,与「meta 损坏就如实抛」一致。
        let raw = try decoder.container(keyedBy: AnyKey.self)
        var unknown: [String: JSONValue] = [:]
        for key in raw.allKeys where !Self.knownKeys.contains(key.stringValue) {
            unknown[key.stringValue] = try raw.decode(JSONValue.self, forKey: key)
        }
        self.extras = unknown
    }
}
