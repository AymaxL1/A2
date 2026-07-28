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
- **任务产物**:每次委托一个任务工作区目录(如 `~/.aa/agent-tasks/<task-id>/`),`report.md` 为主产物;内部结构单独设计(03 票,可维护性为纲)。

## Not yet specified

- **插件经宿主委托**(北极星第二步):插件侧调用契约、发起方确认强度(插件发起 ≈ 拉起任意代码执行,倾向 dangerous 档)、与注册表的关系——等宿主委托 spec 定型后 sharpen。
- **GUI 接线**:菜单栏入口与通知的具体形态——等 12/14 票宿主壳成型。
- **per-op 审批上抛**:把 agent 过程内权限请求异步转发宿主 GUI(multica 明确没做的那块)——双层模型跑通后的 Phase 2 方向。
- **模型目录/CLI 自省**:multica 式 `(provider, executable, version)` 缓存的模型/档位探测。
- **agent 探测与版本兜底**:本机没装/版本过旧的检测与引导(multica MinVersions 类机制)。

## Out of scope

- 多轮会话/追问——由「用户回 agent 侧,agent 经 `aa` 调平台」承接(v1 方向)。
- 调度台(多 agent 会话管理面板)、定时/事件触发委托——北极星裁决后置。
- 按任务内容自动路由 agent。
- ACP 协议接入;codex app-server 协议。
- Codex/Claude Code 以外的 agent(含 Gemini CLI 等)。
- V1 的会话 resume。
