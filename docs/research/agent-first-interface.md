# Agent-first 接入面调研：外部 Codex 调用本应用

> 对应票：`.scratch/v1-mac-recharter/issues/05-agent-first-interface.md`。
> 调研日：2026-07-28。域名说明：Codex 官方文档现址为 learn.chatgpt.com（本次再次实测 `developers.openai.com/codex/*` 308 永久重定向到 `learn.chatgpt.com/docs/*`），与 `docs/research/swift-mac-route.md` 开头的核实一致。
> 标注约定：**事实** = 一手来源可直接支撑；**【推断】/【建议】** = 由事实推出的判断或设计建议。第 6 节整体为建议。

## 0. 结论摘要

1. **官方推荐的「第三方应用被 Codex 调用」路径**：官方没有钦点唯一路径，而是给出一组分工明确的机制。官方定位语句：MCP 用于「Codex 需要本地 repo 之外的能力时」（外部工具/应用的标准通道）；AGENTS.md 是常驻指令；Skills 是可带脚本的可复用工作流；Plugin 是把 skill + MCP 连接打包分发的官方载体（ChatGPT 与 Codex 共用一个 plugin 目录）。shell 直调本地 CLI 是默认能力，官方机制（AGENTS.md/skills）明确支持用它指引 agent 用命令行工具。→ 详见第 1 节。
2. **CLI 先行成立；MCP 何时补**：CLI 先行与原调研 6.2 节判断继续成立，且本次核实新增了两个「以后补 MCP」的增强理由——MCP 工具带 JSON Schema 自动进入 Codex 工具列表并有 per-tool 审批模式（`auto/prompt/writes/approve`）与 destructive 注解联动；MCP 连接可打包进官方 plugin 目录分发。补 MCP 的合理时点：capability registry 稳定、且想要「零 AGENTS.md 依赖的工具发现 + 细粒度审批 + plugin 分发面」时。→ 第 1、4 节。
3. **审批落在哪层**：双层。Codex 层管「这条命令/这个工具能不能跑」（sandbox + approval + rules prefix_rule 信任列表，用户可一次性把我们的 CLI 加白）；宿主层管「dangerous 能力的最终确认」——因为 Codex 侧审批可被用户配置整体关闭（`approval_policy="never"`、`danger-full-access`、allow 规则），MCP 规范也明确注解只是 hint、不可作为安全依据，所以 dangerous 级能力的确认必须由宿主 GUI 出面（out-of-band），CLI 自身不做交互式确认（无 TTY 下会挂死 agent）。→ 第 2、5 节。
4. **对 Electron-vs-Swift 的实质影响**：方向反转本身利好 Swift 路线——V1 不再内嵌 Codex，原 Swift 最大逆风项（官方 SDK 矩阵无 Swift，见 swift-mac-route §3）从 V1 关键路径上移除；我们从「实现 Codex 客户端」变成「提供被调用面（CLI/MCP server）」。远期 MCP adapter 上语言差仍是事实：MCP TypeScript SDK 为 Tier 1（活跃到昨日），Swift SDK 虽官方但 Tier 3「Experimental」（0.12.1，2026-05-07 后无 release）；但 MCP server 是独立小进程，即便宿主选 Swift 也可用 TS sidecar 或由 CLI 层承担，不构成对宿主语言的硬约束。**【推断】** → 第 4 节。
5. **文档核不动、必须 spike 实测的问题**：见第 7 节清单（最关键一条：workspace-write 沙箱下我们 CLI 与宿主的本地 IPC 是否被网络封锁拦截，决定每次调用是否触发 escalation 弹窗）。

---

## 1. Codex 侧接入路径盘点

### 1.1 官方提供的机制全景

**事实**（[Customization overview](https://learn.chatgpt.com/docs/customization/overview)）：Codex 官方customization 文档枚举的机制为：AGENTS.md（"persistent instructions"）、Memories、Skills（"reusable workflows and domain expertise"）、MCP（"access to external tools and shared systems"）、Subagents。其中官方「何时用 MCP」的表述是：**"Codex needs capabilities that live outside the local repo, such as issue trackers, design tools, browsers, or shared documentation systems"**——这是文档中最接近「连接外部应用」的官方定位语句。

### 1.2 shell 直调本地 CLI + AGENTS.md 指引

**事实**：

- AGENTS.md 是开放格式（"A simple, open format for guiding coding agents"），Codex 为首批支持者之一，现由 Linux 基金会下 Agentic AI Foundation 托管，官方推荐内容明确包含 "Build and test commands"；FAQ 确认 agent 会执行文中列出的命令（"Yes—if you list them. The agent will attempt to execute relevant programmatic checks and fix failures before finishing the task."）。[agents.md](https://agents.md/)
- Codex 的 AGENTS.md 发现顺序：每个目录按 `AGENTS.override.md`、`AGENTS.md`、`TEAM_GUIDE.md`、`.agents.md`；作用域含全局 `~/.codex/`（CODEX_HOME）与 git 根到当前目录逐层；自根向下拼接，越近的文件越后出现、覆盖前文；合并大小上限 `project_doc_max_bytes` 默认 32 KiB。[Custom instructions with AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
- 对本机 CLI 的调用没有专门注册机制：CLI 就是 shell 命令，受第 2 节的 sandbox/approval 管辖。

**限制【推断】**：此路径的工具「发现」完全依赖文本指引（AGENTS.md/skill/用户口头）加模型自发探索（跑 `--help` 等；后者无官方文档保证）。全局 `~/.codex/AGENTS.md` 可让指引不依赖用户所在 repo，但要占 32 KiB 预算并需安装器写入。

### 1.3 MCP server（config.toml）

**事实**（[Model Context Protocol](https://learn.chatgpt.com/docs/extend/mcp)、[Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference)）：

- stdio 型：`[mcp_servers.<id>]` 配 `command`/`args`/`env`；streamable HTTP 型：`url` + `bearer_token_env_var`/`http_headers`，OAuth 经 `codex mcp login <server-name>`。配置位置 `~/.codex/config.toml`，也可用项目级 `.codex/config.toml`（仅 trusted 项目），或 Settings UI「MCP servers」添加；composer 内 `/mcp` 可查看已连接 server。
- 工具级控制：`enabled_tools`/`disabled_tools` 白/黑名单；`startup_timeout_sec`（默认 10s）、`tool_timeout_sec`（默认 60s）；审批见第 2.3 节。

### 1.4 Skills 与 Plugins

**事实**：

- Skill = 含 `SKILL.md`（frontmatter 必填 `name`、`description`）的目录，可带 `scripts/`、`references/`、`assets/`；存放位置：repo 层 `.agents/skills`、用户层 `~/.agents/skills`、系统层 `/etc/codex/skills`、OpenAI 内置。显式 `$skill-name` 调用，或按 description 隐式匹配（"ChatGPT or Codex can choose a skill when your task matches the skill `description`"）。[Build skills](https://learn.chatgpt.com/docs/build-skills)
- Plugin = 可安装包，"can include skills, an MCP server, or both"；manifest 为 `.codex-plugin/plugin.json`；"ChatGPT and Codex share one universal plugin directory. Publish a public plugin once to make the same listing discoverable from supported surfaces in both products."；提交前可用 local marketplace 测试。[Plugins](https://learn.chatgpt.com/docs/plugins)、[Build plugins](https://learn.chatgpt.com/docs/build-plugins)

### 1.5 哪条是官方推荐路径（本票核心问题）

**【推断（综合 1.1–1.4 官方定位语句）】**：官方没有一句「第三方本机应用应走 X」的钦点。按官方各机制定位拼出的图景：**MCP 是官方给「repo 之外的外部工具/应用」的标准正门**；**CLI + AGENTS.md/skill 是零配置合法路径**（官方机制明确支持以文档/skill 指引 agent 使用命令行工具）；**plugin 是官方分发载体**，允许我们最终把「skill（教学）+ MCP server（工具面）」一次打包上架。对本项目：V1 以 CLI + 随产品分发的 AGENTS.md 片段/skill 起步完全站得住；MCP 作为 V2 正门补齐后可经 plugin 目录获得分发面。

## 2. 审批与沙箱行为

### 2.1 沙箱模型

**事实**（[Sandbox](https://learn.chatgpt.com/docs/sandboxing)、[Permissions](https://learn.chatgpt.com/docs/permissions)、[Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference)）：

- `sandbox_mode`：`read-only` / `workspace-write`（本地默认低摩擦模式）/ `danger-full-access`（"removes the filesystem and network boundaries"）。macOS 实现："On macOS, sandboxing works out of the box using the built-in Seatbelt framework."
- workspace-write 下**网络默认关闭**：`[sandbox_workspace_write] network_access`（布尔，"Allow outbound network access inside the workspace-write sandbox"）；新版 permissions 配置中网络需显式开启且按域名放行（"If there are no `allow` entries, domain requests are blocked"）。可写根经 `writable_roots` 扩展。
- 新的 `[permissions.<name>]` 档位体系（`:read-only`/`:workspace`/`:danger-full-access` 与自定义档），经 `default_permissions` 选择；旧 `sandbox_mode`/`--sandbox` 仍生效。

### 2.2 审批模型与「把特定 CLI 加入信任列表」

**事实**（[Agent approvals & security](https://learn.chatgpt.com/docs/agent-approvals-security)、[Rules](https://learn.chatgpt.com/docs/agent-configuration/rules)、[Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference)）：

- `approval_policy`：`untrusted`（只自动跑已知安全的读操作）/ `on-request`（版本管理目录默认）/ `never`，以及细粒度对象形式 `{ granular = { sandbox_approval, rules, mcp_elicitations, request_permissions, skill_approval } }`。触发弹窗的典型动作：改工作区外文件、需要网络的命令、离开沙箱、信任集之外的命令。
- **信任列表机制 = Rules**：`.rules` 文件（Starlark 语法）放在各配置层的 `rules/` 目录（用户层 `~/.codex/rules/default.rules`，项目层 `<repo>/.codex/rules/` 仅 trusted 项目加载）。`prefix_rule(pattern=..., decision=...)`，decision 三值——**allow：“Run the command outside the sandbox without prompting.”**；prompt：逐次询问；forbidden：直接拒绝。多规则命中取最严（forbidden > prompt > allow），拆分复合命令逐段判定（防 `git add . && rm -rf /` 搭车）。
- **Smart approvals（默认开启）会在 escalation 时主动建议 prefix_rule**："When Smart approvals are enabled (the default), Codex may propose a `prefix_rule` for you during escalation requests."——即用户第一次批准我们 CLI 时就会被建议「以后自动允许」。管理员可经 `requirements.toml` 强制限制性规则（用户配置不能放松）。
- 审批可被整体关闭：`approval_policy = "never"` 或 `danger-full-access`。
- 非交互 `codex exec` 默认 read-only 沙箱（"By default, `codex exec` runs in a read-only sandbox."），可 `--sandbox workspace-write`/`danger-full-access` 放宽。[Non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)

### 2.3 MCP 工具的审批

**事实**（[MCP](https://learn.chatgpt.com/docs/extend/mcp)、[Agent approvals & security](https://learn.chatgpt.com/docs/agent-approvals-security)）：MCP server 可配 `default_tools_approval_mode`（`auto`/`prompt`/`writes`（非只读工具询问）/`approve`）并按 `[mcp_servers.<id>.tools.<tool>] approval_mode` 逐工具覆盖；且 **"Destructive app/MCP tool calls always require approval when the tool advertises a destructive annotation"**——MCP 的 destructive 注解直接接入 Codex 审批。另有 `approvals_reviewer = "auto_review"` 可让 reviewer agent 预审 escalation。

### 2.4 对我们 CLI 的落地含义

**【推断】**：

- 用户预配置量：**零配置即可用**（走默认 escalation 弹窗）；一次批准 + 接受 Smart approvals 建议的 prefix_rule（或我们文档给出 `~/.codex/rules/` 片段）后，`app ...` 前缀命令免弹窗。
- 每次调用弹什么取决于一件文档核不动的事：我们 CLI 与宿主走本地 IPC（unix socket），**workspace-write 的网络封锁是否拦截 unix domain socket / localhost 连接未见官方文档说明**。若拦截，则每次调用都是一次 sandbox escalation（需审批或 allow 规则）；若不拦截，普通调用可在沙箱内直通。→ spike 清单第 1 条。
- rules 的 allow 含义是「**沙箱外**免弹窗运行」——被 allow 的我们的 CLI 将不受 Seatbelt 限制，这反而绕开了 IPC 是否被拦的问题，但也意味着 Codex 层此后对该前缀不再有任何拦截，dangerous 兜底必须在宿主层（第 5 节）。

## 3. Agent-first CLI 设计的事实基础

### 3.1 Codex 如何“学会”一个 CLI

**事实**：文档层面可确认的发现渠道有两条——AGENTS.md 常驻指令（官方推荐写入 build/test 等命令，agent 会执行；32 KiB 预算，见 1.2）与 skill 隐式触发（按 description 匹配，官方要求 "write concise descriptions with clear scope and boundaries. Front-load the key use case and trigger words"，见 1.4）。**Codex 会不会自发跑 `--help` 探索未见文档承诺【推断：这是模型行为而非机制保证，不应把可用性押在它上面】。**

### 3.2 agent-friendly CLI 先例：gh

**事实**（[gh formatting](https://cli.github.com/manual/gh_help_formatting)、[gh exit codes](https://cli.github.com/manual/gh_help_exit-codes)、[gh repo delete](https://cli.github.com/manual/gh_repo_delete)）：

- 机器输出三件套：`--json`（逗号分隔字段列表；**省略参数即列出全部可用字段**——自描述）、`--jq`、`--template`；官方明确定位为脚本消费（"as input to another command line script"）。
- 文档化 exit code：0 成功 / 1 失败 / 2 取消 / 4 需要认证，并提醒按命令查详情。
- 破坏性操作先例：`gh repo delete` 交互下强制确认；非交互/自动化必须显式 `--yes`（"Confirm deletion without prompting"），且删除当前仓库时 `--yes` 被忽略、必须显式给出仓库名——即「破坏性动作要求显式、具名的确认物」。

### 3.3 对原 6.1 设计（`app capabilities list/describe/call --json`）的评估

**事实基线**：原设计见 `docs/research/platform-framework-research.md` §6.1（stdout 只出结果 JSON、诊断走 stderr、稳定 exit code、结构化 `host_unavailable`、幂等键与 invocation receipt）。该骨架与 MCP 工具模型同构——MCP 工具定义要求 `name`/`description`/`inputSchema`（JSON Schema，必填）、可选 `outputSchema` 与结构化结果 `structuredContent`，发现走 `tools/list`（[MCP spec Tools, 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)）。`list/describe/call` 正是 `tools/list` + schema + `tools/call` 的 CLI 化。**【评估：结构对 agent 消费已是正确形状】**

**要补的点【建议】**：

1. **命名一致性**：原文混用 `app capabilities describe` 与 `app capability call`，统一为一个名词（agent 对不一致的动词/名词组合更易出错）。
2. **`describe` 直接输出 JSON Schema**（input/output 两份，语义对齐 MCP `inputSchema`/`outputSchema`）——未来 MCP adapter 可直通零翻译，也让 Codex 在 CLI 路径就吃到 schema。
3. **永不交互阻塞**：无 TTY 时禁止任何 stdin 等待（Codex 在沙箱内非交互执行命令，交互确认会挂死直至超时）；确认语义全部改为显式 flag（gh `--yes` 先例）或宿主 GUI（第 5 节）。
4. **错误面向 agent 自纠**：错误 JSON 带稳定 `code` + 可执行的下一步提示；对应 MCP 对 execution error 的定位（"actionable feedback that language models can use to self-correct and retry with adjusted parameters"）。
5. **文档化 exit code 表**（gh 先例：0/1/2/4 级别的小表），并区分「宿主未运行」「能力不存在」「权限被拒」「宿主拒绝确认」。
6. **自描述入口**：`--json` 无参列字段（gh 先例）或 `app capabilities --help` 输出面向 agent 的紧凑用法；输出保持精简（AGENTS.md 32 KiB 预算 + 命令输出进上下文都有成本）。
7. **随产品分发指引物**：提供 `app integrations codex` 之类的安装命令，生成/更新全局 AGENTS.md 片段与（可选）`~/.agents/skills/<app>/SKILL.md`、`~/.codex/rules/` 建议片段——把「被发现」做成产品动作而不是用户作业。

## 4. MCP 路线现状核查

### 4.1 规范与 SDK 成熟度

**事实**：

- 现行规范版本 **2025-11-25**（以 schema.ts 为权威）。[MCP specification latest](https://modelcontextprotocol.io/specification/latest)
- 官方 SDK 分层制（tiering，2026-02-23 起发布）：**Tier 1（完整实现+100% conformance+2 工作日 triage+稳定版）：TypeScript、Python、C#、Go**；Tier 2：Java、Rust；**Tier 3（"Experimental, partially implemented, or specialized SDKs"，无时限承诺）：Swift、Ruby、PHP、Kotlin**。[SDKs](https://modelcontextprotocol.io/docs/sdk)、[SDK Tiering System](https://modelcontextprotocol.io/community/sdk-tiers)
- **Swift SDK 是官方的**（modelcontextprotocol org 下，自述 "The official Swift SDK for Model Context Protocol servers and clients"），未归档；但处于 Tier 3、无 1.0（最新 release 0.12.1，2026-05-07；此前 0.12.0 2026-03-24、0.11.0 2026-02-19），截至 2026-07-28 已约 2.5 个月无 push，open issues 88。[swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)（活跃度数据来自 GitHub API，2026-07-28 取样）
- TypeScript SDK：Tier 1，push 活跃至 2026-07-27（取样前一日），~13.0k stars。[typescript-sdk](https://github.com/modelcontextprotocol/typescript-sdk)

### 4.2 Codex 侧配置 MCP server 的用户成本

**事实**：见 1.3/2.3——一段 `config.toml` 或 Settings UI 表单；stdio server 由 Codex 拉起子进程（`command`），无需用户常驻维护；审批粒度可到单工具。**【推断】成本低但非零：仍是「装完应用后还要动 Codex 配置」的一步，不如 CLI 的零配置；plugin 目录上架后可降为一次安装动作。**

### 4.3 CLI vs MCP 的工具发现质量（文档层面能核到的）

**事实层**：MCP 工具连同 JSON Schema 经 `tools/list` 自动进入会话（配置一次、每会话可用，无需占 AGENTS.md 预算），并接入 per-tool 审批与 destructive 注解（2.3）；CLI 的发现依赖文本指引与模型探索（3.1），审批粒度只有命令前缀（prefix_rule 的 pattern 是 token 前缀匹配，无参数语义）。**【推断】文档层面可下的结论：MCP 在「发现的确定性」与「审批的语义粒度」两个维度优于 CLI；但两者调用成功率、token 成本、模型实际使用质量文档核不动 → spike 清单第 2 条。** 这与原 6.2 节「V1 CLI、registry 稳定后薄 MCP adapter」的判断相容，并新增 per-tool 审批与 plugin 分发两个补 MCP 的理由。

### 4.4 对技术栈票的输入

**【推断】**：V1（纯 CLI）两栈无差。远期 MCP adapter：Electron/Node 侧有 Tier 1 SDK；Swift 侧要么用 Tier 3 SDK（官方但实验级、无时限承诺）要么自实现（协议为 JSON-RPC，参照 swift-mac-route §3.2 的评估逻辑，传输层薄、类型面是持续成本）。但 MCP server 是独立小进程：宿主选 Swift 时 adapter 可以是 Node sidecar 或未来用任何 Tier 1 语言实现的 CLI 附属二进制——**语言差是实质但可绕，不应单独左右 Electron-vs-Swift 决定**。更大的影响是方向性的：V1 不内嵌 Codex 后，swift-mac-route §3 所述「官方 SDK 无 Swift」逆风从 V1 关键路径移除。

## 5. dangerous 能力的 agent 路径

**事实层**：

- Codex 层已有的闸门：sandbox + approval + rules（第 2 节）；MCP destructive 注解必弹审批（2.3）；auto_review 预审（2.2）。但这些全部可被用户配置削平（`never`/`danger-full-access`/allow 规则）。
- MCP 规范的安全立场：**"Hosts must obtain explicit user consent before invoking any tool"**；tools 章节警告 "there **SHOULD** always be a human in the loop with the ability to deny tool invocations"、客户端 SHOULD "Prompt for user confirmation on sensitive operations"；同时**注解不可信**——"all properties in ToolAnnotations are **hints**. … Clients should never make tool use decisions based on ToolAnnotations received from untrusted servers."（server 侧则 MUST "Implement proper access controls"）。[MCP spec 2025-11-25](https://modelcontextprotocol.io/specification/latest)、[Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)、[schema.ts ToolAnnotations](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-11-25/schema.ts)
- CLI 先例：gh 对破坏性操作要求交互确认或显式 `--yes`（3.2）。
- macOS 系统层本身对改系统代理另有一道闸：`networksetup` 需要 admin 权限（已核实于 swift-mac-route §4，不重复展开）。

**结论【推断】**：**dangerous 级能力的最终确认必须落在宿主层，Codex 层审批只能当作加分不能当作依赖。** 理由：(a) Codex 审批可被配置绕过；(b) agent 驱动下 CLI 的任何 `--yes` 类 flag 都会被模型自己传上，等于不设防；(c) CLI 交互确认在无 TTY 环境会挂死（3.3）。对能力注册表分级的含义：

- **safe（只读）**：CLI/MCP 直通；未来 MCP 面标 `readOnlyHint: true`。
- **normal（可逆写）**：依赖 Codex 层审批 + 幂等键/receipt 兜底重放；MCP 面用 `writes` 审批模式承接。
- **dangerous（系统级/难逆）**：CLI 只提交意图，宿主 GUI 弹确认（out-of-band、带超时与明确拒绝语义、CLI 返回 `confirmation_denied`/`confirmation_timeout` 结构化错误）；可选「会话内授权/记住本次选择」由宿主管理；未来 MCP 面标 `destructiveHint: true` 以触发 Codex 必弹审批作为第一道闸。宿主确认弹窗需防「agent 替用户点」的社工话术，展示动作的真实参数（MCP 客户端指引同款逻辑："Show tool inputs to the user before calling the server"）。

## 6. 对首批插件的含义（整体为【建议】，供「代理插件 V1 范围」票与后续 spec 消费）

在 agent-first 准则（每个能力：稳定 ID、JSON Schema 输入输出、风险级、幂等键、receipt）下的能力面样例：

- **提醒（agent 价值最高，天然结构化）**：`reminder.create`（title/when/repeat）、`reminder.list`、`reminder.complete`、`reminder.delete`（normal；delete 可按批量阈值升 dangerous）。典型指令「明早九点提醒我交周报」可完全走 CLI 单次调用。
- **宠物（GUI 中心，agent 面最小化）**：`pet.status`（safe，读状态/心情）、`pet.interact`（normal，投喂/逗玩，幂等键防连发）。定位是趣味出口（如 Codex 完成长任务后调 `pet.celebrate`），不为 agent 扩表面。
- **代理 / mihomo（示例场景主角，分级最全）**：
  - safe：`proxy.status`（当前模式/节点/延迟）、`proxy.nodes.list`（组与节点，JSON）。
  - normal：`proxy.node.select --group <g> --node <n>`、`proxy.mode.set rule|global|direct`（可逆、影响仅本机流量走向）。
  - dangerous：`proxy.system.enable|disable`（改 macOS 系统代理，触宿主 GUI 确认；系统层另有 admin 闸，见 §5）、`proxy.config.apply`（换订阅/改配置文件）。
  - 示例流（用户对 Codex 说「帮我把代理切到香港节点并开系统代理」）：Codex 读 AGENTS.md 片段 → `app capabilities list --json` → `proxy.nodes.list` → `proxy.node.select`（Codex 层 escalation 或 prefix_rule 放行）→ `proxy.system.enable` → 宿主 GUI 弹确认 → CLI 返回 receipt，Codex 汇报结果。
- 三个插件共同验证的准则：能力面小而稳定、describe 即 schema、dangerous 必经宿主确认——这正是未来 MCP adapter 可以机械翻译的形状。

## 7. 文档核不动、必须留到 spike 实测的问题

1. **【最关键】workspace-write 沙箱内我们 CLI ↔ 宿主的本地 IPC（unix socket/localhost）是否被网络封锁拦截**——Seatbelt 规则细节官方未文档化。结果决定：普通调用能否沙箱内直通，还是每次 escalation（从而 prefix_rule allow 是否为体验必需）。
2. CLI vs MCP 的实际发现/调用成功率与 token 成本对比（原 6.2「仍需实测」项，文档层只能核到 4.3 的定性结论）。
3. Smart approvals 对我们 CLI 建议 prefix_rule 的实际触发与 pattern 粒度是否如文档描述。
4. `codex exec` 非交互模式下 escalation 的具体行为（文档只讲默认 read-only 沙箱，未讲无法弹窗时失败/跳过的语义）。
5. 全局 AGENTS.md 片段 + skill 的实际命中率（如「帮我切代理节点」是否稳定触发我们的指引）与 32 KiB 预算内的篇幅控制。
6. MCP Swift SDK 的实际质量（Tier 3 无 conformance 门槛，需跑官方 conformance 套件实测）——仅当技术栈票选 Swift 且决定不走 sidecar 时才需要。

## 附：一手来源清单

- Codex：[Customization overview](https://learn.chatgpt.com/docs/customization/overview) · [AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md) · [Build skills](https://learn.chatgpt.com/docs/build-skills) · [Plugins](https://learn.chatgpt.com/docs/plugins) / [Build plugins](https://learn.chatgpt.com/docs/build-plugins) · [MCP](https://learn.chatgpt.com/docs/extend/mcp) · [Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference) · [Sandbox](https://learn.chatgpt.com/docs/sandboxing) · [Agent approvals & security](https://learn.chatgpt.com/docs/agent-approvals-security) · [Rules](https://learn.chatgpt.com/docs/agent-configuration/rules) · [Permissions](https://learn.chatgpt.com/docs/permissions) · [Non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)
- AGENTS.md 开放格式：[agents.md](https://agents.md/)
- MCP：[Specification（2025-11-25）](https://modelcontextprotocol.io/specification/latest) · [Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) · [schema.ts](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2025-11-25/schema.ts) · [SDKs](https://modelcontextprotocol.io/docs/sdk) · [SDK Tiering](https://modelcontextprotocol.io/community/sdk-tiers) · [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) · [typescript-sdk](https://github.com/modelcontextprotocol/typescript-sdk)（活跃度取样：GitHub API，2026-07-28）
- gh CLI：[formatting](https://cli.github.com/manual/gh_help_formatting) · [exit codes](https://cli.github.com/manual/gh_help_exit-codes) · [repo delete](https://cli.github.com/manual/gh_repo_delete)
- 仓库内交叉引用：`docs/research/platform-framework-research.md` §6（原 CLI 设计与 CLI-vs-MCP 基线）、`docs/research/swift-mac-route.md` §3（codex app-server/`codex exec --json` 已核事实）、§4（networksetup 权限）
