// AAAgentCore —— Claude Code headless(`--output-format stream-json`)原生事件流 → 平台 6 型统一消息的归一化纯函数。
// 依赖边:AAAgentCore → AAContracts + 系统 Foundation(**不 import 任何 Host***)。
//   为何本文件 import Foundation(与 AgentMessage.swift / AgentPort.swift 不同):归一化的输入是 agent 吐出的
//   原生 JSON 行,必须用 `JSONDecoder` 解成 `AAContracts.JSONValue` 才能遍历。AAContracts 自身也 import Foundation,
//   故这条依赖不越界 —— 红线只针对 AAHostRuntime / AAHostMacOS / AAHostTestKit / AAPluginSDK / PluginProxy。
//
// 姿态:**纯函数、无副作用、不抛错、绝不崩**。
//   agent 的 stdout 是不受我们控制的外部输入(版本升级会加新事件、进程被杀会截断行、非 JSON 噪声会混进来)。
//   任何「解析不了就抛/崩」的写法都会把一次可诊断的降级变成宿主故障,故这里全路径退化:
//   解析失败 → `status="unparsed"`;未知顶层事件 → `status="unknown:<type>"`;未知子块 → `status="unknown-block:<type>"`。
//   原始行截断进 `text` 保诊断能力(截断上限 `rawLineLimit`,避免日志被超长行撑爆)。
//
// 依据(01 spike 实测样本 `.scratch/agent-delegation/research/spike-claude-headless/*.stdout.ndjson`,非文档臆测):
//   * 顶层 `type` 实测只有 5 种:system / rate_limit_event / assistant / user / result。
//   * `assistant.message.content[]` 子块实测有 text / thinking / tool_use;`user.message.content[]` 有 tool_result / text。
//   * 工具结果由 **`type:"user"`** 承载(不是 assistant),`tool_use_id` 与 tool_use 的 `id` 配对 → 统一消息 `callID`。
//   * `tool_result.content` 实测是**字符串**(非对象),原样当 JSONValue 承载即可。
//   * 终态必须联合 `is_error` / `terminal_reason` / `api_error_status` 判定(见 `terminalStatus(of:)` 的顺序注释)。

import Foundation
import AAContracts

/// Claude Code headless `stream-json` 的归一化器(无状态,故用 enum 作命名空间,不可实例化)。
public enum ClaudeAdapter {

    /// 不可解析 / 未知事件时,原始行进 `text` 的截断上限(保诊断能力,又不让单行撑爆日志与内存)。
    private static let rawLineLimit = 512

    // MARK: - 公开入口

    /// 单行原始 stream-json → 统一消息(纯函数,无副作用,**不抛错**)。
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
        case "system":           return normalizeSystem(root)
        case "rate_limit_event": return normalizeRateLimit(root)
        case "assistant":        return AgentAdapterOutput(messages: normalizeAssistant(root))
        case "user":             return AgentAdapterOutput(messages: normalizeUser(root))
        case "result":           return normalizeResult(root)
        default:
            // 未知顶层事件(含双向控制消息 `control_request` / `control_response`)——
            // V1 不实现应答,只记录不崩:这就是票面「收到未知双向消息记日志不崩」的落点。
            return AgentAdapterOutput(messages: [
                AgentMessage(kind: .status, text: truncated(trimmed), status: "unknown:\(type)")
            ])
        }
    }

    /// 多行聚合(测试与上层消费用):按序归一化并合并 —— `terminal` 取**最后**一个非 nil,`sessionID` 取**第一个**非 nil。
    /// (终态取最后:一次执行只应有一个终态行,取最后可容忍异常多终态行的情形以最终态为准;
    ///  sessionID 取第一个:会话标识由 init 行确立,后续行不应改写它。)
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

    // MARK: - 逐事件归一化

    /// `system`:`init` 是会话起始(产 sessionID);其余 subtype(实测有 `api_retry` / `thinking_tokens`)原生保真兜底。
    private static func normalizeSystem(_ root: JSONValue) -> AgentAdapterOutput {
        let subtype = root.member("subtype")?.stringValue
        if subtype == "init" {
            return AgentAdapterOutput(
                messages: [AgentMessage.status(.sessionStarted)],
                sessionID: root.member("session_id")?.stringValue
            )
        }
        // 未枚举的 system 子类型:不吞、不猜,原样带 subtype 上浮(上层可见、可诊断,新增子类型也不会打崩)。
        return AgentAdapterOutput(messages: [
            AgentMessage(kind: .status, status: "system:\(subtype ?? missingSentinel)")
        ])
    }

    /// `rate_limit_event`:限流播报 —— 归一为共用词汇 `rate-limit`,原生 `rate_limit_info.status` 作 detail。
    private static func normalizeRateLimit(_ root: JSONValue) -> AgentAdapterOutput {
        let detail = root.member("rate_limit_info")?.member("status")?.stringValue
        return AgentAdapterOutput(messages: [AgentMessage.status(.rateLimit, detail: detail)])
    }

    /// `assistant`:遍历 `message.content[]`,逐子块归一化(text / thinking / tool_use;其余兜底)。
    private static func normalizeAssistant(_ root: JSONValue) -> [AgentMessage] {
        var messages: [AgentMessage] = []
        for block in contentBlocks(root) {
            let blockType = block.member("type")?.stringValue ?? missingSentinel
            switch blockType {
            case "text":
                messages.append(.text(block.member("text")?.stringValue ?? ""))
            case "thinking":
                // 实测 thinking 子块可能是空串(带 signature 的加密思考)——照收不特判,型别不丢。
                messages.append(.thinking(block.member("thinking")?.stringValue ?? ""))
            case "tool_use":
                messages.append(toolUseMessage(block))
            default:
                messages.append(AgentMessage(kind: .status, status: "unknown-block:\(blockType)"))
            }
        }
        return messages
    }

    /// `user`:实测承载**工具结果**(tool_result)与**中断提示**(text)两类子块 —— 二者语义迥异,必须分开归一。
    private static func normalizeUser(_ root: JSONValue) -> [AgentMessage] {
        var messages: [AgentMessage] = []
        for block in contentBlocks(root) {
            let blockType = block.member("type")?.stringValue ?? missingSentinel
            switch blockType {
            case "tool_result":
                messages.append(toolResultMessage(block))
            case "text":
                // **刻意不归一为 `.text`**:`type:"user"` 的文本不是 agent 的输出(实测中断场景是
                // `[Request interrupted by user]` 这类系统注入),当成 agent 发言会混淆发言方 → 归一为 status。
                messages.append(AgentMessage(
                    kind: .status,
                    text: block.member("text")?.stringValue,
                    status: "user:text"
                ))
            default:
                messages.append(AgentMessage(kind: .status, status: "unknown-block:\(blockType)"))
            }
        }
        return messages
    }

    /// `result`(终态行):被拒条目 → 最终答复文本 → 终态判定(+ aborted 时补一条 interrupted)。次序固定。
    private static func normalizeResult(_ root: JSONValue) -> AgentAdapterOutput {
        var messages: [AgentMessage] = []

        // ① 「操作被拒」:`permission_denials[]` 每条元素实测就 tool_name / tool_use_id / tool_input 三个键。
        //    据 tool_use_id 可与前面那条 `is_error:true` 的 tool_result 对上号(全链可追溯)。
        for denial in root.member("permission_denials")?.arrayValue ?? [] {
            messages.append(.permissionDenied(
                callID: denial.member("tool_use_id")?.stringValue,
                tool: denial.member("tool_name")?.stringValue,
                input: denial.member("tool_input")
            ))
        }

        // ② 终态判定 + aborted 时额外的 interrupted 状态消息(让「被中断」在消息流里也可见,不只在终态里)。
        //    注:agent 的最终答复文本(`result` 字段)**刻意不产成一条 `.text` 消息**,而是进终态的 `finalText`
        //    —— 它是最后一条 assistant text 的逐字回显,产成消息会让报告把同一段结论打印两遍。理由详见
        //    `AgentTerminalStatus.finalText` 的文档注释。
        let terminal = terminalStatus(of: root)
        if terminal.outcome == .aborted {
            messages.append(AgentMessage.status(.interrupted))
        }
        return AgentAdapterOutput(messages: messages, terminal: terminal)
    }

    // MARK: - 终态判定(顺序即语义,不可颠倒)

    /// 联合 `is_error` / `terminal_reason` / `api_error_status` 收敛终态 —— **绝不能只看 `subtype`**。
    ///
    /// 判定顺序(spike 实证,每一步都有对应样本钉死):
    ///  1. `terminal_reason == "aborted_streaming"` → `.aborted`
    ///     (04/08 中断样本:`is_error` **也**是 true —— 若把 failed 判在前,中断会被误报为失败,故顺序不可颠倒);
    ///  2. `is_error == true` 或 `api_error_status` 非空 或 `terminal_reason == "api_error"` → `.failed`
    ///     (05 invalid-model 样本:`subtype` 字面仍是 "success",只看 subtype 会把失败误报为成功);
    ///  3. `is_error == false` **且** `terminal_reason == "completed"` → `.succeeded`(两条都成立才算成功);
    ///  4. 其余 → `.failed`(fail-closed:兜底不乐观,宁可误报失败也不误报成功)。
    ///
    /// **为什么第 1 步不看 `subtype == "error_during_execution"`**(CR 结论,刻意为之):
    ///   04/08 两个中断样本的 `terminal_reason` 都是 `aborted_streaming`,该 subtype 分支在实测数据上冗余;
    ///   而 `error_during_execution` 字面是「执行期出错」这一**大类**,拿它单独作 aborted 的充分条件,
    ///   会把未来某个非中断成因的执行期错误判成「被用户取消」——失败被伪装成取消,上层连告警都不会发,
    ///   比「中断被误报为失败」更糟。何况整个本函数存在的理由就是「subtype 不可靠」(05 样本实证),
    ///   在不可信字段上建判定自相矛盾。真中断不会因此丢失:中断是宿主自己发起的动作,
    ///   job 层在发信号那刻本就知情(spec 对 Codex 明文要求「发信号那刻自标 aborted」,对 Claude 同样可用)。
    private static func terminalStatus(of root: JSONValue) -> AgentTerminalStatus {
        let subtype = root.member("subtype")?.stringValue
        let terminalReason = root.member("terminal_reason")?.stringValue
        let isError = root.member("is_error")?.boolValue
        // 注:`api_error_status` 正常时是**显式 JSON null**(不是缺键),`member(_:)` 把二者一视同仁地判为 nil。
        let apiErrorStatus = root.member("api_error_status")
        // 理由保真:优先原生 terminal_reason,缺失退回 subtype(仍留下可诊断的线索)。
        let reason = terminalReason ?? subtype
        // 终局答复(空串按缺失处理:不产空结论)。放终态而非消息流,见 `AgentTerminalStatus.finalText`。
        let finalText = root.member("result")?.stringValue.flatMap { $0.isEmpty ? nil : $0 }

        if terminalReason == "aborted_streaming" {
            return AgentTerminalStatus(outcome: .aborted, reason: reason, finalText: finalText)
        }
        if isError == true || apiErrorStatus != nil || terminalReason == "api_error" {
            return AgentTerminalStatus(outcome: .failed, reason: reason, finalText: finalText)
        }
        if isError == false && terminalReason == "completed" {
            return AgentTerminalStatus(outcome: .succeeded, reason: reason, finalText: finalText)
        }
        return AgentTerminalStatus(outcome: .failed, reason: reason, finalText: finalText)
    }

    // MARK: - 子块 → 消息(缺字段时保真降级,不臆造占位值)

    /// tool_use 子块 → tool-use 消息。`id` → `callID`(全链保留)。
    private static func toolUseMessage(_ block: JSONValue) -> AgentMessage {
        let callID = block.member("id")?.stringValue
        let tool = block.member("name")?.stringValue
        let input = block.member("input")
        if let callID = callID, let tool = tool {
            return .toolUse(callID: callID, tool: tool, input: input)
        }
        // 畸形子块(缺 id / name):便利构造器要求非可选,这里退回全字段 init 让缺的字段**如实留 nil**
        // —— 绝不拿空串冒充 callID(那会让下游误以为配上了对)。
        return AgentMessage(kind: .toolUse, tool: tool, callID: callID, input: input)
    }

    /// tool_result 子块 → tool-result 消息。`tool_use_id` → `callID`;`content` 实测是字符串,原样承载。
    ///
    /// 刻意**不**承载顶层兄弟字段 `tool_use_result`(实测是 Claude 私有的结构化细节,如 Write 的 structuredPatch):
    ///   它是单家 agent 的私有形状,进统一模型会让 6 型消息沾上 Claude 专属字段;排障需要它时去
    ///   `logs/raw.ndjson`(全量落盘、永不裁剪)。归一化只收两家都有的语义,这是「统一模型」的代价与边界。
    private static func toolResultMessage(_ block: JSONValue) -> AgentMessage {
        let callID = block.member("tool_use_id")?.stringValue
        let output = block.member("content")
        // `is_error` 键缺失即 nil(**不补默认 false**):「没说」与「明确说不是错」是两件事,后者才是 false。
        let isError = block.member("is_error")?.boolValue
        if let callID = callID {
            return .toolResult(callID: callID, output: output, isError: isError)
        }
        return AgentMessage(kind: .toolResult, callID: nil, output: output, isError: isError)
    }

    // MARK: - 小工具

    /// `type` / 子块 `type` 缺失时的哨兵串(让兜底路径的 status 串仍有意义,如 `unknown:(missing)`)。
    private static let missingSentinel = "(missing)"

    /// 取 `message.content[]`;形状不符(缺键 / 非数组)时返回空数组 —— 不崩。
    private static func contentBlocks(_ root: JSONValue) -> [JSONValue] {
        root.member("message")?.member("content")?.arrayValue ?? []
    }

    /// 原始行截断到 `rawLineLimit`(保诊断能力,不让超长行撑爆日志)。
    private static func truncated(_ line: String) -> String {
        line.count <= rawLineLimit ? line : String(line.prefix(rawLineLimit))
    }
}

// JSONValue 的取值便利(`member` / `boolValue` / `arrayValue`)已上提为模块内共用,见 `JSONValueAccess.swift`
// —— 03 票 Codex adapter 落地后两家都要用 `member(_:)`,而它的「缺键与显式 null 一视同仁」是两家各自正确性的
//    前提,各留一份会在将来被单边修改时静默分叉,故收敛为一处 internal 声明。
