# Spec:宿主调用本地 agent 适配层(AAAgentCore)

Status: ready-for-agent
**开工前必读**:正文按旧架构写成,先读文末[修订指令(2026-08-04)](#修订指令2026-08-04a2-内核-bin-化)。
创建:2026-07-29(/to-spec 综合 agent-delegation wayfinder 图,无新面试)
决策来源:`.scratch/agent-delegation/map.md`(四轮批量面试 14 项决议)、[multica 适配层调研](research/multica-adapter-analysis.md)、[01 Claude spike](issues/01-spike-claude-headless.md) + [findings](research/spike-claude-headless/findings.md)、[02 Codex spike](issues/02-spike-codex-exec.md) + [findings](research/spike-codex-exec/findings.md)、[03 任务工作区结构](research/task-workspace-proposal.md)。

## Problem Statement

我的宿主平台(PROJECT_AA)已经能让外部 agent 经 `aa` 操作平台能力(v1-core-proxy 方向:agent → aa → 平台)。但我还想要反方向的能力:**让宿主把一件事委托给本地 coding agent 去替我干**——「帮我查当前网络为什么不通,给我一份结论」「帮我改 mihomo 配置」——全程不用我盯着,干完通知我看结果。

本地 coding agent 有很多家(Codex、Claude Code、Gemini CLI、Cursor……),每家的启动方式、事件流格式、审批姿态、沙箱行为、终态语义都不一样。我不想让宿主对某一家硬编码;我要一层**适配层**,把「委托一个任务给某个 agent 并把它跑完」这件事归一化成平台内部统一的模型,这样宿主(以及将来的插件)只面对一个稳定接口,底下换哪家 agent 都行。

## Solution

新建一个纯逻辑模块 **AAAgentCore**,作为「宿主调用本地 agent」的适配层。它把一次委托建模成一个**单次任务(job)**:提交任务(prompt + agent + 可选 model + 工作目录)→ 适配层拉起对应 agent 的 headless 进程 → 流式读取并归一化其事件 → 落盘到任务工作区 → 产出终态与一份 HTML 报告 → 通知宿主。

适配层对每家 agent 有一个 **adapter**,把该家 CLI 的原生事件流翻译成平台统一的 6 型消息模型;首批实现 Codex 与 Claude Code 两家(两个异构实现,逼出真适配层而非硬编码)。一切子进程副作用压到 AAAgentCore 自己的 **AgentPort** 之后,使域逻辑(任务状态机、归一化、生命周期、看门狗)可在假件上纯逻辑测试。

**双层信任**是本模块的安全骨架:OS/文件层「委托即授权」(agent 在任务工作目录内以 bypass/sandbox 模式全权执行,不中途等人);而任何触及**平台信任面**的动作(改系统代理、换订阅源)仍必须经 `aa` → 现有能力注册表 → dangerous 档宿主 GUI 确认,agent 无法绕过。这恰好补上参考项目 multica 整体缺失的那一环(multica 只有全自动、无平台级审批面)。

V1 的委托入口是一个**试驾 CLI**(独立可执行,不碰现有 `aa`/宿主),宿主 GUI 接线后置。验收 = 两个真实场景:a「查问题」诊断报告、b「改配置」触发双层信任(普通改动零打断,踩 dangerous 弹宿主确认)。

## User Stories

### 委托与执行

1. 作为宿主用户,我想把一个自包含的诊断任务(「查网络为什么不通」)委托给本地 agent,让它只读地跑诊断命令并给我一份结论,以便我不用自己敲一堆命令。
2. 作为宿主用户,我想委托 agent「帮我改 mihomo 配置」这类有副作用的任务,让普通可逆改动零打断完成,以便日常调整不用亲自动手。
3. 作为宿主用户,我想在委托时显式指定用哪个 agent(codex 或 claude),并在不指定时落到一个全局默认 agent,以便按任务挑选我信任的执行者。
4. 作为宿主用户,我想在委托时可选地指定模型(如 `claude-opus-4-8`、codex 的某档),用原生模型名直接透传,以便按任务难度选算力而不被适配层的抽象拉平。
5. 作为宿主用户,我想让委托是单次任务:提交→跑→终态,不要多轮对话,以便语义简单可判定;需要多轮追问时我会回到 agent 侧自己开会话。
6. 作为宿主用户,我想为每次委托指定一个工作目录(缺省用任务工作区内的 `work/`),以便任务 a 只读某处、任务 b 能改到该改的地方。

### 观测与控制

7. 作为宿主用户,我想随时查询一个任务的状态(pending/running/completed/failed/cancelled/timeout),以便知道它跑到哪了。
8. 作为宿主用户,我想取消一个正在跑的任务,让适配层干净地杀掉 agent 进程树、不留孤儿,以便我改主意时能立即止住。
9. 作为宿主用户,我想在任务完成时收到通知,点开直接看到一份 HTML 报告(agent 的结论),以便一眼拿到产出而不必翻日志。
10. 作为宿主用户,我想让每次委托的全过程原始事件流全量落盘成日志文件,以便任务出问题时我能 `tail` 原始记录排障。
11. 作为宿主用户,我想让任务工作区目录堆积时能手动清理(按龄/按量),且清理永不误删正在跑的任务,以便磁盘可控又不丢正在进行的工作。

### 双层信任

12. 作为宿主用户,我想让 agent 在它的任务工作目录内全权执行、不中途停下来等我审批,以便委托能真正全自动跑完(spike 实证:不给 bypass,agent 不是等我而是直接自动拒绝工具调用,任务残废)。
13. 作为宿主用户,我想让 agent 一旦试图触及平台信任面(改系统代理、换订阅源),就必须经 `aa` → 注册表 → dangerous 宿主 GUI 确认,agent 和 CLI 都无法绕过,以便任何自动化都改不了我的信任面而不经过我。
14. 作为宿主用户,我想让被委托的 agent 只拿到干活必需的最小工具面,不默认继承我这台机器上宿主环境的全部插件/技能/自定义 agent 工具(spike 实证:无头 claude 默认继承宿主全部工具面),以便被委托方的能力边界可预期。
15. 作为宿主用户,我想让委托 codex 时用一份每任务独立、用完即弃的 codex 配置(只借我的登录凭据、不带我的全局 danger-full-access 设置),以便委托绝不污染我的真实 `~/.codex`。

### 适配层归一化(平台维护者视角)

16. 作为平台维护者,我想让两家 agent 迥异的事件流(Claude 的 stream-json、Codex 的 exec NDJSON)被各自 adapter 翻译成同一套 6 型消息(text/thinking/tool-use/tool-result/status/error),且工具调用的 CallID 全链保留,以便上层只认一种消息模型。
17. 作为平台维护者,我想让两家在「操作被拒信号」上的不对称(Claude 合成可识别的 is_error 结果,Codex 静默无事件)在归一化层被显式抹平,以便上层不必知道底下是哪家。
18. 作为平台维护者,我想让两家在「终态判定」上的不对称(Claude 须联合 is_error/terminal_reason 多字段、Codex 错因藏在双层编码 JSON 里)在 adapter 内被收敛成统一的终态枚举,以便状态判定不散落到上层。
19. 作为平台维护者,我想让一切 agent 子进程副作用(拉起、探活、流式读、终止)压到 AAAgentCore 自己的 AgentPort 之后,以便任务状态机与归一化能在假件上纯逻辑测试、零真实 agent 依赖。
20. 作为平台维护者,我想让 AAAgentCore 只依赖 AAContracts(不依赖 SDK/Host*),以便它作为独立模块与 v1-core-proxy 的 16 票并行落地、互不踩施工面。

### 生命周期健壮性

21. 作为平台维护者,我想让适配层显式管理 agent 进程的 stdin 生命周期(spike 实证:Claude stream-json 写完 prompt 不发 EOF 就不自退;Codex exec 不给 stdin=/dev/null 会静默挂起),以便进程不无故卡死或不退出。
22. 作为平台维护者,我想让取消走进程组 SIGTERM→宽限→SIGKILL,连带杀掉 agent 派生的子进程树、不留孤儿(样板:现有 SystemProcessPort 的反孤儿模型),以便取消/退出后没有游离进程。
23. 作为平台维护者,我想有一个「消息静默看门狗」在 agent 长时间无输出时判定卡死并终止,且对工具调用在途时放宽超时预算,以便真卡死能被收掉又不误杀慢工具(spike 实证:Codex 失败网络重连可达 40+ 秒)。
24. 作为平台维护者,我想在拿到 agent 的 session/thread id 时就立刻记进任务元数据(Codex 首行 thread.started、Claude system.init 即有),以便将来做会话续接时有据可依(V1 不实现续接本身)。

## Implementation Decisions

以下汇编 map 的 14 项决议 + 两个 spike 的实测事实 + 骨架摸底结论;不改变任何已拍板决议,「归实施」的细节由 ticket/实现定。

### 模块形态与边界

- 新 **library target `AAAgentCore`**,依赖仅 `AAContracts`,纯逻辑:零 AppKit、Process/文件 I/O 全部压到 Port 之后。铁律与 PluginProxy 同级(编译期 + check.sh grep 双重强制不 import Host*)。
- AAAgentCore 定义**自己的 `AgentPort`**(不复用 `AAPluginSDK.ProcessPort`,因依赖边界只到 Contracts)。AgentPort 抽象一次 agent 进程执行:以 `(可执行路径, 参数, 环境, 工作目录, stdin 处置)` 启动,返回一个可读的**行式事件流**(agent stdout 的逐行)+ 一个句柄;支持探活、进程组终止。样板 = `SystemProcessPort` 的反孤儿模型(atexit/SIGTERM/SIGINT/SIGHUP 钩子兜底 SIGKILL)。
- 其余副作用同样端口化:**ClockPort**(看门狗与超时,可测)、**FileSystemPort**(任务工作区读写)或等价的注入点,使状态机纯逻辑可测。端口划分粒度归实施,红线是「域逻辑不直接碰 Foundation 副作用」。
- **真实现 + 试驾 CLI**:新建独立 executable target(暂名 `aa-agent`,名可调),依赖 `AAAgentCore` + 各 Port 真实现(`SystemAgentPort` 等);它就是 V1 委托入口(`aa-agent run|status|cancel|list`)。**不碰现有 `aa` 与 `AAHostMacOS`**(守并行红线,避开正被 v1-core-proxy 改动的施工面)。真实现放在这个 executable target 内或一个薄的桥接 target,归实施。
- **后置 glue(不在本 spec)**:把 `agent.*` 能力(如 `agent.delegate`/`agent.status`)挂进 `AAHostRuntime.Registry`、把 SystemAgentPort 注入、宿主 GUI 入口与通知——都是 AAAgentCore 落定后的薄接线,属 fog,待宿主壳成型再做。

### agent 适配(首批两家)

- **Claude Code adapter**:`claude -p --output-format stream-json --input-format stream-json`,prompt 走 stdin 一行 JSON;**必带 `--permission-mode bypassPermissions`**(spike:不带则工具调用被同步自动拒绝,任务残废),且此 flag 进 blocked-args 黑名单不可被委托参数覆盖(否则退回交互模式 → 无头永久挂起);**必带能力面收紧**(`--strict-mcp-config` + 显式工具白名单,屏蔽宿主继承的插件/技能/自定义 agent 面);stdin 写完 prompt 后由适配层显式管理关闭/收尾(进程不自退)。
- **Codex adapter**:`codex exec --json`;**stdin 显式 `/dev/null`**(否则静默挂起);沙箱经 `-s/--sandbox` 或 `-c sandbox_mode=` 传;**每任务独立 `$CODEX_HOME`**(只拷贝用户 `~/.codex/auth.json`、绝不拷 `config.toml`;用完即弃),实测 fail-closed(缺 auth 直接 401 不回退真身份),保证不污染用户全局配置。
- **不采 ACP、不采 codex app-server**:碎片化实证见 multica 报告(ACP 六家连恢复会话方法名都不统一);app-server 的复杂度服务多轮 thread 管理,单次 job 用不上。手写两个薄协议客户端,零 SDK、零 PTY。
- **模型选择**:委托可选 `model` 字段,**原生模型名字符串透传**到各家 CLI(Claude `--model`、Codex `-m`/`-c model=`);传错由 CLI 自己报错,适配层如实回传;不做跨厂商模型枚举拉平(学 multica `thinking.go` 的价值观)。模型目录/自省探测进 fog。

### 消息归一化(6 型统一模型)

- 定义统一消息类型(Swift `Codable`,置于 AAAgentCore;暂不进 Contracts——它是适配层内部模型,非三方共用词汇):`text` / `thinking` / `tool-use` / `tool-result` / `status` / `error`(multica 的 6 型,`log` 型 V1 并入 status 或丢弃,归实施)。**工具调用 CallID 全链保留**(修 multica 在 daemon 边界丢 CallID 的有损点)。
- 每家 adapter 的归一化是**纯函数**:`(原始事件行) -> [统一消息]`,不碰副作用——直接用两个 spike 落盘的真实样本(`research/spike-*/**.ndjson`)当黄金测试向量。
- **三处不对称在归一化/adapter 层显式抹平**(spike 核心产出):
  1. **沙箱边界**:Codex `workspace-write` 有真 OS 沙箱(拦 cwd 上级越界写);Claude cwd 非安全边界(`../`、`/tmp` 越界写全成功)。→ 见「双层信任」,两家不能用同一隔离假设。
  2. **操作被拒信号**:Claude 合成 `is_error:true` 的 tool_result(可编程识别)+ `permission_denials[]`;Codex 被拒调用连 `item.started` 都不出现(静默空气墙,只能事后 diff FS)。→ 归一化成统一的「操作被拒」status 消息;Codex 侧的「拒绝」在 V1 只能尽力而为地不可见,spec 承认此限制。
  3. **终态判定**:Claude 须联合 `is_error`/`terminal_reason`/`api_error_status`(不能只看 `subtype`,model 错时 exit 1 但 subtype 仍 success);Codex 成功=exit0+`turn.completed`、失败=exit1+`turn.failed`(错因是双层编码 JSON 需 parse 两层),中断=负信号号。→ 各 adapter 内收敛为统一终态枚举 `completed/failed/aborted/timeout`。
- `control_request` 应答:Claude spike 8 次零命中(判为版本漂移),V1 **不实现** control_request 应答逻辑,仅留兜底(收到未知双向消息时记日志不崩)。

### 双层信任

- **OS/文件层——委托即授权**:agent 在任务工作目录内以 bypass(Claude)/sandbox(Codex)模式全权执行,过程内不中途等人。
- **Claude 侧隔离的诚实声明**(spike:cwd 不是安全边界):V1 **接受「任务工作目录之外不设防」的信任假设并在文档显式写明**——理由:(a) 真正的护栏是平台信任面(经 aa 的 dangerous 确认),不是文件系统;(b) 委托本就是「以用户身份替用户干活」,等价于用户自己开 claude;(c) 任务 b 本就需要写到任务目录外的 mihomo 配置路径,强隔离反而挡路。OS 级沙箱(sandbox-exec 等)进 fog,非 V1。
- **平台信任面——不可绕过**:agent 若要改系统代理/换订阅源等,只能经 `aa` → `Registry.invoke` → 现有三档路由;dangerous 在 `Registry.invoke` 层强制宿主 GUI 确认(nil 回调 fail-closed),CLI 收 pending/denied 不阻塞。此机制已由 v1-core-proxy 04 票建成,本模块复用、不改。
- **能力面收紧**(spike 新发现,升为必做):委托 Claude 必须显式限定工具面(`--strict-mcp-config` + 工具白名单),不继承宿主环境全部工具。具体白名单集归实施。
- **发起方决定确认强度**(fog,北极星第二步):用户从试驾 CLI/宿主 GUI 亲手发起委托 = 发起动作即授权;插件/CLI 发起委托 ≈ 拉起任意代码执行,倾向按 dangerous 档经宿主确认——待「插件经宿主委托」sharpen。

### 进程生命周期

- **单发子进程、不常驻、不复用**:每次委托一次性拉起,终态即回收。
- **取消/退出**:进程组 SIGTERM → 宽限期 → SIGKILL,连带杀 agent 派生的子进程树(样板 SystemProcessPort 反孤儿钩子)。Claude 中断后会先补 `[Request interrupted]` 再落终态 result——**drain 循环必须读到底,不能一发信号就弃管道**;Codex 中断不产终态 JSON——**适配层在发信号那刻自行标记 aborted**。
- **看门狗**:消息静默看门狗(长时间无输出判卡死)+ 工具在途放宽(有未闭合 tool-use 时给更大预算)。阈值可配,默认值归实施(须容忍 Codex 40+s 网络重连)。
- **会话 id**:拿到即记进 `meta.json`(Codex 首行 `thread.started.thread_id`、Claude `system/init.session_id`);V1 **不实现续接**,失败重跑一律全新任务(顺带绕开 multica「中毒会话」问题)。

### 任务工作区(03 票已定稿,详见 [结构提案](research/task-workspace-proposal.md))

- 根 `~/.aa/agent-tasks/`,在 `AAContracts.AAPaths` 加静态常量作单一来源(与 `socketPath` 同款,不在 AAAgentCore 另起)。
- 目录名即 task-id:`<YYYYMMDD-HHmm>-<slug>-<hex4>`。
- 每任务固定布局:`meta.json`(状态唯一真相源,单写者=适配层,`schema_version` 演进,`state`∈pending/running/completed/failed/cancelled/timeout/orphaned)+ `prompt.md`(委托快照)+ `report.html`(主产物,通知直开)+ `changes.md`(有副作用任务)+ `logs/{raw.ndjson, normalized.ndjson, stderr.log}` + 缺省 `work/`。
- **raw 与 normalized 永不互相回写**;下游(状态/报告)只消费 normalized,排障才碰 raw。
- **HTML 报告**:主路径 = 委托 prompt 模板约定 agent 直写自包含 `report.html`;兜底 = 无该文件时适配层把最终文本 escape 套极简内置模板生成(不做 md→HTML 渲染器,守零依赖)。
- **崩溃残留**:`state=running` 且 `pid` 已死 → 任何 `aa-agent` 读操作扫到即标 `orphaned`,证据不删。
- **prune**:`aa-agent tasks prune --older-than|--keep`,只删终态、永不删 running;`list` 显示条数与磁盘占用。

### 验收场景 b 的收敛(摸底新发现,守并行红线)

- mihomo 的写能力(`proxy.mode.set`/`proxy.subscription.update`/新增订阅源)属 v1-core-proxy 的 09/10 票,**尚未落地**;插件现仅暴露只读 `proxy.status`。
- 为不依赖未完成的票,验收 b 用平台**已跑通**的 demo 能力演示双层信任路由的机制正确性:agent 经 `aa demo.note.set`(normal,零打断)完成一次可逆改动、经 `aa demo.wipe`(dangerous,触发宿主 GUI 确认/拒绝两分支)证明信任面不可绕过。
- **等 09/10 的 `proxy.*` 写能力落地,同一委托机制零改动自动适用**——AAAgentCore 不感知具体能力,只负责把 agent 的 `aa` 调用透传到注册表。spec 在验收辞里用 demo 能力表述,mihomo 具体写能力作为「机制适用性」的将来延伸,不作 V1 硬依赖。

## Testing Decisions

**好测试的标准**(沿用仓库价值观):只测外部行为——归一化函数的输入行→输出消息、任务状态机的状态迁移与终态、AgentPort 收到的调用序列(launch 参数/终止信号)、任务工作区落盘后的文件结构与 meta 状态;不测实现细节。每张实施票的红绿循环必须有一条当天(vfsoverlay 环)就能跑的验证。

**三层 seam**:

1. **主 seam:AgentPort 假件**。一切 agent 子进程副作用压到 AgentPort 之后;`FakeAgentPort` 可编程「回放一段预置 stdout 事件脚本」「编程 launch 失败」「编程进程中途死亡」「记录终止信号序列」(样板 = 现有 `FakeProcessPort`)。任务状态机、生命周期、看门狗、取消、工作区落盘全在此层纯逻辑测,零真实 agent。金字塔主体在这层。
2. **次 seam:归一化纯函数 × spike 黄金样本**。两家 adapter 的 `(原始行)->[统一消息]` 是纯函数,直接喂两个 spike 落盘的真实 NDJSON 样本(`research/spike-claude-headless/*.stdout.ndjson`、`research/spike-codex-exec/samples/*.stdout.jsonl`)断言归一化结果——**spike 样本即回归测试资产**,把一次性实测固化成永久测试向量。三处不对称的抹平规则各配至少一条针对性断言。
3. **试驾 CLI 端到端**(冒烟,不进日常门禁):`aa-agent run` 真拉起 claude/codex 跑一个最小任务,断言终态与 report.html 产出。类比 XCUITest 的地位——需真 agent 与配额,仅发版前或手动跑。

**测试引擎的现实落差(spec 显式约束,禁止实施票踩坑)**:仓库当前**无 swift-testing、无 `Tests/` 目录**;既有测试是手写 `TestReport` 断言框架放在库 target 的 `Sources/` 下、由 `Scripts/check.sh` 动态生成 runner 跑二进制断言 stdout(样板 `RegistryConformanceTests`/`ProxyConformanceTests`)。**AAAgentCore 的 V1 测试必须落成与之同构的 `TestReport` 模式**(放 AAHostTestKit 或新 `AAAgentTestKit`,归实施),接入 check.sh 拓扑序编译 + runner。**不得直接 `import Testing`**——swift-testing 迁移是 v1-core-proxy 11 票(Xcode 就绪后 vfsoverlay 退役)的统一动作,本模块随之迁移,届时测试接口(TestReport→#expect)保持行为不变。

**被测模块**:AAAgentCore 域逻辑(状态机/生命周期/看门狗/工作区,经 Fake Port)、两家 adapter 归一化(经 spike 样本)、`aa-agent` CLI(E2E 冒烟)。

**门禁**:AAAgentCore 的编译 + TestReport 测试并入 `Scripts/check.sh`(vfsoverlay 直编环,与现有 target 同拓扑序);check.sh 的一条命令、非零即失败的接口不变。

## Out of Scope

- **多轮会话/追问**:V1 单次 job;想多轮的用户回到 agent 侧,由 agent 经 `aa` 反向调用平台(v1-core-proxy 已有方向承接)。
- **会话续接(resume)**:V1 不实现;仅记 session id 留门。
- **宿主 GUI 接线**:菜单栏委托入口、系统通知、GUI 实时滚屏——待宿主壳(v1-core-proxy 12/14 票)成型后的后置 glue。
- **`agent.*` 能力挂进注册表**:把委托暴露成平台能力供别的 agent/插件调用——北极星第二步「插件经宿主委托」,fog。
- **per-op 审批上抛**:把 agent 过程内权限请求异步转发宿主 GUI(multica 明确没做的那块)——双层模型跑通后的方向。
- **OS 级强隔离**:Claude 侧 sandbox-exec 等;V1 接受「任务目录外不设防」信任假设。
- **能力面探测/模型目录**:multica 式 `(provider,executable,version)` 缓存的自省;agent 未装/版本过旧的检测与引导(MinVersions 类)。
- **Codex/Claude 以外的 agent**(含 Gemini CLI 等)、ACP 协议、codex app-server 协议。
- **调度台、定时/事件触发委托、按内容自动路由 agent**。
- **mihomo 具体写能力**:属 v1-core-proxy 09/10 票,本 spec 用 demo 能力演示机制,不硬依赖其落地。

## Further Notes

- 语言:全部产出(代码注释、文档、票)中文;agent 机器面为英文 JSON/CLI。
- **工具链两段式约束**(继承 v1-core-proxy):Xcode 未装期,AAAgentCore 走 vfsoverlay 直编 + TestReport 断言验证;每张实施票标注「vfsoverlay 可验」或「需 Xcode」。AAAgentCore 纯逻辑 + Fake Port,主体 vfsoverlay 可验;试驾 CLI 端到端需真 agent(非门禁,手动)。
- **spike 样本是一等测试资产**:`research/spike-*/` 下的真实事件流不是临时产物,是次 seam 的黄金向量,实施时纳入版本库并被测试引用。
- **旗舰验收辞**:「宿主经 `aa-agent` 委托 codex/claude 完成一次诊断任务并产出 HTML 报告;委托一次经 `aa demo.note.set` 的可逆改动全程零打断;委托一次经 `aa demo.wipe` 的信任面改动必触发宿主 GUI 确认且拒绝分支能挡住」——此场景通过即本模块出口。
- **与参考项目 multica 的关键差异**:multica 全自动无平台审批面(连 agent 的「问人」工具都禁用),本模块的双层信任正是补上这一环;multica 在 daemon 边界丢 CallID、消息排序有隐患,本模块保留 CallID 全链;multica 会话机器绑定,本模块 V1 索性不做续接。详见 [multica 调研报告](research/multica-adapter-analysis.md) 第 8 节借鉴与踩坑清单。

## 修订指令(2026-08-04,a2 内核 bin 化)

架构反转(见 [ADR 0008](../../docs/adr/0008-kernel-bin-ui-optional.md))之后,本 spec 正文所依赖的宿主模型(`aahost` 持有主逻辑、GUI 弹窗确认、`aa` 薄客户端、`~/.aa` 路径)已整体作废。**本次不改正文实现细节**——正文继续作为「一次委托怎么跑」的行为规范参考;下列四条(前三条是修订方向,第 4 条记未裁项)是重启本效fort时必须先落地的,冲突处以本指令为准。指令来源:`.scratch/kernel-bin-recharter/` 的 04/05/06/08 票(**本机决策记录,未入库**)。

1. **审批收敛到内核统一仲裁**。委托执行器的 dangerous 与普通调用一律走内核的**三层仲裁**([ADR 0005](../../docs/adr/0005-agent-first-interaction.md) 修订后第 4 条):无确认器 → 结构化默拒;拒绝报文自带「人类如何完成」的精确命令并结构化回传发起方;有确认器 → 带外确认(确认信息永不过 agent 之手)。同一条确认器通道、同一套禁旁路规则(`--yes` 永禁、TTY 确认禁止)、内核统一 audit 记账。正文「双层信任」一节里凡是「经 `aa` → `Registry.invoke` → 宿主 GUI 确认 / nil 回调 fail-closed」的表述,一律按新模型重读:**平台信任面不可绕过这一条不变,变的是确认由谁出面、不在场时怎么办**。
2. **执行器将来在内核内以 TS 重生**。`aa-agent` / `AAAgentCore` 随旧可执行一并**挂起**(04 票):不再新建 Swift 实现,已有 Swift 代码与测试降级为行为规范参考;将来在 `kernel/` 内以 TS 重建([ADR 0010](../../docs/adr/0010-ts-kernel-bun-runtime.md))。连带改名:委托入口 `aa-agent …` → 内核子命令(`a2 …`,具体命名届时定);任务工作区根 `~/.aa/agent-tasks/` → `~/.a2/agent-tasks/`(`A2_HOME` 可覆写);正文里 agent 反向调用平台的 `aa …` 一律为 `a2 … --json`。**AgentPort/ClockPort/FileSystemPort 的端口化思想、6 型消息归一化、三处不对称的抹平规则、两个 spike 的黄金样本**在 TS 侧原样继承——spike 样本继续是一等测试资产。
3. **壳侧无专属通道**。菜单栏壳 `a2-panel` 是对等客户端 + 角色注册(确认器 / 订阅者),**不含业务逻辑**,不为委托开任何私有入口;正文 Out of Scope 里的「宿主 GUI 接线(菜单栏委托入口、系统通知、GUI 实时滚屏)」按新契约重画——委托状态经内核事件流推送给订阅者,壳只做投影。委托的发起端首选 CLI(agent 与人都走同一条),GUI 入口是可选糖。
4. **仍然待裁**:「发起方决定确认强度」(人亲手发起 vs 插件/CLI 发起委托的档位差异)在本次批次里**没有被裁**,继续挂在本 spec 的 fog 里,重启本效fort时连同 TS 重建方案一并 sharpen。
