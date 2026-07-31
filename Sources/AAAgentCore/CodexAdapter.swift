// AAAgentCore —— Codex(`codex exec --json`)原生扁平 NDJSON 事件流 → 平台 6 型统一消息的归一化纯函数。
// 依赖边:AAAgentCore → AAContracts + 系统 Foundation(**不 import 任何 Host***)。
//   为何本文件 import Foundation(与 AgentMessage.swift / AgentPort.swift 不同):归一化的输入是 agent 吐出的
//   原生 JSON 行,必须用 `JSONDecoder` 解成 `AAContracts.JSONValue` 才能遍历。AAContracts 自身也 import Foundation,
//   故这条依赖不越界 —— 红线只针对 AAHostRuntime / AAHostMacOS / AAHostTestKit / AAPluginSDK / PluginProxy。
//
// 姿态:**纯函数、无副作用、不抛错、绝不崩**(同 ClaudeAdapter)。
//   agent 的 stdout 是不受我们控制的外部输入(版本升级会加新事件、进程被杀会截断行、非 JSON 噪声会混进来)。
//   全路径退化:解析失败 → `status="unparsed"`;未知顶层事件 → `status="unknown:<type>"`;
//   未知 item 类型 → `status="unknown-item:<type>"`。原始行截断进 `text` 保诊断能力(上限 `rawLineLimit`)。
//
// 依据(02 spike 实测样本 `.scratch/agent-delegation/research/spike-codex-exec/samples/exec*.stdout.jsonl`,非文档臆测):
//   * 顶层 `type` 实测只有 7 种:thread.started / turn.started / item.started / item.completed /
//     turn.completed / turn.failed,外加**非终态**的顶层 `error`。
//   * 载荷在 `item:{id, type, ...}`,`item.type` 实测有 command_execution / agent_message / error。
//   * `command_execution` 的 `item.started` 与 `item.completed` 用**同一个 `item.id`**(如 `item_1`)—— callID 的来源。
//   * `agent_message` **只出现在 `item.completed`**(无 started 半场);`error` 型 item 是 item 级警告(如 model 元数据缺失)。
//   * `turn.failed.error.message` 有两种形态:exec6 是**再序列化了一层的 JSON 串**,exec7 是**纯文本**
//     → 双层解码必须能优雅退化(见 `unwrapNestedErrorMessage`)。
//
// **与 Claude 侧的三处不对称(刻意如实保留,绝不为了对称而臆造)**:
//   ① **中断 / 超时时流里根本没有终态行**。exec5(进程组 SIGTERM,returncode=-15)只到 `turn.started` 就断;
//      exec3(4 条 `Reconnecting...` 后被 90s 硬超时 SIGTERM,returncode=-15)也没有任何终态行。
//      本 adapter 此时**诚实返回 `terminal == nil`** —— 绝不据 `error` 行、也绝不据「流结束了」臆造一个终态。
//      **终态由上层据进程退出码补**(负数=被信号杀 → aborted;spec 亦要求 job 层在发信号那刻就自标 aborted)。
//      这与 Claude 正相反:Claude 被中断也会补一条 `result` 终态行(`terminal_reason:"aborted_streaming"`)。
//      为什么不在这里「兜底造一个 failed」:归一化是**纯函数**,只看得见事件流这一份证据,看不见退出码;
//      在证据不足处编一个终态,会让上层无从区分「agent 说它失败了」与「adapter 猜的」——nil 才是如实的答案。
//   ② **被拒调用是「静默空气墙」**(02 spike 3/3 实证):被沙箱拦下的写操作**连 `item.started` 都不出现**,
//      不是「item 出现但标记 denied/failed」,而是这个 item 在流里完全不存在(exec3b 的强制写、exec4 的越界写皆然)。
//      故 Codex 侧**没有可编程识别的拒绝信号**,V1 **不合成** permission-denied 消息(Claude 侧有
//      `permission_denials[]` 故能如实产出)。要审计「拦截了什么」只能靠任务前后 diff 文件树(spec 已承认此不对称)。
//   ③ **没有终局答复字段**:Codex 的 `turn.completed` 只带 `usage`,原生没有 Claude `result.result` 那样的
//      「最终答复回显」→ 终态的 `finalText` **一律 nil**,04 票的报告兜底退回「取最后一条 `.text` 消息」。
//
// 另:stderr 的 `ERROR` 字样**不是**失败判据(02 spike:8/8 次调用连成功的那几次 stderr 也稳定打 ERROR,
//   是该 alpha 构建连 ChatGPT 私有后端的旁路依赖噪音)。本文件只吃 stdout 事件流,天然不受其影响 —— 记在此处
//   是为了让「别拿 stderr 判成败」这条结论有个落点,上层(04 票 job 层)据退出码 + 本文件的终态判定即可。

import Foundation
import AAContracts

/// Codex `exec --json` 扁平 NDJSON 的归一化器(无状态,故用 enum 作命名空间,不可实例化)。
public enum CodexAdapter {

    /// 不可解析 / 未知事件时,原始行进 `text` 的截断上限 —— 与 `ClaudeAdapter.rawLineLimit` 同口径(512)。
    /// (两处各自私有而非共享一个常量:它们是各自 adapter 的降级细节,不构成模块公共面;口径一致由本注释与门禁断言守。)
    private static let rawLineLimit = 512

    // MARK: - 公开入口

    /// 单行原始 NDJSON → 统一消息(纯函数,无副作用,**不抛错**)。
    public static func normalize(line: String) -> AgentAdapterOutput {
        // 空行 / 全空白行:NDJSON 尾行与心跳空写都常见 —— 无事发生,产 0 条消息(不是错误)。
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return AgentAdapterOutput() }

        // 解析失败:降级成一条可诊断的 status 消息,绝不抛、绝不崩(截断的原始行留在 text 里)。
        guard let data = trimmed.data(using: .utf8),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return AgentAdapterOutput(messages: [
                AgentMessage.status(.unparsed, detail: truncated(trimmed))
            ])
        }

        // `type` 缺失时用哨兵串占位(仍走「未知顶层事件」兜底路径,不特判、不崩)。
        let type = root.member("type")?.stringValue ?? missingSentinel
        switch type {
        case "thread.started":
            // 会话起始:thread_id 就是 session 指针(**流的第一行**直接给,不必等 rollout 文件落盘 —— 02 spike 实证)。
            return AgentAdapterOutput(
                messages: [AgentMessage.status(.sessionStarted)],
                sessionID: root.member("thread_id")?.stringValue
            )
        case "turn.started":
            return AgentAdapterOutput(messages: [AgentMessage.status(.turnStarted)])
        case "turn.completed":
            // 唯一的成功终态行。`usage` 只是 token 统计,不进统一模型(单家私有形状,排障去 logs/raw.ndjson)。
            return AgentAdapterOutput(
                messages: [AgentMessage.status(.turnCompleted)],
                terminal: AgentTerminalStatus(outcome: .succeeded, reason: "turn.completed", finalText: nil)
            )
        case "turn.failed":
            return normalizeTurnFailed(root, raw: trimmed)
        case "error":
            // **顶层 error 绝不产终态**:实测它多数是瞬态重连噪音(`Reconnecting... 2/5 (…)`,
            // 每个传输通道 5 次、WebSocket 试完再回退 HTTPS 又 5 次),重连成功后回合照样能 `turn.completed`。
            // 把它当失败会把「还在正常重试」误报成失败;真失败另有 `turn.failed` 行(且内容与最后一条 error 重复)。
            // message 缺失时退回截断原始行:错误消息宁可粗糙也不能空手(可诊断优先)。
            return AgentAdapterOutput(messages: [
                AgentMessage.error(root.member("message")?.stringValue ?? truncated(trimmed))
            ])
        case "item.started":
            return AgentAdapterOutput(messages: [normalizeItemStarted(root, raw: trimmed)])
        case "item.completed":
            return AgentAdapterOutput(messages: [normalizeItemCompleted(root, raw: trimmed)])
        default:
            // 未知顶层事件(如上游新增的 item 之外的事件类型)——记录不崩,原始行截断保真。
            return AgentAdapterOutput(messages: [
                AgentMessage(kind: .status, text: truncated(trimmed), status: "unknown:\(type)")
            ])
        }
    }

    /// 多行聚合(测试与上层消费用):按序归一化并合并 —— `terminal` 取**最后**一个非 nil,`sessionID` 取**第一个**非 nil。
    /// (口径与 ClaudeAdapter 逐字相同:终态取最后可容忍异常多终态行的情形以最终态为准;
    ///  sessionID 由 `thread.started` 确立,后续行不应改写它。
    ///  **注意**:全流跑完 `terminal` 仍为 nil 是 Codex 的**正常**情形之一(中断 / 硬超时),不是 bug,更不是「该兜底了」。)
    public static func normalize(lines: [String]) -> AgentAdapterOutput {
        var out = AgentAdapterOutput()
        for line in lines {
            let one = normalize(line: line)
            out.messages.append(contentsOf: one.messages)
            if let terminal = one.terminal { out.terminal = terminal }
            if out.sessionID == nil { out.sessionID = one.sessionID }
        }
        return out
    }

    // MARK: - 终态失败行

    /// `turn.failed`(唯一的失败终态行):理由取 `error.message` 的**双层解码**结果,并在消息流里也留一条 `.error`。
    ///
    /// 为什么消息流里也要留一条:终态是给判定用的(上层看 outcome),消息流是给人看的(报告/日志按序渲染)。
    /// 若只进终态,一份按序渲染的对话记录里就看不到「它是怎么死的」——而 Codex 的失败往往只有这一句话。
    ///
    /// **代价要如实说清(CR 纠正)**:这确实会产生重复。exec7 样本里最后一条顶层 `error` 与
    ///   `turn.failed.error.message` **逐字相同**,归一化后就是连着两条一模一样的 `.error`;exec6 也重复
    ///   (但两条形态不同:一条是原始双层串、一条是解出的内层人话)。仍这么做的理由是**诊断面要如实、
    ///   判定面才收敛**——adapter 是逐行无状态纯函数,要去重就得引入跨行状态,为了少印一行而破坏纯函数
    ///   不划算。**去重责任在渲染层(票 04 的报告面)**,不在这里。
    /// (Claude 侧刻意不留:它的 `result.result` 是最后一条 assistant text 的逐字回显,产成消息会让**每一次
    ///  正常成功**都打印两遍——那是常态而非失败时的边缘情形,故改由终态的 `finalText` 承载。)
    private static func normalizeTurnFailed(_ root: JSONValue, raw: String) -> AgentAdapterOutput {
        let native = root.member("error")?.member("message")?.stringValue
        let reason = native.map(unwrapNestedErrorMessage)
        // `error.message` 缺失时理由如实留 nil(不臆造),但消息流里仍留一条带截断原始行的 error(可诊断)。
        return AgentAdapterOutput(
            messages: [AgentMessage.error(reason ?? truncated(raw))],
            terminal: AgentTerminalStatus(outcome: .failed, reason: reason, finalText: nil)
        )
    }

    /// `turn.failed.error.message` 的**双层解码**(票面第 3 条:错因是双层编码 JSON,需 parse 两层)。
    ///
    /// 实测两种形态:
    ///  * exec6(invalid-model):值是把整段 API 错误 JSON **再序列化了一层**的字符串 ——
    ///    `"{\"type\":\"error\",\"status\":400,\"error\":{…,\"message\":\"The '…' model is not supported…\"}}"`,
    ///    直接展示给人看是一堆转义符,故解开取内层 `error.message` 那句人话;
    ///  * exec7(401 无鉴权):值就是**纯文本**(`unexpected status 401 Unauthorized: …`),根本不是 JSON。
    ///
    /// 故:解得开且里面真有 `error.message` 才用内层;**解不出 / 形状不符 / 内层为空一律原样退回**
    /// —— 绝不因为解不开就丢信息、更不抛错(错因文本是失败诊断的唯一线索,宁可粗糙也不能没有)。
    private static func unwrapNestedErrorMessage(_ message: String) -> String {
        guard let data = message.data(using: .utf8),
              let inner = try? JSONDecoder().decode(JSONValue.self, from: data),
              let text = inner.member("error")?.member("message")?.stringValue,
              !text.isEmpty else { return message }
        return text
    }

    // MARK: - item.* → 消息(载荷都在 `item`,started/completed 半场语义不同)

    /// `item.started`:实测只有 `command_execution` 会出这一半场(工具**开始**执行)。
    private static func normalizeItemStarted(_ root: JSONValue, raw: String) -> AgentMessage {
        guard let item = root.member("item") else { return malformedItem(raw) }
        let itemID = item.member("id")?.stringValue
        let itemType = item.member("type")?.stringValue ?? missingSentinel
        switch itemType {
        case "command_execution":
            return toolUseMessage(item, callID: itemID)
        default:
            // 未实测到的 started 半场形状(如上游给 agent_message 也补 started):保真上浮,不猜语义、不打崩。
            return AgentMessage(kind: .status, callID: itemID, status: "unknown-item:\(itemType)")
        }
    }

    /// `item.completed`:三种实测形状 —— 工具结果 / agent 发言 / item 级错误警告。
    private static func normalizeItemCompleted(_ root: JSONValue, raw: String) -> AgentMessage {
        guard let item = root.member("item") else { return malformedItem(raw) }
        let itemID = item.member("id")?.stringValue
        let itemType = item.member("type")?.stringValue ?? missingSentinel
        switch itemType {
        case "command_execution":
            return toolResultMessage(item, callID: itemID)
        case "agent_message":
            // agent 的发言(Codex 只在 completed 半场给,无流式增量)。
            return .text(item.member("text")?.stringValue ?? "")
        case "error":
            // item 级错误警告(实测:模型元数据缺失、WebSocket 降级 HTTPS)——是 agent 侧的错误播报,
            // 归一为 `.error` 消息;**同样绝不产终态**(exec7 里它在第 7 行出现,回合又跑了 7 行才 turn.failed)。
            return .error(item.member("message")?.stringValue ?? truncated(raw))
        default:
            return AgentMessage(kind: .status, callID: itemID, status: "unknown-item:\(itemType)")
        }
    }

    /// `command_execution` 的 started 半场 → tool-use 消息。
    ///
    /// 工具名恒为字面 `command_execution`:Codex 的 shell 调用**没有**独立的工具名字段(不像 Claude 的
    /// `tool_use.name` 有 Write/Read 之分),item 的 `type` 就是它的全部身份 —— 如实照搬,不自造更好听的名字。
    /// `command`(实测形如 `/bin/zsh -lc '…'`)作入参,包一层对象以便将来 Codex 加别的入参字段时不改形状。
    private static func toolUseMessage(_ item: JSONValue, callID: String?) -> AgentMessage {
        let input = item.member("command").map { JSONValue.object(["command": $0]) }
        if let callID = callID {
            return .toolUse(callID: callID, tool: commandExecutionTool, input: input)
        }
        // 畸形 item(缺 id):便利构造器要求非可选,这里退回全字段 init 让 callID **如实留 nil**
        // —— 绝不拿空串冒充 callID(那会让下游误以为配上了对)。
        return AgentMessage(kind: .toolUse, tool: commandExecutionTool, callID: nil, input: input)
    }

    /// `command_execution` 的 completed 半场 → tool-result 消息(callID 与 started 半场**同一个 `item.id`**)。
    ///
    /// `output` 只收 `aggregated_output` + `exit_code` 两个键:前者是工具的真实产出,后者是判定依据;
    /// `command` / `status` 不重复进 output(command 已在 tool-use 的 input 里,status 已收敛进 `isError`)。
    private static func toolResultMessage(_ item: JSONValue, callID: String?) -> AgentMessage {
        var fields: [String: JSONValue] = [:]
        if let aggregated = item.member("aggregated_output") { fields["aggregated_output"] = aggregated }
        if let exitCode = item.member("exit_code") { fields["exit_code"] = exitCode }
        let output: JSONValue? = fields.isEmpty ? nil : .object(fields)
        let isError = commandFailed(item)
        if let callID = callID {
            return .toolResult(callID: callID, output: output, isError: isError)
        }
        return AgentMessage(kind: .toolResult, callID: nil, output: output, isError: isError)
    }

    /// 一次 `command_execution` 算不算「错误结果」:`status == "failed"` **或** `exit_code != 0`。
    ///
    /// 两个判据都缺时返回 nil(**不补默认 false**):「没说」与「明确说不是错」是两件事,后者才是 false
    /// (与 ClaudeAdapter 处理缺失 `is_error` 的口径一致)。
    ///
    /// **工具失败 ≠ 回合失败**:exec2 里这条命令 `status:"failed"`、`exit_code:1`,而整个回合仍是 `turn.completed`
    /// (agent 把失败如实报告给用户就算完成了任务)。故本函数的产出只落在**单条消息的 `isError`**,
    /// 绝不参与终态判定 —— 终态只认 `turn.completed` / `turn.failed` 两种行。
    private static func commandFailed(_ item: JSONValue) -> Bool? {
        let status = item.member("status")?.stringValue
        let exitCode = item.member("exit_code")?.numberValue
        guard status != nil || exitCode != nil else { return nil }
        return status == "failed" || (exitCode != nil && exitCode != 0)
    }

    // MARK: - 小工具

    /// Codex shell 工具在统一模型里的工具名(见 `toolUseMessage` 的注释:Codex 没有独立工具名字段)。
    private static let commandExecutionTool = "command_execution"

    /// `type` / `item.type` 缺失时的哨兵串(让兜底路径的 status 串仍有意义,如 `unknown:(missing)`)。
    /// 与 `ClaudeAdapter.missingSentinel` 同口径。
    private static let missingSentinel = "(missing)"

    /// `item.*` 事件缺 `item` 载荷:走与「未知 item 类型」同一条兜底路,原始行截断保真。
    private static func malformedItem(_ raw: String) -> AgentMessage {
        AgentMessage(kind: .status, text: truncated(raw), status: "unknown-item:\(missingSentinel)")
    }

    /// 原始行截断到 `rawLineLimit`(保诊断能力,不让超长行撑爆日志)。
    private static func truncated(_ line: String) -> String {
        line.count <= rawLineLimit ? line : String(line.prefix(rawLineLimit))
    }
}

// JSONValue 的取值便利(`member` / `numberValue`)已上提为模块内共用,见 `JSONValueAccess.swift`
// —— 与 ClaudeAdapter 共用同一份 `member(_:)`,其「缺键与显式 null 一视同仁」的语义两家都依赖
//    (Claude 的 `api_error_status`、Codex 的 `item.started.exit_code` 都是显式 null),收敛一处防单边分叉。
