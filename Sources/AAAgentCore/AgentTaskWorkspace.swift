// AAAgentCore —— 任务工作区的**单写者**(03 票《任务工作区结构提案》§2/§3/§4/§6 的代码化)。
// 依赖边:本文件 → Foundation(JSONEncoder/JSONDecoder/Data)+ 本模块类型;绝不 import 任何 Host* / SDK / PluginProxy。
//
// 目录结构(提案「树形总览」,一字不改):
//   <root>/<task-id>/
//     ├── meta.json          唯一元数据真相源(**只有本类型能写**)
//     ├── prompt.md          委托原文 + 参数快照(审计与重跑依据)
//     ├── report.html        终态产物(agent 自产优先,缺失才兜底;见 AgentTaskReport)
//     ├── changes.md         有副作用任务的变更清单(纯只读任务缺省不产)
//     ├── logs/{raw.ndjson, normalized.ndjson, stderr.log}
//     └── work/              缺省 agent cwd(委托指定外部 workdir 时**不建**)
//
// 三条铁律(每条都有断言钉死,别当注释读):
//   1. **meta 单写者**:只有 `updateMeta` / `finish` 写 meta.json。非法状态迁移**抛错**,
//      且**在写盘之前**抛 —— 抛错时磁盘上的 meta.json 必须一个字节都没变(不静默改写)。
//   2. **raw 与 normalized 永不互写**:`appendRaw` 只碰 raw.ndjson,`appendNormalized` 只碰 normalized.ndjson。
//      raw 是「agent 说了什么」,normalized 是「平台听懂了什么」;两者互相污染就等于同时毁掉排障真相源
//      与状态判定输入。两条路各自独立,连共用的私有 append 助手都不设(共用助手是将来串档的入口)。
//   3. **prune 永不删 running/pending**:哪怕调用方点名要删也跳过,并**如实**在返回值里报出没删哪些。
//
// 关于 turn 边界(03 票 CR 回填的实测约束):`appendNormalized` **全量照收**,不按 turn 边界过滤。
//   Codex 的 `item.*` 事件不保证被 turn 包住(exec6 里 item error 在 `turn.started` 之前),
//   拿 turn 当闸门会把 pre-turn 的诊断信息直接丢掉。

import Foundation

/// 工作区写盘 / 读盘 / 生命周期维护中可能抛出的错误。
public enum AgentTaskWorkspaceError: Error, Equatable, Sendable {
    /// 非法状态迁移(含终态 → 任何状态)。抛出时 meta.json 未被写入。
    case illegalTransition(from: AgentTaskState, to: AgentTaskState)
    /// 终态元数据已冻结:任务已进终态,meta.json 不再接受任何写入(含原地重写)。
    case metaFrozen(state: AgentTaskState)
    /// `finish` 收到的不是终态。
    case notATerminalState(AgentTaskState)
    /// `task_id` 不可被 `updateMeta` 改(它就是目录名,改了等于凭空造出第二个真相)。
    case taskIDImmutable(expected: String, got: String)
    /// `schema_version` 不可被 `updateMeta` 改(版本迁移不是一次普通更新)。
    case schemaVersionImmutable(expected: Int, got: Int)
    /// 目标任务已存在(`create` 绝不覆盖既有工作区)。
    case taskAlreadyExists(String)
    /// `task_id` 形状非法:空串 / 含 `/` / 含 `..` / 以 `.` 开头。见 `AgentTaskWorkspace.requireValidTaskID`。
    case invalidTaskID(String)
    /// JSON 编解码失败(编码出的字节不是合法 UTF-8 等)。
    case codingFailed(String)
}

/// `prune` 的结果。**两个事实都要报**:删了哪些、以及**没删哪些**。
///
/// 为什么不是单个 `[String]`:票面同时要求「返回值如实」与「如实返回没删哪些」。
/// 一个数组只能承载其中一个事实 —— 调用方若只拿到 removed,就永远不知道有几个 running 被跳过了
/// (而那恰恰是用户点了「清理」却发现磁盘没瘦下来时最需要的解释)。
public struct AgentTaskPruneResult: Sendable, Equatable {
    /// 已删除的任务目录 id(全部是终态)。
    public let removed: [String]
    /// **点名要删但被跳过**的 id:running / pending(铁律 3),以及 meta 读不出的可疑目录(不销毁证据)。
    public let skipped: [String]

    public init(removed: [String], skipped: [String]) {
        self.removed = removed
        self.skipped = skipped
    }
}

/// 任务工作区(一个根目录下的全部委托任务)。所有副作用经 `AgentFileSystemPort` / `AgentClockPort`,
/// 故 04 全票的断言跑在假件上:零真实文件系统、零真实时钟。
public struct AgentTaskWorkspace: Sendable {
    /// 工作区根目录(生产值 = `AAContracts.AAPaths.agentTasksRoot`)。
    public let root: String
    private let fs: any AgentFileSystemPort
    private let clock: any AgentClockPort

    public init(root: String, fs: any AgentFileSystemPort, clock: any AgentClockPort) {
        self.root = root
        self.fs = fs
        self.clock = clock
    }

    // MARK: - task-id 形状校验(全部写/读入口的统一闸门)

    /// 校验 task-id 的形状,不合格即抛 `invalidTaskID`。**每一条带 taskID 的读写入口开头都过这道闸**。
    ///
    /// 为什么非有不可:`join` 与全部 `xxxPath(for:)` 都是**原样拼接**,而 07 票的 CLI 会把**用户敲进来的**
    ///   `<task-id>` 直接喂给 `readMeta` / `create`。生产端口是真 `FileManager`:一个 `../../x`
    ///   就能让 `create` 在 root **之外**建目录、写文件(`readMeta` 则能读到 root 之外的任意文件)。
    ///   这是路径穿越,不是「输入不规范」——故拦在域逻辑里,而不是指望每个调用方自己记得先洗一遍。
    ///
    /// 四条规则(合起来保证「id 只可能是 root 下的一个直接子目录名」):
    /// - **空串**:`join(root, "")` 会拼出 `root/`,等于把整个工作区根当成一个任务;
    /// - **含 `/`**:能拼出任意深的子路径(`a/b`),越出「目录名即 task-id」的一层扁平结构;
    /// - **含 `..`**:向上穿越的唯一原料(`..`、`../x`、`a/../../b` 全在此被拦下);
    /// - **以 `.` 开头**:`.` / `..` 自身,外加会被 `list()` 与 `ls` 藏起来的隐藏目录(建得出却看不见的任务是坏证据)。
    ///
    /// 合法字符集刻意**不**收得更窄(不限定只准 `[a-z0-9-]`):`AgentTaskID.make` 产的 id 天然合规,
    ///   而对手工建的旧目录过度收紧会让读操作反过来读不出**已经躺在磁盘上**的证据。
    static func requireValidTaskID(_ taskID: String) throws {
        if taskID.isEmpty || taskID.contains("/") || taskID.contains("..") || taskID.hasPrefix(".") {
            throw AgentTaskWorkspaceError.invalidTaskID(taskID)
        }
    }

    // MARK: - 路径(提案「树形总览」的唯一出处;上层不得各拼各的)

    /// 拼路径:去掉 base 末尾多余的 `/` 再接一段。
    static func join(_ base: String, _ component: String) -> String {
        var b = base
        while b.count > 1 && b.hasSuffix("/") { b.removeLast() }
        return b + "/" + component
    }

    /// 任务目录(目录名即 task-id)。
    public func directory(for taskID: String) -> String { Self.join(root, taskID) }
    /// `meta.json`。
    public func metaPath(for taskID: String) -> String { Self.join(directory(for: taskID), "meta.json") }
    /// `prompt.md`。
    public func promptPath(for taskID: String) -> String { Self.join(directory(for: taskID), "prompt.md") }
    /// `report.html`。
    public func reportPath(for taskID: String) -> String { Self.join(directory(for: taskID), "report.html") }
    /// `changes.md`(有副作用任务)。
    public func changesPath(for taskID: String) -> String { Self.join(directory(for: taskID), "changes.md") }
    /// `logs/` 目录。
    public func logsDirectory(for taskID: String) -> String { Self.join(directory(for: taskID), "logs") }
    /// `logs/raw.ndjson` —— agent 原话,排障真相源。
    public func rawLogPath(for taskID: String) -> String { Self.join(logsDirectory(for: taskID), "raw.ndjson") }
    /// `logs/normalized.ndjson` —— 6 型统一消息流,状态与报告的唯一输入。
    public func normalizedLogPath(for taskID: String) -> String { Self.join(logsDirectory(for: taskID), "normalized.ndjson") }
    /// `logs/stderr.log` —— 子进程 stderr 原样。
    public func stderrLogPath(for taskID: String) -> String { Self.join(logsDirectory(for: taskID), "stderr.log") }
    /// 缺省 agent cwd `work/`(委托指定外部 workdir 时不建、也不用)。
    public func defaultWorkPath(for taskID: String) -> String { Self.join(directory(for: taskID), "work") }

    // MARK: - 创建

    /// 建一个任务工作区,落 `meta.json`(state=pending)+ `prompt.md` + 三个空日志文件,返回刚写下的 meta。
    ///
    /// - `promptSnapshot`:委托参数快照(agent / model / 超时 / 沙箱姿态等),按键名排序写进 `prompt.md`,
    ///   供审计与重跑。空字典时如实写「无额外参数」。
    /// - `workdir`:nil = 用缺省的 `work/`(本函数建之);非 nil = 委托指定的外部目录,此时**不建** `work/`(提案 §2)。
    ///
    /// 三个日志文件在 create 时就建成空文件(提案里它们是「启动即有」):这样 `tail -f logs/raw.ndjson`
    /// 从任务一出现就能盯,不必等拉起;目录结构也自 create 起就是完整的那一棵树。
    ///
    /// 已存在同名任务时抛 `taskAlreadyExists` —— create 绝不覆盖既有工作区(那会一次性毁掉别人的全部证据)。
    /// 存在性判据是**任务目录本身**、不是 `meta.json`:「目录建好了、meta 还没写就崩了」留下的半截目录
    ///   若只看 meta.json 就会被判为「不存在」而被静默复用覆盖 —— 那半截目录里可能已经有 `logs/raw.ndjson`,
    ///   而它恰恰是排查上一次崩溃的唯一线索。
    @discardableResult
    public func create(
        taskID: String,
        prompt: String,
        promptSnapshot: [String: String] = [:],
        agent: String,
        model: String? = nil,
        workdir: String? = nil,
        initiator: String
    ) throws -> AgentTaskMeta {
        try Self.requireValidTaskID(taskID)
        let dir = directory(for: taskID)
        // 先查目录本身(半截目录也算「已存在」),再查 meta.json —— 两道都不放水。
        if fs.exists(at: dir) || fs.exists(at: metaPath(for: taskID)) {
            throw AgentTaskWorkspaceError.taskAlreadyExists(taskID)
        }

        let now = clock.now()
        try fs.createDirectory(at: dir)
        try fs.createDirectory(at: logsDirectory(for: taskID))

        let resolvedWorkdir: String
        if let external = workdir {
            resolvedWorkdir = external          // 外部 workdir:不建 work/(提案 §2)
        } else {
            resolvedWorkdir = defaultWorkPath(for: taskID)
            try fs.createDirectory(at: resolvedWorkdir)
        }

        // 三个日志文件先建成空的(见上文「启动即有」)。
        try fs.write("", to: rawLogPath(for: taskID))
        try fs.write("", to: normalizedLogPath(for: taskID))
        try fs.write("", to: stderrLogPath(for: taskID))

        let meta = AgentTaskMeta(
            taskID: taskID,
            state: .pending,
            agent: agent,
            model: model,
            workdir: resolvedWorkdir,
            initiator: initiator,
            createdAt: now.iso8601
        )
        try fs.write(
            Self.renderPromptSnapshot(meta: meta, prompt: prompt, parameters: promptSnapshot),
            to: promptPath(for: taskID)
        )
        try fs.write(try Self.encodeMeta(meta), to: metaPath(for: taskID))
        return meta
    }

    /// `prompt.md` 的正文(人可读、可复制重跑)。prompt 原文**原样**落盘,不转义、不裁剪。
    static func renderPromptSnapshot(meta: AgentTaskMeta, prompt: String, parameters: [String: String]) -> String {
        var out = """
        # 委托快照

        - task-id: \(meta.taskID)
        - agent: \(meta.agent)
        - model: \(meta.model ?? "(未指定)")
        - workdir: \(meta.workdir)
        - initiator: \(meta.initiator)
        - created-at: \(meta.createdAt)

        ## Prompt

        \(prompt)

        ## 委托参数

        """
        if parameters.isEmpty {
            out += "(无额外参数)\n"
        } else {
            for key in parameters.keys.sorted() {   // 排序:同一份委托每次落盘逐字节一致,便于 diff 与断言
                out += "- \(key): \(parameters[key] ?? "")\n"
            }
        }
        return out
    }

    // MARK: - 追加落盘(铁律 2:两条路各自独立,永不互写)

    /// 追加一行 **agent 原始事件**到 `logs/raw.ndjson`。全量落盘、永不裁剪(排障真相源)。
    /// 本方法**只碰 raw.ndjson**。
    public func appendRaw(_ line: String, taskID: String) throws {
        try Self.requireValidTaskID(taskID)
        try fs.append(Self.singleLine(line), to: rawLogPath(for: taskID))
    }

    /// 追加一条 **归一化 6 型消息**到 `logs/normalized.ndjson`(逐行 JSON)。
    /// 本方法**只碰 normalized.ndjson**。
    ///
    /// 全量照收:不按 turn 边界过滤(Codex 的 item 事件不保证被 turn 包住,拿 turn 当闸门会丢诊断信息)。
    public func appendNormalized(_ message: AgentMessage, taskID: String) throws {
        try Self.requireValidTaskID(taskID)
        try fs.append(try Self.encodeMessageLine(message), to: normalizedLogPath(for: taskID))
    }

    /// 追加一行子进程 stderr 到 `logs/stderr.log`(原样)。
    public func appendStderr(_ line: String, taskID: String) throws {
        try Self.requireValidTaskID(taskID)
        try fs.append(Self.singleLine(line), to: stderrLogPath(for: taskID))
    }

    /// 写 `changes.md`(有副作用任务的变更清单:改了什么、为什么、怎么回滚)。覆盖写;纯只读任务不调用即不产该文件。
    public func writeChanges(_ markdown: String, taskID: String) throws {
        try Self.requireValidTaskID(taskID)
        try fs.write(markdown, to: changesPath(for: taskID))
    }

    /// 把一行文本压成**单行**(ndjson 的每行必须是一条记录)。只剥换行,不裁剪内容长度 —— raw 永不裁剪。
    static func singleLine(_ line: String) -> String {
        line.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    // MARK: - meta 读写(铁律 1:唯一写者)

    /// 读 `meta.json`。解不出(文件损坏 / 未知 state 值)时如实抛;taskID 形状非法时**先**抛(路径穿越拦在读之前)。
    public func readMeta(taskID: String) throws -> AgentTaskMeta {
        try Self.requireValidTaskID(taskID)
        let text = try fs.read(at: metaPath(for: taskID))
        guard let data = text.data(using: .utf8) else {
            throw AgentTaskWorkspaceError.codingFailed("meta.json 不是合法 UTF-8:\(taskID)")
        }
        return try JSONDecoder().decode(AgentTaskMeta.self, from: data)
    }

    /// 更新 `meta.json` —— 与 `finish` 并列的**仅有两条**写 meta 的路。
    ///
    /// 先读回当前 meta,交给 `mutate` 改,然后**在写盘之前**校验三条不变量:
    /// - 任务已在终态 → 抛 `metaFrozen`,**一个字节都不写**(终态元数据冻结;「终态→自身」也在此被拦下);
    /// - `state` 真的变了但迁移非法 → 抛 `illegalTransition`,同样不写;
    /// - `task_id` / `schema_version` 被改 → 抛,不写。
    ///
    /// 「先校验后写盘」的次序是承重的:非法迁移必须**抛错且磁盘内容不变**,而不是「抛错但已经改了一半」。
    public func updateMeta(taskID: String, _ mutate: (inout AgentTaskMeta) -> Void) throws {
        let current = try readMeta(taskID: taskID)   // 形状校验在此(readMeta 开头)一并完成
        var next = current
        mutate(&next)

        if next.state != current.state {
            // 状态真的变了 → 必须是合法迁移(终态 → 任何状态在此被 `canTransition` 一并拦下)。
            guard current.canTransitionCheck(to: next.state) else {
                throw AgentTaskWorkspaceError.illegalTransition(from: current.state, to: next.state)
            }
        } else if current.state.isTerminal {
            // 状态没变但任务已终结 → meta 冻结。「终态 → 自身」这条(以及终态后补写 error 之类)在此被拦下:
            // 终态是一次性的,写定即封存;还想改说明调用方的状态没理清,与其容忍不如让它响。
            throw AgentTaskWorkspaceError.metaFrozen(state: current.state)
        }
        if next.taskID != current.taskID {
            throw AgentTaskWorkspaceError.taskIDImmutable(expected: current.taskID, got: next.taskID)
        }
        if next.schemaVersion != current.schemaVersion {
            throw AgentTaskWorkspaceError.schemaVersionImmutable(expected: current.schemaVersion, got: next.schemaVersion)
        }
        try fs.write(try Self.encodeMeta(next), to: metaPath(for: taskID))
    }

    /// 收尾:把任务迁进终态、记 `finished_at` / `exit_code` / `error`,并保证有一份 `report.html`。
    ///
    /// 次序也是承重的:**先**写 meta(非法迁移在这里就抛掉了)**再**碰报告 ——
    /// 否则一次非法的 finish 也会在磁盘上留下一份报告,读的人会以为任务真结束了。
    ///
    /// 报告遵循提案 §6:已有 agent 自产的 `report.html` → **原样保留,绝不覆盖**;没有才用最终文本兜底生成。
    ///
    /// - `error`:失败理由(调用方一般传 `AgentTerminalStatus.reason`)。**与 state / finished_at / exit_code
    ///   一次写盘**:若靠终态前额外来一次 `updateMeta` 写它,就是两次写盘,中间崩溃会在磁盘上留下
    ///   「error 已填但 state 还是 running」的半截现场(而且终态后 meta 冻结,那时再补写只会抛)。
    ///
    /// **同态幂等**(`state` 与磁盘上现有终态相同、且 `finished_at` 已有)→ **跳过 meta 写入**、只补报告:
    ///   1. 上面 `orphaned → 证据终态` 的放行让「扫描先标了孤儿、run 进程随后 finish」能纠正过来,
    ///      但 run 进程若**重试同一次 finish**(或两条路都收到了同一个终态),第二次不该被 `metaFrozen` 打回;
    ///   2. 更要紧的是**自愈**:上一次 meta 写成功但报告写失败(或写报告前进程崩了)时,
    ///      重调同值 finish 能把报告补出来 —— 否则那个任务永远是「终态已定、报告缺失」且无路可修。
    ///   状态**真的要变**时一律走严格路径,`updateMeta` 的冻结逻辑一字不动。
    public func finish(
        taskID: String,
        state: AgentTaskState,
        exitCode: Int32?,
        finalText: String?,
        error: String? = nil
    ) throws {
        guard state.isTerminal else { throw AgentTaskWorkspaceError.notATerminalState(state) }
        try Self.requireValidTaskID(taskID)
        let now = clock.now()   // 只取一次:finished_at 与报告页脚用同一时刻,不制造两个「现在」
        let current = try readMeta(taskID: taskID)

        // 同态幂等:同一个终态、且上次确实收过尾 → 不碰 meta(故不会撞 metaFrozen),直落下面的报告兜底。
        let isSameTerminalRepeat = (current.state == state && current.finishedAt != nil)
        if !isSameTerminalRepeat {
            try updateMeta(taskID: taskID) { meta in
                meta.state = state
                meta.finishedAt = now.iso8601
                meta.exitCode = exitCode
                meta.error = error
            }
        }

        if !fs.exists(at: reportPath(for: taskID)) {
            let html = AgentTaskReport.fallbackHTML(
                taskID: taskID,
                state: state,
                finalText: finalText ?? lastNormalizedText(taskID: taskID),
                generatedAt: now.iso8601
            )
            try fs.write(html, to: reportPath(for: taskID))
        }
    }

    /// 兜底报告的第二来源:`logs/normalized.ndjson` 里**最后一条** `.text` 消息的文本(没有则 nil)。
    ///
    /// 为什么非有不可:`AgentTerminalStatus.finalText` 只有 Claude 侧填得出(`result.result`);
    ///   Codex 的 `turn.completed` 原生**没有**终局答复字段,终态 `finalText` **恒为 nil**
    ///   (见 `AgentTerminalStatus` 与 `CodexAdapter` 文件头,两处都写明「04 退回取最后一条 text 消息」)。
    ///   缺了这条路,一个成功的 Codex 任务只要没自产 report.html,兜底报告就会写「没有留下最终文本」——
    ///   而答案就逐字躺在 normalized.ndjson 的最后一条 text 里。
    ///
    /// 只读 **normalized**、绝不读 raw:提案 §2 的红线是「一切下游只准消费 normalized,排障才碰 raw」,
    ///   报告是下游中的下游。取**最后**一条而非第一条:后面的 text 是对前面的收敛(过程 → 结论)。
    ///
    /// 尽力而为、**绝不抛**:文件不存在 / 读失败 / 全是坏行 / 一条 text 都没有 → 如实回 nil,
    ///   由 `AgentTaskReport` 如实写「没有留下最终文本」。报告兜底本就是尽力而为的一环,
    ///   不该因为日志读不动就把一次已经成功的 `finish` 掀翻(meta 那半已经写定了)。
    func lastNormalizedText(taskID: String) -> String? {
        guard let content = try? fs.read(at: normalizedLogPath(for: taskID)) else { return nil }
        var found: String?
        for line in content.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let message = try? JSONDecoder().decode(AgentMessage.self, from: data),
                  message.kind == .text,
                  let text = message.text else { continue }   // 坏行 / 非 text 型一律跳过,不中断扫描
            found = text
        }
        return found
    }

    // MARK: - 列举 / 残留扫描 / prune(提案 §4)

    /// 列出全部任务 id(即目录名),已排序。
    ///
    /// 只把**含 `meta.json`** 的条目当任务:`.DS_Store` 之类杂物、以及正在被别的进程创建到一半的目录
    /// 都不该出现在 `aa agent list` 里。根目录还不存在时如实返回空表(不抛:一次都没委托过不是错误)。
    ///
    /// **已知限制(如实记下,不假装没有)**:缺 `meta.json` 的半截目录对 `list` / `prune` / `scanForOrphans`
    ///   **一律不可见** —— 既不会被列出,也因此永远不会被 prune 自动清掉,只能人工删。
    ///   这是刻意的取舍:它们的 `logs/` 里可能正躺着上一次崩溃的唯一线索,**证据不销毁优先于自动清理**。
    ///   (同名 `create` 会因目录已存在而抛 `taskAlreadyExists`,故半截目录也不会被静默复用覆盖。)
    public func list() throws -> [String] {
        guard fs.exists(at: root) else { return [] }
        return try fs.listDirectory(at: root)
            .filter { fs.exists(at: metaPath(for: $0)) }
            .sorted()
    }

    /// 扫描崩溃残留:`state == running` 且 pid 已死 → 标 `orphaned`。返回被标记的 id(已排序)。
    ///
    /// **不销毁证据**(提案 §4 的原话「其余文件原样保留」):本函数**只**改 meta.json 的 `state`,
    ///   连 `finished_at` 都不填 —— 我们并不知道它是何时死的,凭空写一个时间戳就是伪造证据。
    ///   `logs/` 下的三个文件、`prompt.md`、`report.html` 一律不碰。
    ///
    /// 两处刻意的克制:
    /// - `state == running` 但 `pid` 为 nil(拉起与落 pid 之间宿主就崩了)→ **不标**。没有判据就不判,
    ///   留给人去看 `logs/raw.ndjson`;凭「没记 pid」就断言它死了是猜。
    /// - meta 解不出的目录 → 跳过,绝不删、绝不改。
    public func scanForOrphans(liveness: any AgentProcessLivenessPort) throws -> [String] {
        var marked: [String] = []
        for taskID in try list() {
            guard let meta = try? readMeta(taskID: taskID) else { continue }
            guard meta.state == .running, let pid = meta.pid else { continue }
            if liveness.isAlive(pid: pid) { continue }
            try updateMeta(taskID: taskID) { $0.state = .orphaned }
            marked.append(taskID)
        }
        return marked
    }

    /// 手动清理(提案 §4:V1 手动 prune)。删除**不在** `keepIDs` 里的任务目录。
    ///
    /// **永不删 running / pending**:哪怕它不在 `keepIDs` 里(即调用方点名要删),也跳过,
    ///   并把它列进 `skipped` 如实报出。理由很直白:那些目录背后可能还有个活着的进程在往里写,
    ///   删掉等于一边写一边抽地板;更别说用户按时间批量清理时根本没意识到有个跑了两小时的任务在里面。
    ///
    /// meta 读不出的目录同样跳过(fail-closed:看不懂就不动它,证据不销毁)。
    public func prune(keepIDs: Set<String>) throws -> AgentTaskPruneResult {
        var removed: [String] = []
        var skipped: [String] = []
        for taskID in try list() {
            if keepIDs.contains(taskID) { continue }        // 点名保留:本就不该删,不计入 skipped
            guard let meta = try? readMeta(taskID: taskID) else { skipped.append(taskID); continue }
            guard meta.state.isTerminal else { skipped.append(taskID); continue }  // ← 铁律 3
            try fs.removeDirectory(at: directory(for: taskID))
            removed.append(taskID)
        }
        return AgentTaskPruneResult(removed: removed, skipped: skipped)
    }

    // MARK: - 编码助手

    /// meta.json 的编码:pretty + 键排序 + 不转义斜杠 —— 磁盘上这份是给人和 `jq` 看的。
    static func encodeMeta(_ meta: AgentTaskMeta) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(meta)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentTaskWorkspaceError.codingFailed("meta.json 编码结果不是合法 UTF-8")
        }
        return text
    }

    /// normalized.ndjson 的一行:**紧凑单行**(ndjson 每行一条记录,不能 pretty)。
    static func encodeMessageLine(_ message: AgentMessage) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgentTaskWorkspaceError.codingFailed("normalized 消息编码结果不是合法 UTF-8")
        }
        return text
    }
}

extension AgentTaskMeta {
    /// 转发到状态机的迁移判定(让 `updateMeta` 读起来是「这份 meta 能不能迁过去」)。
    func canTransitionCheck(to next: AgentTaskState) -> Bool { state.canTransition(to: next) }
}
