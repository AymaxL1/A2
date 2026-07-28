# multica 本地 Agent 调用适配层 —— 架构还原报告

> 调研资产：2026-07-29 由子代理对 multica（multica-ai/multica，浅克隆于 `/Users/Shared/Workspaces/multica`）源码逐文件分析产出，全部结论带 file:line 证据。
> 用途：《宿主调用本地 agent 适配层》效应（`.scratch/agent-delegation/`）的参考设计输入。

范围说明：multica 是一个 Go 后端（`server/`，chi + sqlc + gorilla/websocket）+ Next.js/Electron 前端（`apps/`）的任务管理平台（`CLAUDE.md:16`：*"AI-native task management platform for small teams, with agents as first-class assignees"*）。真正的「本地 agent 适配层」是一个纯 Go 库包 **`server/pkg/agent`**（17 个后端文件，非测试代码约 1.9 万行，测试代码规模与之相当甚至更大，如 `codex_test.go` 155KB），被本地守护进程 **`server/internal/daemon`**（`multica daemon` 这个独立 OS 进程）引用消费。注意 multica 产品里还有一个同名但完全不同的「Agent」概念（工作区里可配置的 AI 角色/权限实体，`server/internal/handler/agent*.go`），下文严格只讨论**调用本地 coding agent CLI 的适配层**，涉及产品级 Agent 概念处会明确标注以免混淆。

---

## 0. 全链路一览

```
server/pkg/agent.Backend            —— 纯 Go 接口，同进程内 channel，无网络协议
        ↑ 被调用
server/internal/daemon (Daemon)     —— 独立 OS 进程，本机常驻，pidfile 管理
        ↕ HTTP 轮询/POST + 一条 WS(唤醒用)
multica server (Go, chi, Postgres)  —— events.Bus 内部发布
        ↓ WS (/ws) + Redis Streams 分片中继（多实例扩展）
apps/web /apps/desktop /apps/mobile —— WSClient 订阅、TanStack Query 落地
```

四层里，只有 **第一层（`agent.Backend`）** 是本报告说的「适配层」本身；第二三层是它的宿主/上层，第 7 节详述。

---

## 1. 适配层的核心抽象

统一接口定义在 **`server/pkg/agent/agent.go`**。

```go
// server/pkg/agent/agent.go:17-22
type Backend interface {
    // Execute runs a prompt and returns a Session for streaming results.
    Execute(ctx context.Context, prompt string, opts ExecOptions) (*Session, error)
}
```

只有**一个方法**。没有独立的 `Start/Send/Interrupt/Destroy` 方法——这是一个关键设计选择，见第 8 节。

- **`ExecOptions`**（`agent.go:25-92`）：单次执行的入参，字段包括 `Cwd/Model/SystemPrompt/MaxTurns/Timeout/SemanticInactivityTimeout/IdleWatchdogTimeout/HandshakeTimeout/ResumeSessionID/ResumeExpected/ExtraArgs/CustomArgs/McpConfig/ThinkingLevel/ServiceTier/OpenclawMode/ClaudeSettingsPath`。每个字段的 doc comment 直接写明「哪些 backend 会消费它、其余的会怎样忽略」——这是它声明能力差异的主要方式（详见第 6 节）。
- **`Session`**（`agent.go:108-114`）：
  ```go
  type Session struct {
      Messages <-chan Message // 结束时 close（早于 Result）
      Result   <-chan Result  // 恰好收到一个值后 close
  }
  ```
  "启动"即 `Execute()` 调用本身；"流式输出"＝消费 `Messages`；"获取终局"＝阻塞读 `Result`；**没有显式的 Interrupt()/Destroy() 方法**——中断永远是调用方 cancel 传入的 `context.Context`（见第 4 节"中断"小节）。
- **`Message` / `MessageType`**（`agent.go:117-140`）：内部统一事件模型，六种类型 `text/thinking/tool-use/tool-result/status/error/log`，字段 `Type/Content/Tool/CallID/Input/Output/Status/Level/SessionID`（详见第 3 节）。
- **`Result`**（`agent.go:166-205`）：终态，`Status("completed"/"failed"/"aborted"/"timeout"/"cancelled")/Output/Error/DurationMs/SessionID/Usage/ResumeRejected`（+两个 provider-internal 私有字段）。
- **`Config`**（`agent.go:208-217`）：构造 Backend 用的静态配置——可执行文件路径、探测到的 CLI 版本、环境变量、logger、TaskID/RuntimeID 等。
- **工厂函数 `New()`**（`agent.go:295-338`）是一个 17 分支的 `switch agentType`，直接 `return &xxxBackend{cfg: cfg}, nil`——没有注册表/插件机制，新增 agent = 改这个 switch + 新增一个 `.go` 文件（详见第 6/8 节）。
- **`SupportedTypes`**（`agent.go:236-254`）是硬编码的合法 `agentType` 白名单，与 DB 迁移里 `runtime_profile.protocol_family` 的 CHECK 约束保持同步（注释指名了每个 backend 是哪次 migration 加入的）。
- `runContext()`（`agent.go:100-105`）是唯一的超时/取消语义封装：`Timeout>0` 才有硬性 wall-clock 超时，否则完全依赖上层的"不活跃看门狗"存活判定。

---

## 2. 支持哪些 agent，各自怎么和进程通信

`server/pkg/agent/agent.go:1-6` 包头注释即列出了全部 17 家：*Claude Code, CodeBuddy, Codex, Copilot, OpenCode, DevEco Code, OpenClaw, Hermes, Pi, Cursor, Kimi, Kiro, Antigravity, Qoder, Trae, Grok, Qwen Code*。**注意**：`CLI_AND_DAEMON.md:135-155` 的表格里写了 "Gemini | `gemini`"，但代码里根本没有 `gemini` 这个 backend（`gemini-` 只是 Antigravity 模型目录里的一个模型名前缀，`models.go:264-265,456,1750`）——文档与代码存在漂移，报告设计参考时以代码为准。

**共同底层**：全部 17 个都是 `os/exec.CommandContext` 直接 spawn 本地 CLI 二进制（`claude.go:74`、`codex.go:885`……逐一同构），**没有一处使用 PTY**（`proc_other.go:16-32`、`proc_windows.go` 只做进程组/静默窗口处理，不涉及伪终端），**没有一处调用任何厂商官方 SDK**——全部是"造轮子"式地手写协议客户端。取消统一用进程组信号（见第 4 节）。

按通信协议分四族：

| 协议族 | Backend / 文件 | 传输 | Prompt 传递方式 | 关键证据 |
|---|---|---|---|---|
| **Claude 系 stream-json**（自有 JSON schema，逐行 NDJSON，双向：agent 会用 `control_request`/`control_response` 回传询问） | `claude.go` | stdin/stdout pipe，长连接，写完 prompt 后**保持 stdin 打开** | prompt 走 stdin（`writeClaudeInput`） | `claude.go:32-33,102-158,270-271,439-481` |
| 同上，几乎照搬 Claude 协议（腾讯 CodeBuddy） | `codebuddy.go` | 同 claude | stdin | `codebuddy.go:18-19` 注释明写"mirrors claude.go's execution model" |
| **OpenCode 兼容 NDJSON**（`run --format json`） | `opencode.go` | stdout pipe only（无 stdin） | **CLI 位置参数**（`opencode.go:69,101`） | `opencode.go:44` |
| 同协议族（DevEco 明确复用 OpenCode 协议） | `deveco.go` | 同 opencode | CLI 参数（`deveco.go:95,121`） | `deveco.go:13` 注释："DevEco speaks the same `run --format json` protocol and emits the same NDJSON" |
| **自有 JSON/JSONL，prompt 走参数** | `copilot.go`（`-p <prompt> --output-format json --allow-all --no-ask-user`） | stdout only | CLI 参数（`copilot.go:461`） | `copilot.go:18-19,457-465` |
| 同上 | `qwen.go`（`qwen -p <prompt> --output-format stream-json`） | stdout only | CLI 参数（`qwen.go:50`） | `qwen.go:14,50` |
| 同上，但**刻意打开又立刻关闭 stdin**避免 systemd 下挂起 | `pi.go`（`pi -p <prompt> --mode json`） | stdout + 一次性 stdin | CLI 参数（`pi.go:525`） | `pi.go:222-241`（#2188 的坑） |
| 自有 stream-json（非 ACP） | `cursor.go`（`cursor-agent -p --yolo`） | stdin/stdout | **stdin**（`cursor.go:77-89`） | `cursor.go:20,42-101` |
| 自有 stream-json，**prompt 走参数，且自称"streaming"实为读完整个 buffer 再解析** | `openclaw.go`（`openclaw agent --message <prompt> --output-format stream-json --yes`） | stdout only | CLI 参数（`openclaw.go:213`） | `openclaw.go:299-338`（代码注释自曝"no longer truly streaming"） |
| **无结构化协议，纯文本 stdout 抓取** | `antigravity.go`（`agy -p <prompt> --dangerously-skip-permissions`） | stdout only（逐行当纯文本） | CLI 参数（`antigravity.go:447`） | `antigravity.go:19-38`（最不规整的一个，见第 8 节） |
| **ACP（Agent Client Protocol）JSON-RPC 2.0**，共享同一个客户端实现 `hermesClient` | `hermes.go`（`hermes acp`） | stdin/stdout JSON-RPC | 通过 `session/prompt` RPC | `hermes.go:157-159,690-719` |
| 同协议，复用 `hermesClient` | `kimi.go`（`kimi acp`） | 同上 | `session/prompt` | `kimi.go:14-26,120-123` |
| 同协议 | `kiro.go`（`kiro-cli acp`） | 同上 | `session/prompt` | `kiro.go:17-33` |
| 同协议 | `qoder.go`（`qodercli --yolo --acp`） | 同上 | `session/prompt` | `qoder.go:16-29` |
| 同协议 | `traecli.go`（`traecli acp serve --yolo`） | 同上 | `session/prompt` | `traecli.go:17-37` |
| 同协议 | `grok.go`（`grok agent --always-approve stdio`） | 同上 | `session/prompt` | `grok.go:18,57-61` |
| **Codex 私有 JSON-RPC 2.0**（`app-server`，不是 ACP） | `codex.go`（`codex app-server --listen stdio://`） | stdin/stdout JSON-RPC | `turn/start` RPC 参数 | `codex.go:164-177` |

**ACP 家族内部并不是铁板一块**：即便都自称"ACP"，恢复会话用的方法名在各 vendor 之间就不统一——`hermes.go:387`、`kimi.go:217`、`qoder.go:242` 用 `session/resume`，而 `kiro.go:254`、`traecli.go:260`、`grok.go:325` 用 ACP 标准方法名 `session/load`。适配层必须逐个 vendor 硬编码，"用了标准协议"并没有真正省下六份高度相似但仍需分别维护的 backend 文件。

**Codex 的 JSON-RPC 方法名**（`codex.go` 内 grep 得到的字面量）：请求方向 `initialize`（`codex.go:1195`）、`thread/start`（`codex.go:1628`）、`thread/resume`（`codex.go:1579`）、`thread/name/set`（`codex.go:1663`）、`turn/start`（`codex.go:1328`）；通知方向 legacy 事件走 `codex/event`（`codex.go:1950,2359`），新版走 `turn/started`/`item/*` 等 raw v2 通知（`codex.go:2376-2383`）。

---

## 3. 消息/事件的归一化

**同一套 6 字段 shape，在 5 层管道里被原样搬运**（这是本项目最一致的设计决策）：

1. **适配层内部**：`agent.Message`（`agent.go:129-140`）——`Type/Content/Tool/CallID/Input/Output/Status/Level/SessionID`。各 backend 各自把自己的协议事件翻译成它，例如 Claude 把 `content[].type=="tool_use"` 翻成 `Message{Type: MessageToolUse, Tool: block.Name, CallID: block.ID, Input: input}`（`claude.go:396-407`）；ACP 家族把 `tool_call`/`tool_call_update` notification 翻成同一 shape（`hermes.go:1311-1437` 的 `handleToolCallStart/handleToolCallUpdate`，还专门做了**跨多帧参数拼接**的缓冲——Kimi 的 tool 参数是逐 token 流式到达的累积 JSON，`pendingToolCall.argsText` 攒够/看到 `status=completed` 才真正 emit 一次 `MessageToolUse`，`hermes.go:708-716,1437-1521`）。
2. **daemon 落地/裁剪**：`executeAndDrain` 的 drain 循环（`daemon.go:5556-5679`）把 `agent.Message` 收窄成 `TaskMessageData`（`server/internal/daemon/client.go:358-365`，字段 `Seq/Type/Tool/Content/Input/Output`）——**`CallID` 和 `MessageLog` 在这一步被丢弃**（switch 语句 `daemon.go:5569-5679` 根本没有 `MessageLog` 分支；`CallID` 只在本地 `callIDToTool` map 里临时用来给 `tool_result` 反查工具名，`daemon.go:5607-5610,5641-5646`，之后就不再传递）。
3. **HTTP 上报**：`client.ReportTaskMessages`（`client.go:367-371`）POST 到 `/api/daemon/tasks/{id}/messages`（路由 `server/cmd/server/router.go:836`）。
4. **服务端持久化**：`handler.ReportTaskMessages`（`server/internal/handler/daemon.go:3644-3707`）先做敏感信息脱敏（`redact.Text/redact.InputMap`，`daemon.go:3677-3679`），写入 Postgres `task_message` 表（`CreateTaskMessage`，`daemon.go:3685-3693`），再 `publishTask`（`handler.go:508-517`）进内部 `events.Bus`。
5. **下发前端**：`protocol.TaskMessagePayload`（`server/pkg/protocol/messages.go:103-113`，同样六个核心字段 + `TaskID/IssueID/CreatedAt`），WS 事件名 `task:message`（`protocol/events.go:40`），前端类型 `ChatTimelineItem`（`packages/core/chat/store.ts:279-287`）——**字段与最初的 `agent.Message` 几乎一一对应**。

**没有 diff 类型，没有权限请求类型**。文件编辑就是一次普通 `tool_use`：`Input` 里塞了 `file_path/old_string/new_string` 之类原始 JSON，前端渲染时用启发式字段名猜测摘要（`getToolSummary`，`packages/views/chat/components/chat-message-list.tsx:844-865`：依次尝试 `query/file_path/path/pattern/description/command/prompt/skill`），折叠区里就是 `JSON.stringify(item.input, null, 2)` 原样转储（`ToolCallRow`，`chat-message-list.tsx:867-894`）；`tool_result` 同理直接展示原始文本（`ToolResultRow`，`chat-message-list.tsx:896-`）。整条链路里 **"diff" 不是一等公民**。

**ACP"最终答案 vs 中间叙述"的额外归一化**：ACP 协议本身不区分"过程话术"和"最终回复"（都是同一种 `agent_message_chunk`），适配层为此专门写了 `acpDeliverableTracker`（`server/pkg/agent/acp_deliverable.go:27-68`）——把"最近一次工具调用之后的文本"当作交付内容（`observe()` 在遇到 `MessageToolUse` 时 reset 累积区，`acp_deliverable.go:41-53`），这是一个**启发式**（文件注释自己承认"That boundary is a heuristic until the runtimes mark the final answer explicitly"，`acp_deliverable.go:16-17`）。

**排序上的一个隐患**（详见第 8 节）：text/thinking 走 buffer，只在 500ms ticker 触发 `flush()` 时才分配 `Seq`（`daemon.go:5504-5537,5539`）；而 `tool_use/tool_result/error` 到达时立即分配 `Seq` 并直接 append 进 `batch`（`daemon.go:5612-5619,5636-5655,5671-5678`）——同一个 500ms 窗口内先出现的文本可能因为延迟分配而拿到比后出现的工具调用更大的 `Seq`。

---

## 4. 会话与进程生命周期

- **进程模型：每个 Task 一次性拉起一个子进程，不常驻、不复用**。`CLI_AND_DAEMON.md:159-165` 原话：*"当任务到达时，[daemon] 创建隔离工作目录、拉起 agent CLI、并流式回传结果"*；代码上体现在 `executeAndDrain`（`daemon.go:5427-5436`）每次调用都新建一个 `backend.Execute`。
- **daemon 自身**是独立 OS 进程，`multica daemon start/stop/restart/status`，pidfile 管理（`server/cmd/multica/cmd_daemon.go`），支持二进制热更新后自重启（`RestartBinary`，`daemon.go:1108-1111`；重启逻辑 `cmd_daemon.go:815-868`）。
- **任务获取**：HTTP 轮询 + 认领（`ClaimTask`/`ClaimTasks`，`client.go:204-300`，默认 3s 间隔，可配 `MULTICA_DAEMON_POLL_INTERVAL`，`CLI_AND_DAEMON.md:162,173`），叠加一条常驻 WebSocket（`daemonws.Hub`，`server/internal/daemonws/hub.go`）用于低延迟唤醒（`NotifyTaskAvailable`，`hub.go:315-345`）——WS 只是缩短轮询延迟的优化，真相源仍是 HTTP。心跳 15s 一次（`SendHeartbeat`，`client.go:463`）。
- **会话延续完全委托给底层 CLI 自己的本地存储**，multica 服务端只存一个字符串指针：`task.session_id`（迁移 `server/migrations/020_task_session.up.sql`）。下一个任务把它塞回 `ExecOptions.ResumeSessionID`，各 backend 各自转成 `--resume <id>`（claude/codex）、`session/resume`/`session/load`（ACP 族）等。
  - 查找规则：`GetLastTaskSession` 按 `(agent_id, issue_id)` 查最近一次**未被判定为"中毒(poisoned)"**的会话（`server/internal/handler/daemon.go:2022-2038`），**且要求 `prior.RuntimeID == task.RuntimeID`**（`daemon.go:2032`）——**换句话说，跨机器/跨 daemon 无法续会话**，只能在产生该 session 的同一台机器上恢复，因为真正的对话记录（Claude 的 session 文件、Codex 的 rollout 文件……）躺在那台机器本地磁盘上，multica 数据库里只有指针。Rerun 场景同理（`daemon.go:2007-2014`）。
  - "中毒会话"识别（`server/internal/daemon/poisoned.go:1-40`）：输出侧命中已知的"放弃话术"标记、或错误侧是 400 invalid_request（如内嵌图片超限）、或 Codex 语义无进展超时——这三类失败续接大概率复现同样的坏状态，因此下一个任务改走全新会话。
  - `Result.ResumeRejected`（`agent.go:172-194`）是"这次续接被明确拒绝"的正面证据，只有部分 backend 能可靠检测（`resumeRejectionUndetectable`，`agent.go:279-285`：antigravity/copilot/cursor/deveco/opencode 不算数，其余算），驱动同任务的自动降级重试（`daemon.go:5389-5420` `freshSessionMayHelp`）。
  - **早绑定 session 指针防崩溃丢失**（`daemon.go:5570-5602`，`MUL-5305`）：一拿到 `SessionID` 就立刻（对 Codex 还要等 rollout 文件真落盘）调 `PinTaskSession`（`client.go:418`），而不是等任务彻底结束才存，这样 daemon 中途崩溃也不会丢掉续接指针。
- **存活判定不是心跳式 IPC，而是"消息静默"看门狗**：`AgentIdleWatchdog`（默认可配置，0 = 关）+ 更宽松的 `AgentToolWatchdog`（工具调用挂起中单独给更大预算，用 `inFlightTools` 计数区分，`daemon.go:5468-5490`）。触发后 `agentCancel()` → `context` 取消 → **进程组级** SIGTERM→（等待 grace period）→SIGKILL（`configureProcessGroup`/`signalProcessGroup`，`server/pkg/agent/proc_other.go:16-32`；claude/codex/opencode/cursor 等各自在 `Execute` 里用 `cmd.Cancel = func() error { return nil }` 接管默认取消行为再手动 kill 整个进程组，如 `claude.go:84-90,196-211`、`codex.go:887-903,1211-1253`）。**没有任何一个 backend 通过协议层消息（ACP `session/cancel`、Codex RPC 等）发起取消**——中断永远是操作系统级的进程组信号，代码里搜不到任何 `session/cancel` 调用。
- **服务端主动取消的传播**：daemon 后台轮询 `GetTaskStatus`（`client.go:442-450`，调用点 `daemon.go:3352,3532`）发现任务被服务端标记 cancelled 后本地 cancel context，同样落到上面那条进程组 kill 路径。
- **崩溃恢复**：daemon 重连/重新注册时对上次心跳失联的 runtime 调 `RecoverOrphans`（`client.go:435-437`，调用点 `daemon.go:913,2391`），由服务端回收被"消失的" runtime 认领着但再也不会完成的任务。

---

## 5. 权限/审批流（重点）

**结论先行：属实——agent 执行过程中永远不会真的停下来等"人"批准；所有会触发协议层"审批请求"的地方，都在守护进程自己的代码里同步、原地、自动应答，从不上抛给 UI 或人。**

### 5.1 各 adapter 启动时的完整 bypass/auto-approve 配置（file:line）

| Backend | 具体机制 | 证据 |
|---|---|---|
| **Claude Code** | CLI 参数 `--permission-mode bypassPermissions`，且该参数被列入 `claudeBlockedArgs`（`blockedWithValue`），**用户自定义 custom_args 无法覆盖它** | `claude.go:657`（blocked 声明）、`claude.go:674`（实际拼进 args）|
| **CodeBuddy** | 同 Claude，同样硬编码且 block 覆盖 | `codebuddy.go:32`（blocked）、`codebuddy.go:46`（拼参数） |
| **Codex** | **不是单一 flag**，是两层：①`sandbox_mode`（workspace-write / danger-full-access）写进每任务专属 `$CODEX_HOME/config.toml`（`server/internal/daemon/execenv/codex_sandbox.go:347` `sandbox_mode = %q`），控制"物理上能不能做"；②`app-server` JSON-RPC 层，Codex 把每次需要批准的动作都发成一条 **agent→client 的 RPC 请求**（见 5.2），multica 的 `codexClient` 无条件自动应答"同意" | 见 5.2 |
| **Cursor Agent** | CLI 参数 `--yolo`，同样 blocked 防覆盖 | `cursor.go:823`（blocked）、`cursor.go:850`（拼参数） |
| **Copilot CLI** | CLI 参数组合 `--allow-all --no-ask-user`（还外加 `--allow-all-tools/--allow-all-paths/--allow-all-urls` 均在 blocked 表里防覆盖） | `copilot.go:442-450`（blocked 表）、`copilot.go:461-465`（实际拼参数） |
| **OpenCode / DevEco** | CLI 参数 `--dangerously-skip-permissions` | `opencode.go:40,69`；`deveco.go:66,95` |
| **Antigravity** | CLI 参数 `--dangerously-skip-permissions` | `antigravity.go:421`（blocked）、`antigravity.go:448`（拼参数） |
| **Qwen Code** | CLI 参数 `--yolo` | `qwen.go:43`（blocked）、`qwen.go:61`（拼参数） |
| **Pi** | 无需专门 flag——`-p --mode json` 非交互模式本身就没有交互审批路径 | `pi.go:497-501` |
| **OpenClaw** | `--yes`/非交互标志 | `openclaw.go:46-49` |
| **Hermes** | 环境变量 `HERMES_YOLO_MODE=1`（但只压制"危险 shell 命令"提示，不压制文件编辑审批，兜底靠 ACP 层拦截） | `hermes.go:207-208` |
| **Kiro / Qoder / Trae / Grok** | CLI 参数 `--yolo`（Kiro/Qoder/Trae）或 `--always-approve`（Grok），**且这只是防御性冗余**——真正的兜底是 ACP 协议层拦截（见 5.2） | `qoder.go:24,94`；`traecli.go:28,112`；`grok.go:28,140` |
| **Kimi** | **CLI 本身不支持 `--yolo` 类 flag**，完全依赖共享的 ACP 拦截逻辑 | `kimi.go:53-55` 注释 |

### 5.2 不是简单 bypass 时：「适配层拦截后原地自动应答」，不是「异步上抛给 UI」

**Codex 和 ACP 家族的 CLI 即便加了 auto-approve flag，协议本身仍会在轮次中间发一条"审批请求"给驱动它的客户端**——multica 就是这个客户端，应答逻辑写在适配层代码里，**在读 stdout 的同一个 goroutine 里同步完成**，从不等待任何外部（网络请求/UI 弹窗/人）。

**Codex（`codex.go:2270-2293`）**：`handleServerRequest` 对 `item/commandExecution/requestApproval`、`execCommandApproval`、`item/fileChange/requestApproval`、`applyPatchApproval` 一律 `respond(id, {"decision": "accept"})`；`item/permissions/requestApproval` 走 `codexPermissionsApprovalResponse`（`codex.go:2305-2334`，注释直言 *"In daemon mode there is no human to approve, so we echo back the requested network / fileSystem profile and scope it to the current turn"*）；连 MCP 的通用 elicitation（工具向调用方提问的标准机制）也被无脑 accept 且回填空内容。

**ACP 家族（共享 `hermesClient`）**：`session/request_permission` 由 `handleAgentRequest` 同步应答（`hermes.go:843-917`），核心决策函数 `selectACPPermissionOption`（`hermes.go:966-1001`，doc comment 948-965）：①优先选"仅本 session 有效"的授权选项；②否则任意 `allow_once`；③都没有就选 `reject_once` 只拒这一个动作；④什么安全选项都没提供就回 JSON-RPC 协议错误——**绝不编造 agent 没 offer 过的 optionId，绝不自动选永久性 `allow_always`**（注释引用了真实回归 multica#5300：allow_always 会持久化到 runtime 属主的磁盘 allowlist，寿命超过任务本身）。

**Claude Code（`claude.go:439-481`）**：stream-json 的 `control_request` 在同一读循环里同步应答 `{"behavior": "allow", "updatedInput": inputMap}`。

**协议层面 agent 子进程确实会阻塞等应答，但这个等待永远是毫秒级、进程内的**——回复方就是 daemon 自己。代码库里完全搜不到"审批超时"处理：不需要，因为另一端从来没有人。

**更直接的旁证——multica 连"问人"功能本身都主动屏蔽**：Claude Code 的 `AskUserQuestion` 工具被显式 disable（`claude.go:675-681`，注释解释：非交互模式没有 UI 可渲染，问题用户永远看不见，见 GitHub #2588；"用户侧澄清应该走 issue 评论"）；CodeBuddy 同样禁用（`codebuddy.go:47`）；Copilot 直接 `--no-ask-user`（`copilot.go:450,464`）。**agent 永远不能在任务中途向人求助，只能"自己判断 + 把疑问写进 issue 评论"。**

### 5.3 权限档位是否可配？

**不可配。全局唯一档位，硬编码，没有任何开关。**排除法证据：DB 里唯一的 `permission_mode` 字段（`server/migrations/130_agent_invocation_permission.up.sql:32-33`）是产品级"谁有权调用这个 Agent 角色"的 ACL，与 CLI 权限无关；全仓库 grep `require_approval|approval_mode|risk_level` 在 agent/handler/db 包零命中；`ExecOptions` 无任何审批档位字段；各 backend 的 bypass flag 都在 blocked-args 表里**禁止用户改回交互模式**——"不允许调低自动化程度"是显式设计。

### 5.4 有没有"先斩后奏"（自动同意 + 事后审计/回滚）？

**适配层/daemon 层没有专门的审批日志或自动回滚。**真正的"后奏"是结构性的、在适配层之外的 VCS 工作流：agent 在隔离的每任务 git 分支上工作（`server/internal/daemon/execenv/git.go`），产出走 GitHub/GitLab/Forgejo 开 PR/MR（支持 draft），multica CLI 给 agent 的命令面里**没有"合并 PR"子命令**（grep `merge` 无命中）——"人 review diff 再点合并"落在 VCS 平台原生 UI 里。**中间没有 multica 自己的审计轨迹或回滚开关**；如果参考设计需要"自动同意+可追溯+可撤销"，这一块需要自己补。

---

## 6. 能力差异处理

没有单一的"能力注册表"，是五种并存的机制：

1. **编译期白名单**：`SupportedTypes`（`agent.go:236-254`）决定 `runtime_profile` 能选哪个"协议族"（`runtime_profile.go:18-29`）。产品化扩展仅限"给现有协议族换可执行文件/固定参数"；接入新协议必须改代码（新 `.go` + `New()` switch 分支 + `launchHeaders` + `MinVersions`）。
2. **字段级软声明**：`ExecOptions` 每个字段 doc comment 写明谁支持，如 `ThinkingLevel`（`agent.go:66-71`）——**不支持＝静默忽略，不是报错**，全字段一致约定。
3. **运行时 ACP 握手协商**：`initialize` 响应的 `agentCapabilities.mcpCapabilities` 被解析（`extractACPMcpCapabilities`），现场过滤该发哪种 MCP 传输（`filterACPMcpServersByCapability`，调用点 `hermes.go:371` 等）——唯一"探测式"能力协商。
4. **拒绝拉平的价值观**（最值得参考）：推理档位/模型目录**故意不跨厂商归一化**（`thinking.go:15-22`，MUL-2339：*"we deliberately do not flatten Claude's `low|medium|high|xhigh|max` and Codex's `none|minimal|...|ultra` onto a shared enum... must round-trip exactly through each CLI's own value vocabulary"*）。做法：现场跑 CLI 自省，按 `(provider, executablePath, cliVersion)` 缓存（`thinkingCacheKey`，`thinking.go:30-34`）。**模型选择同理：`ExecOptions.Model` 每次执行传入，原生词表透传。**
5. **版本闸门**：`MinVersions`（`version.go:13-19`）注册阶段硬拒过旧 CLI（`probeBuiltinRuntime`，`daemon.go:1269-1327`）；软性功能闸门（`MinHandoffCLIVersion`，`version.go:41-63`）探测不到就静默降级。

具体范例：
- **图片/多模态**：`ExecOptions`/`Message` 上根本没有 image 字段——daemon 把附件写成 prompt 里的文字指令，让 agent 自己跑 `multica attachment download <id>` 落地成本地文件再用自带文件工具"看见"（`prompt.go:469-485`）；出图走 `attachment upload`（`prompt.go:487-497`）。零后端专属代码换统一"视觉能力"。
- **上游功能与数据模型不兼容 → 直接关掉留逃生舱**：Codex 新版默认开 `features.multi_agent`（模型可自派子会话），multica 任务模型管不了，于是每任务 config.toml 注入 `features.multi_agent = false`（`execenv/codex_multi_agent.go:11-52`），环境变量 `MULTICA_CODEX_MULTI_AGENT=1` 可手动打开。
- `resumeRejectionUndetectable`（`agent.go:279-285`）也是能力声明——列出哪些 backend 连"续接被拒"都判断不出来。

---

## 7. 适配层与上层（server/UI）的边界

`agent.Backend` 接口**没有自己的线协议**——同进程 Go 接口 + channel。边界经两跳网络到 UI：

1. **daemon → server**：HTTP/REST 为主（bearer token，`client.go:119-200`）——轮询认领（3s）、500ms 批量 POST 消息、15s 心跳、终态上报；叠加一条常驻 WS **只用于服务端"叫醒"daemon**（`daemonws/hub.go:315-368`），醒后仍回落 HTTP 取数——WS 是延迟优化，不是权威通道。
2. **server 内部**：handler 写 Postgres → 进程内 `events.Bus`（`handler.go:508-517`）。
3. **server → 前端**：独立 WS `GET /ws`（`router.go:737-739`），Redis Streams 分片中继横向扩展（`sharded_stream_relay.go`，8 shard），事件 `task:message`。
4. **前端**：`WSClient`（`packages/core/api/ws-client.ts`），WS 事件只 invalidate/patch TanStack Query 缓存（`CLAUDE.md:42`）。

同一套六字段消息 shape 贯穿两跳，没有二次转译。

---

## 8. 值得借鉴与踩坑点

### 值得借鉴

1. **单一 channel-pair 抽象吃下 17 种迥异协议**——`Session{Messages, Result}` 是教科书级适配器模式：每个 backend 独立、可单测（`codex_test.go` 一家 155KB），互不传染。
2. **`filterCustomArgs`/blocked-args 通用防覆盖机制**（`claude.go:923-1000`）：允许用户自由加 CLI 参数与保证协议关键 flag 不被覆盖共存。
3. **能力声明贴着代码写**——`ExecOptions` 字段自带"谁支持/不支持会怎样"注释，真话和实现在同一个 diff 里。
4. **拒绝伪造统一抽象**：推理档位、模型名不拉平，透传原生词表 + 现场探测缓存（`thinking.go`）。
5. **能力不兼容就干脆关掉，留逃生舱**（`codex_multi_agent.go`）。
6. **图片/附件降维成文件系统问题**，零后端专属代码，最漂亮的 lowest-common-denominator 技巧。
7. **ACP 权限自动应答有认真的失败闭合设计**（`selectACPPermissionOption`，连历史事故编号 #5300 都写在注释里）。
8. **会话指针"能拿到就立刻落盘"**（MUL-5305）,设计期堵上 crash-safety。
9. **中断路径高度统一**：17 个 backend 全部 `context → 进程组 SIGTERM→SIGKILL`，只维护一套"杀干净进程树"的逻辑。

### 看起来勉强/耦合的地方

1. **审批环节整体缺位是产品选择**：要做真·人工审批（危险操作前暂停等人点头），这层帮不上——连"问用户"工具都被 disable；且 `tool_use` 消息到达适配层时底层 CLI 通常已决定执行。需要在这层之上重新设计"提交前拦截"。
2. **归一化在 daemon 边界有损**：`CallID` 不下发（并发同名工具调用下游无法配对）；`MessageLog` 被吞。
3. **消息排序隐患**：文本 500ms 缓冲才分配 Seq，工具事件即时分配——持久化顺序可能与真实时间线不一致。
4. **"标准协议"没带来真一致性**：ACP 六家连恢复会话方法名都不统一（`session/resume` vs `session/load`），厂商 quirk 仍要逐家维护。
5. **openclaw "streaming" 名不副实**（`openclaw.go:333-338` 自认累积到进程结束才 drain）——接口语义在单个 backend 上悄悄不一致，是"接口谎言"。
6. **antigravity 是最脏一处**：纯文本抓取、glog 日志里抠会话 ID、靠重读磁盘 transcript 兜底——说明并非所有厂商 CLI 都适合被无头驱动。
7. **会话续接机器绑定**（`prior.RuntimeID == task.RuntimeID`）——"会话存储完全委托底层 CLI 本地状态"的必然代价。
8. **`custom_args`/`custom_env` 信任边界薄**（`claude.go:936-937` 直说 workspace 成员被信任）——叠加全局 bypass，爆炸半径不小，只有 Codex 有 OS 级 sandbox 兜底。
9. **复杂度分布极不均匀**：`codex.go` 单文件 106KB/2900+ 行远超其余（15-40KB）——协议最古怪的那一个主导整个适配层的复杂度预算，工作量评估不能线性外推。
