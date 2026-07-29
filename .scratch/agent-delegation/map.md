# Map: 宿主调用本地 agent 适配层(agent-delegation)

Label: wayfinder:map
创建:2026-07-29(建图 = multica 参考调研 + batch-grill 四轮批量面试)

## Destination

一份 ready-for-agent 的《宿主调用本地 agent 适配层》spec:宿主可把单次任务委托给本地 coding agent(Codex/Claude Code)执行,验收场景为「查问题(诊断报告)」与「帮我改 mihomo 配置」。图走完 = 没有决策留在 spec 之前,可直接进 /to-spec + 拆票实施。

## Notes

- **并行红线**:本效应作为独立模块与 v1-core-proxy 16 票并行落地。新 target `AAAgentCore`(纯逻辑)只依赖 `AAContracts`;与宿主的接线(注册表/GUI)是后置薄 glue,不踩 16 票施工面。
- **验证环**:Xcode 仍缺席(CLT 损坏),一切验证走 vfsoverlay 直编 + assert 脚本;spike 只用现成 agent 二进制,不需要 Swift 工具链。本机:`claude` 2.1.212(PATH)、`codex` 0.146.0-alpha(`~/.codex/plugins/.plugin-appserver/codex`,不在 PATH)。
- **参考资产**:[multica 适配层架构还原报告](research/multica-adapter-analysis.md)(全部结论带 file:line,借鉴与踩坑清单在第 8 节)。
- **产出语言**:全中文;对 agent 的机器面为英文 JSON。
- 逐票一个 session;spike 票可 AFK 驱动,03 票 HITL。

## Decisions so far

<!-- 建图期批量面试(2026-07-29,四轮)一次性裁决,记于此;此后的决议由票据承载 -->

- **北极星**:先做宿主委托本身(菜单栏只是 UI 细节),第二步插件经宿主委托;调度台/定时触发后置。
- **验收场景**:a「查问题」诊断报告型 + b「帮我改 mihomo 配置」;b 天然与平台 dangerous 档交叉,是审批模型的试金石。
- **首批 agent**:Codex + Claude Code(两个异构实现逼出真适配层);更多家 out of scope。
- **任务模型**:单次 job(提交→流式进度→终态+产物);多轮会话不做——想多轮的用户回到 agent 侧,由 agent 经 `aa` 反向调用平台(v1 已有方向)。
- **入口**:试驾 CLI 先行,宿主 GUI 接线后置。
- **观测面**:状态查询 + 取消 + 完成通知三件套;过程流全量落日志文件,V1 无 GUI 实时滚屏。
- **agent 选择**:委托时显式指定 + 全局默认;按内容自动路由 out of scope。
- **模型选择**:委托参数可选 `model` 字段,原生模型名透传(学 multica 拒绝跨厂商拉平);传错由 CLI 报错如实回传;模型目录/自省进 fog。
- **审批模型(双层信任)**:OS/文件层学 multica——委托即授权,agent 在任务工作目录内以 bypass 模式全权执行;平台信任面必须经 `aa`——dangerous 能力自动触发宿主 GUI 确认、CLI 收 pending 不挂起(v1 已建机制,恰好补上 multica 缺失的审批环)。配套:禁用 agent 的「问人」工具(疑问写进 report.md);blocked-args 黑名单防止委托参数把 bypass 改回交互模式。
- **通信协议**:两家最简 headless 面——`claude -p --output-format stream-json` + `codex exec --json`;Swift 手写薄协议客户端,零 SDK、零 PTY;不采 ACP(碎片化实证见报告第 2 节);避开 codex app-server(其复杂度服务多轮 thread 管理,单次 job 用不上)。
- **消息模型**:借鉴 multica 6 型统一消息(text/thinking/tool-use/tool-result/status/error/log),`CallID` 全链保留(修 multica 有损点);原始 NDJSON 全量落任务工作区(排障真相源),归一化消息只服务状态判定与报告生成。
- **进程生命周期**:单发子进程、不常驻;取消 = 进程组 SIGTERM→宽限→SIGKILL;双看门狗(消息静默 + 工具在途放宽);进程执行收进 AAAgentCore 自己的 Port(测试打 Fake,试驾 CLI 真实现,将来桥宿主 ProcessPort)。
- **会话续接**:V1 不做 resume;session-id 拿到就记进任务工作区元数据(为将来留门);失败重跑一律全新会话。
- **任务产物**:每次委托一个任务工作区目录,内部结构单独设计(03 票,可维护性为纲)。
- [03 任务工作区目录结构](issues/03-task-workspace-design.md) — 已定稿:根 `~/.aa/agent-tasks/`,目录名即 task-id(时间+slug+hex4);meta.json 单一真相源(schema_version 演进);raw/normalized 双日志流永不互写;主产物 `report.html`(agent 直写自包含 HTML,文本兜底,通知直开);手动 prune 只删终态;详见[结构提案](research/task-workspace-proposal.md)。
- [01 Claude headless spike](issues/01-spike-claude-headless.md) — 实测(8 次真调, [findings](research/spike-claude-headless/findings.md)):5 型顶层事件(`tool_result` 顶层 type 竟是 `user`);`session_id` 首条 `system/init` 即定;stream-json 写完 prompt **进程不自退**,需显式关 stdin;bypass 是**能力开关非安全开关且仅两档**(全放行/无差别拒,无「仅 cwd」中间档);不加 bypass = 同步自动拒(合成 `is_error` tool_result + `permission_denials[]`),**非挂起**;`control_request` 8 次零命中(与 multica 报告分歧,判为版本漂移,V1 免实现留兜底);中断进程组 SIGTERM <1s 净退 exit 143,但**先补 `[Request interrupted]` 再落 result**,drain 要读到底;终态**不能只看 subtype**(model 错时 exit1 但 subtype 仍 success),须联合 `is_error`/`terminal_reason`;**cwd 非安全边界**(`../` 与 `/tmp` 越界写全成功);无头子进程**默认继承宿主机全部插件/技能面**,须 `--tools`/`--strict-mcp-config` 收紧。
- [02 Codex exec spike](issues/02-spike-codex-exec.md) — 实测(8 次真调, [findings](research/spike-codex-exec/findings.md)):扁平 NDJSON(`thread.started`/`turn.*`/`item.*`);**session id 就是首行 `thread.started.thread_id`**(不必等文件落盘,比 multica 等 rollout 简单);**每任务独立 `$CODEX_HOME`(只拷 `auth.json` 不拷 `config.toml`)隔离实测可行且 fail-closed**(缺 auth 直接 401 不回退真身份)——委托 codex 不污染用户全局配置的姿态确定;`sandbox_mode` 走 `-s` flag 或 `-c` 覆盖;**审批被拒是「静默空气墙」**(连 `item.started` 都不出现,无可编程识别的拒绝事件,只能事后 diff FS);**workspace-write 真的拦 cwd 上级越界写**(codex 有真沙箱);中断进程组 SIGTERM 整树瞬死 exit -15,**中断不产终态 JSON**须适配层自标 aborted;失败 exit1 错因需 parse 双层编码 JSON,**stderr 有 ERROR 非失败判据**(alpha 构建噪音);**exec 无条件读 stdin 须显式 `stdin=/dev/null`** 否则静默挂起;失败网络重连可达 40+s,看门狗留余量。
- **⚠️ 两家三处行为不对称(适配层核心存在理由,须写进 spec 约束)**:①**沙箱边界**——Codex `workspace-write` 有真 OS 沙箱拦越界写,Claude cwd 完全不设防;②**操作被拒信号**——Claude 合成 `is_error` tool_result(可识别),Codex 静默无事件(只能事后 diff FS),归一化层须专门抹平这个不对称;③**终态语义**——Claude 须联合多字段判定、Codex 错因藏在双层编码 JSON 里,退出码都不直接携带错因。→ 双层信任模型不能对两家用同一套假设:OS/文件层「委托即授权」对 Claude 需额外 OS 级隔离(sandbox-exec)或在 spec 显式声明「任务目录外不设防」的信任假设,对 Codex 可借其原生 sandbox_mode。

- [04 产出适配层 spec](issues/04-write-spec.md) — **图目的地达成**:[spec.md](spec.md) 定稿 + /to-tickets 拆出 7 张实施票 `impl/01–07`(tracer-bullet)。依赖图:01 骨架→02/03/04/06 并行→05→07 收口。两处 spec 收敛:验收 b 用 demo 能力演示双层信任(不硬绑未落地的 mihomo 09/10 写能力)、测试走 TestReport 同构(禁 import Testing,随 11 票迁 swift-testing)。骨架事实:AAAgentCore 自有 AgentPort(样板 SystemProcessPort 反孤儿)。

## 实施进度(impl/01–07,分支 `worktree-research-next`)

每票循环:主会话读票定设计 → 全新 Opus 子代理机械落地(不 commit / 不自审)→ **主会话独立重跑 `bash Scripts/check.sh` 复验** → Fable 5 双轴 code-review(Standards + Spec)→ 主会话修 → 提交。

- ✅ **01** `e350204` 骨架:`AgentPort` + 6 型统一消息 + `FakeAgentPort` + 门禁接线(PASS=148)。CR 修:删死 import。
- ✅ **02** `1c0d6c9` Claude adapter 归一化(PASS=170,44 条断言)。CR 修:**删掉 aborted 判定里的 `|| subtype == "error_during_execution"`**(两轴独立同结论:该支八样本零独立覆盖,留着会把真失败伪装成「被取消」还凭空注入 interrupted 消息,失败被静音比误报失败更糟);终局答复从消息流挪进终态 `finalText`(`result.result` 实测是最后一条 assistant text 的逐字回显,产成消息会让报告打印两遍)。
- ✅ **03** `fc0aa1a` Codex adapter 归一化(PASS=193,58 条断言)。CR 修:`JSONValue` 取值便利上提为模块共用(`member(_:)` 的「缺键与显式 null 一视同仁」是两家各自正确性的前提,各留一份会被单边修改静默分叉);`AgentAdapterOutput` 挪成独立文件;改掉一句被 exec7 反证的注释。
- ✅ **04** 任务状态机 + 工作区落盘(139 条断言)。**两轴独立收敛到同一个 🔴**:`orphaned` 是「按 pid 死了」**猜**出来的推测性终态,却被冻成不可反证 —— agent 子进程退出后、run 进程还在 drain 的窗口里,另一个终端跑 `list` 触发孤儿扫描就会抢标 `orphaned`,随后 run 进程 `finish(completed)` 抛错,**一次成功的任务被永久记成孤儿且报告缺失**。修法:放行 `orphaned → 证据终态`(单向,证据纠正推测)+ `finish` 同态幂等(顺带自愈「meta 已终态但 report 写失败」的死角)。另修:`finalText` 为 nil 时从 normalized 取最后一条 text(兑现 02/03 写下的承诺)、taskID 形状校验(防 07 把用户输入的 `../../x` 拼出 root)、meta 写侧保留未知字段、3d 门禁 grep 扩到 SDK/PluginProxy。
- ⬜ **05** 看门狗/取消 · ⬜ **06** SystemAgentPort 真实现 · ⬜ **07** 试驾 CLI 收口

**落地阶段新增的实测事实(回填给后续票)**:
- Codex 的 `item.*` 事件**不保证被 turn 边界包住**(exec6 的 item error 出现在 `turn.started` 之前)——状态机不得拿 turn 边界当消息闸门。
- Codex 中断/硬超时时事件流**没有终态行**,adapter 诚实交回 `terminal == nil` —— job 终态必须由退出码 + 取消记账决定,不能把任务挂在 running。

## Not yet specified

- **插件经宿主委托**(北极星第二步):插件侧调用契约、发起方确认强度(插件发起 ≈ 拉起任意代码执行,倾向 dangerous 档)、与注册表的关系——等宿主委托 spec 定型后 sharpen。
- **GUI 接线**:菜单栏入口与通知的具体形态——等 12/14 票宿主壳成型。
- **per-op 审批上抛**:把 agent 过程内权限请求异步转发宿主 GUI(multica 明确没做的那块)——双层模型跑通后的 Phase 2 方向。
- **模型目录/CLI 自省**:multica 式 `(provider, executable, version)` 缓存的模型/档位探测。
- **agent 探测与版本兜底**:本机没装/版本过旧的检测与引导(multica MinVersions 类机制)。
- **Claude 侧 OS 级隔离(01 spike 新增)**:Claude cwd 非安全边界,「委托即授权」要真关住任务目录须上 sandbox-exec 或等价手段——V1 是接受「任务目录外不设防」的信任假设并写明,还是上 OS 隔离?spec 阶段(04 票)须裁,可能牵出独立票。
- **被委托 agent 的能力面收紧(01 spike 新增)**:无头 claude 默认继承宿主机全部插件/技能/自定义 agent 面(`Task`/`SendMessage` 等)——委托时该给多大工具面?硬编码最小集 / 按任务声明 / 白名单?这是新的安全维度,04 票 sharpen。

## Out of scope

- 多轮会话/追问——由「用户回 agent 侧,agent 经 `aa` 调平台」承接(v1 方向)。
- 调度台(多 agent 会话管理面板)、定时/事件触发委托——北极星裁决后置。
- 按任务内容自动路由 agent。
- ACP 协议接入;codex app-server 协议。
- Codex/Claude Code 以外的 agent(含 Gemini CLI 等)。
- V1 的会话 resume。
