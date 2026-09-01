# Spec:a2 内核 bin 化 —— TS 内核、CLI 唯一必需面、UI 降为可选壳

Status: ready-for-agent
创建:2026-08-04(/to-spec 综合自 [kernel-bin-recharter 地图](../kernel-bin-recharter/map.md),13/13 票已收图,无新面试)
决策来源:kernel-bin-recharter 全部 13 票(01 前提、02/03/09/11 调研、10 语言、12 mihomo、04 进程模型、05 仲裁、06 壳契约、07 蓝图、13 插件、08 收图),细节以各票 `## Answer` 为准;本 spec 只收拢,不新裁。

## Problem Statement

我要的架构和现在是反的。现状:GUI 宿主 `aahost` 持有全部主逻辑(注册表、UDS server、插件、mihomo 生命周期),`aa` 只是薄客户端——UI 是必需品,agent 是客人。而我的宗旨是 agent first:主逻辑完全不依赖 UI;内核完全是 bin、经 CLI 使用;无 GUI 是一等公民运行形态;内核跨端(macOS+Linux)是当下承诺;UI 只是可选客户端。现有 Swift/AppKit 栈把这条路封死了,这是一次大重构。

裁决序(全效fort通用):**安全底线 > 法律义务(GPL)> agent-first > 人类便利**。

## Solution

把架构反转过来:

- **TS 重写内核**,Bun compile 成单文件 bin **`a2`**(macOS+Linux;60.5MiB/冷启 ~8ms/RSS ~26MiB 实测),单 bin 多模式:默认 CLI 子命令,`a2 daemon run` 进常驻模式。
- **CLI 是唯一必需交互面**:agent 用 Bash 起子进程 `a2 … --json` 读 stdout,零协议零配置;CLI 永不交互阻塞;dangerous 无确认器时结构化默拒,拒绝报文自带「人类如何完成」的精确命令。
- **常驻显式安装、系统托管**:`a2 service install` 落 launchd/systemd user 单元,自启自愈归系统;CLI 永不隐式拉起 daemon。
- **mihomo 不随包分发**:安装脚本获取,挂自己的 `com.a2.*` unit 系统托管,内核只做配置/reload/存活/启停监督;检测到用户已有 mihomo 时优先复用,复用到实例级;数据面不随控制面起落。
- **菜单栏壳 `a2-panel`(「A2 Panel」)降为可选对等客户端**:确认器 + 状态订阅投影,不含业务逻辑;壳缺席时内核静默运行、dangerous 默拒;「退出即还原」废除。
- **插件北极星「agent 现场写插件」落地**:插件 = 单文件 `.ts`,内核经 `BUN_BE_BUN` 拉起子进程,exec 一次一调(`describe`/`call`);`a2 plugin add` 零闸即生效,dangerous 仲裁只在调用层。
- **迁移六步**(①契约骨架→②控制面→③mihomo 监督→④仲裁确认器→⑤壳原子切换→⑥插件宿主),每步门禁绿;⑤是唯一门禁切换点,**Phase 1 出口 = ⑤完成**。

## User Stories

### AI agent(Claude Code / Codex 类)

1. 作为 AI agent,我想用 Bash 起子进程执行 `a2 <子命令> --json` 并从 stdout 读结构化结果,以便零协议、零配置、零 SDK 地使用整个平台。
2. 作为 AI agent,我想让每条 CLI 命令有稳定的机读输出 schema 与退出码语义,以便可靠判断成败并据此决策。
3. 作为 AI agent,我想让 CLI 永不交互阻塞(无 TTY 确认、无 `--yes` 旁路),以便我的执行流程永不挂起。
4. 作为 AI agent,我在触发 dangerous 能力而无确认器在场时,想收到 `confirmation_unavailable` 类结构化默拒,以便明确知道这条路走不通而不是超时猜谜。
5. 作为 AI agent,我想让拒绝报文自带机器可读的「人类如何完成」精确命令,以便我原样转告用户、用户自己执行(无 GUI 端的零基建路径)。
6. 作为 AI agent,我想在 daemon 未安装/未运行时得到含精确修复命令的结构化指引而非隐式拉起,以便引导用户显式安装,而系统状态永远不因我的查询而被动改变。
7. 作为写插件的 AI agent,我想现场写一个零依赖单文件 `.ts` 就用 `a2 plugin add <path>` 当场装上、立即可调,以便「现场写插件」不被任何装载闸打断。
8. 作为写插件的 AI agent,我想让带 npm 依赖的插件目录在 add 时被自动 install+bundle 成单文件工件(打不进的怪包收到明确拒绝+指引),以便运行期永远是单文件、不用管 node_modules。
9. 作为 AI agent,我想用 `a2 plugin` 系列命令列出/调用插件工具(内核统一暴露 describe 出的清单与 schema),以便像用内置能力一样用插件。

### 人类终端用户(macOS / Linux)

10. 作为终端用户,我想 `curl` 一条安装脚本或直接下载单文件就装好 `a2`,以便不依赖任何包管理器或 GUI。
11. 作为终端用户,我想用 `a2 service install|uninstall|status` 显式管理常驻服务(开机自启、崩溃自愈全归系统 supervisor),以便一次安装后不再操心进程存活。
12. 作为终端用户,我想让 mihomo 由安装脚本获取并挂在独立的系统 unit 下,内核崩溃或升级时代理流量完全不断,以便数据面不随控制面起落。
13. 作为已经自装 mihomo 的用户,我想让 a2 检测并优先复用我已有的安装——运行中实例经 API 接管配置与监督(进程生死仍归原托管方)、仅有二进制则只读复用,以便不装第二份也不被抢走控制权。
14. 作为终端用户,我想让 mihomo 升级永远是显式命令而非静默更新,以便版本变化永远在我知情下发生。
15. 作为终端用户,我想让系统代理还原等恢复动作是内核显式命令(而不是挂在 GUI 退出上),以便无 GUI 也能干净还原环境。
16. 作为终端用户,我想用 `a2 about` 读到 GPL 声明与许可信息,以便义务履行不依赖任何 UI。
17. 作为 Linux 无头用户,我想用同一套 CLI 全功能操作(dangerous 默拒即设计行为,拒绝即指引兜底),以便无 GUI 端是一等公民而非阉割版。

### 菜单栏用户(macOS)

18. 作为 Mac 用户,我想要可选安装的「A2 Panel」菜单栏壳实时显示代理状态/节点列表(订阅推送,零轮询),以便随手可看。
19. 作为 Mac 用户,我想让 dangerous 确认弹在确认器(点按/Touch ID),确认信息永不过 AI agent 之手,以便任何自动化都改不了我的信任面而不经过我。
20. 作为 Mac 用户,我想退出菜单栏壳后代理照常运行(退出仅是客户端断连),以便关掉 UI 不等于关掉服务。
21. 作为 Mac 用户,我想在壳缺席/崩溃时内核静默运行——事件入日志、CLI 可查、dangerous 自动降回默拒,以便系统行为始终可预期、fail-closed。

### 维护者

22. 作为维护者,我想让协议报文以 TS schema 为单一事实源并导出 JSON Schema,Swift 侧手写 Codable 对照 + 金标报文快照双端门禁,以便契约漂移在门禁层被抓住而不引入代码生成链。
23. 作为维护者,我想让迁移六步每步可合并、门禁绿(⑤前 `check.sh` 保绿,⑤时原子切换到 TS 门禁),以便重构全程主干可用。
24. 作为维护者,我想让旧 Swift 逻辑与 428 断言在重建期作为行为规范参考逐条映射(允许合并/淘汰只属 Swift 实现细节的断言),以便已验收的行为不静默丢失。
25. 作为维护者,我想让七条 ADR 批次落笔、路线图出口判据重写,以便决策记录与代码同步演进。
26. 作为维护者,我想让 `a2-panel` 不含业务逻辑、插件只经协议白名单拿能力,以便两条结构红线在新架构下可审计。

## Implementation Decisions

以下全部为已锁定决策(出处标票号),实施不重开:

### 语言、运行时与端范围(09/10/11 票)

- 内核 **TS 重写**,运行时基线 **Bun compile 单文件 bin**;实测:产物 60.5MiB、冷启 7.7–13ms、常驻 RSS 26.4MiB,`--target=bun-linux-x64` 交叉编译产出合法 ELF。若 Bun 翻车,复议运行时(Node SEA/Deno compile 已因不能执行外部脚本被排除),**语言裁定不重开**。
- 端范围:**macOS + Linux 当下承诺;Windows 远景,不设预留约束**。
- Mac 壳留 Swift,经 UDS 与内核通信。

### 进程模型与常驻(04 票)

- **单 bin 多模式**:一个编译产物,默认 CLI,`a2 daemon run` 前台常驻(调试);daemon 与 CLI 天然同版本,插件运行时也是同一文件。
- **系统托管 + 显式安装**:`a2 service install|uninstall|status` 写 launchd user 域 plist(`launchctl bootstrap`)/ systemd user unit;自启与自愈(`KeepAlive.Crashed`/`Restart=on-failure`)全归系统 supervisor,应用层不造看门狗。未装/未运行时 CLI **永不隐式拉起**,返回结构化指引(与「拒绝即指引」同构)。
- **路径约定**:统一 `~/.a2`(环境变量 `A2_HOME` 覆写);socket `~/.a2/run/kernel.sock`;unit 命名空间 `com.a2.*`。Bun 的 UDS 权限跟随 umask(实测),内核必须自建 socket 父目录 0700 并在 bind 后显式收紧权限。
- 对端身份:UDS peer credential 经 `bun:ffi` 调 `getpeereid()`(macOS 实测打通)/Linux `SO_PEERCRED`,内核校验对端 UID。

### mihomo(12/04 票)

- **不随任何分发物打包**;内核职责四件事:脚本化安装、配置管理、开机自启、存活检测。
- **系统托管 + 内核监督**:脚本安装的 mihomo 挂**自己的** `com.a2.*` unit;自启/崩溃重拉归系统;内核做配置+reload、存活探测、经 launchctl/systemctl 启停。**数据面不随控制面起落**。
- **共存 = 检测并优先复用,复用到实例级**(用户明确解除产品层「不接管用户 mihomo」约束):①运行中实例(external-controller 可达)→ API 接管配置与监督,进程生死归原托管方,实例死了只报警+指引;②仅有二进制 → 只读复用,配置/数据/unit 自建;③全无 → 脚本安装,版本按发布元数据锁定。兼容性不达标回退隔离安装;**升级永远显式**。

### dangerous 仲裁与确认器(05 票,替代 ADR 0005 第 4 条)

- **三层叠加**:①无确认器 → 结构化默拒 `confirmation_unavailable`,fail-closed;②拒绝报文即指引(机器可读「人类如何完成」精确命令,agent 只转告);③有注册确认器 → 带外确认(mac=菜单栏壳,确认信息永不过 agent 之手)。`--yes` 类旁路永禁。
- **在场 = 长连接**:确认器注册 confirm-agent 角色并保持长连接;断线即降回默拒;无轮询无心跳;内核校验对端 UID。
- **TTY 交互确认禁止**(`isatty` 不构成人类证明);CLI 永不阻塞保持(ADR 0005 第 3 条不动)。
- 跨端确认器只定协议插槽;V1 唯一实现 = mac 菜单栏壳;Linux 默拒即设计行为。
- agent-delegation 审批**收敛到内核统一仲裁**(同三层/同通道/同禁旁路,统一 audit);执行器将来在内核内以 TS 重生。
- 术语:**确认器**(confirm agent)。

### 壳契约(06 票)

- **对等客户端 + 角色注册**:壳与其他客户端同一条 UDS capability 面,无特权通道;confirm-agent/subscriber 是长连接上注册的角色。V1 不验签;同 UID 冒名记为已知边界(仲裁保护受认可路径,不对抗同 UID 恶意代码);注册协议预留身份强化字段(将来 cdhash/团队 ID)。
- **状态同步 = 订阅推送**:连上先收全量快照,之后增量推送;壳模型 = 内核事件流投影;零轮询。
- **UI 资产全套保留、改喂养源**:「一个模型两个渲染器」与手搓快照测试原封保留,继续当壳侧门禁;XcodeGen .app 工程保留(Touch ID/系统通知要求 bundle 身份)。
- **V1 交付壳**;无壳 = 静默 + 日志 + CLI 可查 + dangerous 默拒。**「退出即还原」废除**:还原动作改挂内核显式命令,壳退出仅断连。
- 红线:**`a2-panel` 不得含业务逻辑**,只做事件投影 + 确认器呈现。

### 插件(13 票)

- 两条接口分开:**agent→内核维持纯 CLI**(零协议零配置);**内核→插件 = exec 一次一调**——`BUN_BE_BUN` 拉起子进程,`plugin describe` 输出工具清单+schema+dangerous 声明(JSON),`plugin call <tool>` stdin JSON 进、stdout JSON 出,退出码即成败。**MCP 不进 V1**(将来可 adapter 包装,挂起不排期)。
- V1 插件**无事件面/无常驻态**(已知限制;壳所需事件全部源自内核自身状态)。
- **依赖 = 装载期 install+bundle,运行期全员单文件**:零依赖单文件 `.ts` 直接登记(北极星主形态);带依赖目录插件在 add 时临时 `bun install` + `bun build --target=bun` 打成单文件工件,node_modules 即弃;native addon(add 期,产物文件数>1 判据)与打包失败结构化拒绝+指引,动态 require 打包期检不出、走运行期 `--no-install` fail-closed 兜底;`bun install` 必带 `--ignore-scripts` 连根封死 lifecycle scripts(02 票 spike 实证:默认只跳依赖的、根工程照跑,不显式封死不安全)。〔本行 2026-08-05 按 02 spike 实证与 11/12 票落地口径订正,原「默认不跑 lifecycle scripts」不准确〕
- **装载零闸、调用层唯一仲裁**:`a2 plugin add` 即时生效(登记+审计事件推送确认器/入日志);dangerous 只在 tool 调用层走三层仲裁。
- 红线等价物:插件 = 进程外子进程,能力只经协议白名单。

### 契约、仓库与命名(07 票)

- **同仓 monorepo**:新增 `kernel/` TS 工程(源码、锁文件、协议 schema);Swift 壳留原处;逻辑 target 降为行为规范参考、⑤后退场。
- **契约 TS 为源**:zod 类 schema 导出 JSON Schema(机器可读契约,也是 agent 写客户端/插件的土壤);Swift 手写 Codable 对照;双端金标报文快照,契约变更即门禁报警;**不引入代码生成链**。
- **命名 a2 系**(品牌级,原 aa 系全面退场):bin `a2`(小写)、`a2 daemon run`、`a2 service …`、壳 target `a2-panel`、.app 显示名「A2 Panel」;`~/.a2`、`A2_HOME`、`com.a2.*`。中文概念名不变(菜单栏壳、确认器)。

### 迁移与门禁切换(07/08 票)

- **六步切步,每步可合并、门禁绿**:①契约与骨架 → ②控制面重建 → ③mihomo 监督面 → ④仲裁与确认器协议 → ⑤**壳原子切换**(废除 `aahost`/`aa`/`aa-agent`;门禁由 `check.sh` 原子切至 TS 门禁——唯一门禁切换点;flagship e2e 对 `a2` 重写)→ ⑥插件宿主。
- **Phase 1 出口 = ⑤完成**;5 条人工项顺延⑤后按新形态重定义(签名仪式→a2-panel.app、TCC/通知授权→确认器、实测项→对 `a2` 重跑)。

### 分发与 GPL(03/08/12 票)

- 渠道 V1 = **单文件直接下载 + curl 安装脚本**;Homebrew Formula 后续;`a2-panel.app` 随附带包。
- GPL:不再分发 GPL 二进制,义务面收缩为「调用外部程序」;**内核重签校验废除**;关于页降级为外部程序声明;**`a2 about` 子命令 + 随包静态文本**为不依赖 UI 的必有落点;独立子进程红线保留并泛化。

### ADR 批次(08 票,七条)

①新增总纲 ADR「内核 bin 化与 UI 可选」;②ADR 0001 废止重立(macOS+Linux 承诺/Windows 远景);③ADR 0002 废止重立(TS 内核 Bun 单 bin + Swift 壳);④ADR 0005 修订(三层仲裁+确认器);⑤ADR 0007 修订(外部安装+义务收缩+红线泛化+`a2 about`);⑥新增 ADR「插件 exec 协议与装载」;⑦agent-delegation spec 修订指令(审批收敛内核、执行器内核内重生、壳无专属通道)。

## Testing Decisions

- **好测试 = 只测外部行为**:经公开缝打进去、断言可观察输出,不测实现细节。
- **测试缝(全部取既有最高缝,不新增更低层缝)**:
  1. **CLI 面**(最高缝):argv 进、stdout JSON/退出码出——TS 侧行为测试的主战场,`bun test` 直测子进程或命令处理函数;
  2. **UDS 协议面**:契约金标报文快照,TS 与 Swift 双端对同一批样本编解码,防契约漂移;
  3. **壳快照**:既有「一个模型两个渲染器」手搓快照测试原封保留,继续当壳侧回归门禁;
  4. **旗舰 e2e**:对真实 `a2` bin + 假 mihomo 夹具跑端到端旗舰场景(既有假 mihomo HTTP 夹具模式沿用)。
- **TS 门禁口径**(08 票):`bun test` + 契约金标快照 + 壳快照 + 重写版 flagship e2e。
- **行为对等映射**:既有 428 断言(4929 行 Swift 测试)逐条映射到 TS 侧,允许合并/淘汰只属 Swift 实现细节的断言;Swift 逻辑代码同期作行为规范参考。
- **门禁切换**:`check.sh` 保绿至⑤,⑤时原子切换到 TS 门禁后退役。
- 先例:v1-core-proxy 的金标样本、手搓快照、假 mihomo e2e 全套模式平移。

## Out of Scope

- **Windows**:远景,不设预留约束。
- **其他端 UI**:只做 Mac 壳。
- **MCP adapter**:挂起不排期,真实需求出现再立效fort。
- **既有暂缓清单**:TUN、内嵌 Codex、运行时第三方插件市场、云、App Store、静默更新——继续暂缓。
- **5 条人工项**(证书签名仪式、TCC/通知授权、真机实测两条等):顺延到⑤后按新形态执行,不在本 spec 排票。
- **v1-core-proxy 分支合并**:`worktree-v1-tickets-11-16` 合入 main 由用户执行。
- **V1 插件事件面/常驻态**:已知限制,显式不做。

## Further Notes

- **实施首步 spike**:`BUN_BE_BUN` 环境下跑 `bun build`/`bun install`(13 票依赖流的成立条件)是高置信**推断**、未实测——排为第一批票,翻车则依赖流回 04 票复议机制(运行时层面),装载协议不受影响。
- **Linux 口径**:交叉编译产物与 systemd 代码路径属当下承诺、进门禁(单元级);Linux 实机端到端验收未裁,默认随人工项节奏顺延(如需提前,用户裁定)。
- **施工红线**(与产品决策无关,agent 施工纪律):不动本机用户自己的 mihomo(端口 33888);门禁 e2e 短暂占用 127.0.0.1:7890;大文件操作用命令。
- 仓库无 git remote:所有工作本地提交,无 PR 流程。
- 文档语言:中文。
- 术语表:**确认器**(替人类出面呈现确认并安全回传批准的进程)、**菜单栏壳**(a2-panel)、**控制面/数据面**(内核/mihomo)、**北极星**(agent 现场写插件)。
