# 地图:内核 bin 化重构 — 主逻辑零 UI 依赖,agent-first 至上,UI 降为可选壳

Labels: wayfinder:map
创建:2026-08-04(后台任务开图;前提已于同日经 01 票现场面试钉死,Destination 经用户逐字确认)
**收图:2026-08-04 —— 13/13 票全部 resolved,雾区清空,destination 到达。后续按 wayfinder 流程交接 /to-spec → /to-tickets → /implement(实施不在本图)。**

## Destination

一套锁定的重构决定集与蓝图,把架构从「GUI 宿主(`aahost`)持有全部主逻辑、`aa` 是薄客户端」反转为「**无头内核 bin 持有全部主逻辑、CLI 是唯一必需交互面、无 GUI 为一等公民运行形态(dangerous 无确认代理时默拒)、内核跨端为当下承诺(语言与端范围经重议票裁定)、agent-first 在安全底线与法律义务之上压倒一切、UI(Mac=Swift 菜单栏壳)降为可选客户端**」:产出修订/新增 ADR(含 0001/0002 重开)、目标架构映射(target 图与迁移切法)、修订后的路线图、以及在飞 Phase 1 工作的处置。重构的实施本身按后续效fort开工,不在本图。

## Notes

- **领域**:桌面插件能力平台(Mac、Swift、SPM 单包多 target;首插件=代理/mihomo 壳)。现状拓扑:`aahost`(GUI 常驻:菜单栏 + UDS server + 注册表 + 插件 + mihomo 生命周期)⇠UDS⇢ `aa`(薄 CLI 客户端);`aa-agent` + `AAAgentCore/System` 为 agent-delegation 效fort的独立模块。
- **本效fort前提(用户 2026-08-04 原话;强度已由 01 票面试钉死,细节见其 Answer)**:
  1. 主逻辑完全不依赖 UI;
  2. 内核完全是 bin,经 CLI 使用;
  3. agent first 是最高宗旨;
  4. UI 不再是必须的;Mac 的 UI 先用 Swift;其他端先不做 UI;
  5. 定性为一次大重构。
- **与既有决定的碰撞面(本图要正面处置的)**:
  - [ADR 0005](../../docs/adr/0005-agent-first-interaction.md) 第 4 条「dangerous 最终确认必须落宿主 GUI」——已由 05 票重设计为三层叠加模型(默拒/拒绝即指引/确认器带外升级);
  - [ADR 0001](../../docs/adr/0001-mac-only-platform-boundary.md) Mac-only 与 [ADR 0002](../../docs/adr/0002-swift-native-stack.md) Swift 栈——01 票已裁跨端为当下承诺、语言全重议,两 ADR 重开,归 09/10 票;
  - [ADR 0007](../../docs/adr/0007-mihomo-subprocess-gpl-compliance.md) GPL 义务面挂在关于页——12 票已裁 mihomo 不随包分发,义务面整体收缩,处置归 04/08 票;独立子进程红线不变;
  - agent-delegation 效fort的审批模型同样押在宿主 GUI 确认上,连带面在雾区。
- **在飞状态(2026-08-04)**:v1-core-proxy 01–10 票在 main;11–16 票(+17 票提交)在分支 `worktree-v1-tickets-11-16` 待合;5 条人工项未做。处置已裁(01 票,(b) 案):合并分支保住已完成价值(用户执行),Phase 1 出口判据随重构重写(落 08 票),人工项顺延到新架构定型后。
- **技能**:决定票用 `/grilling` + `/domain-modeling`;调研票用 `/research`(结论落 `docs/research/`;本仓库 git 无 remote,直接写文件、不建分支);逐票一个 session,调研票可并行 AFK。
- **tracker 约定**:见 `docs/agents/issue-tracker.md`;解决时票内追加 `## Answer`、置 `Status: resolved`,再向本文件 Decisions so far 追加一行(追加前先重读本文件,防并发覆盖)。
- **文档语言**:中文。

## Decisions so far

<!-- 一行一票:够判断相关性即可,细节看票 -->

- [02 调研:无 GUI 前提下的 dangerous 确认模式](issues/02-headless-confirm-patterns.md) — macOS 平台层面无 app bundle 身份的裸 bin/LaunchAgent 不能用 UNUserNotificationCenter 与 Touch ID(Apple 工程师原话确认),故「UI 可选」不等于「宿主进程可以消失」——已有的 `aahost` 菜单栏壳可降格为最小确认代理但不能降到零;预授权 token/TTL 类模式对 agent 自批零防御,维持 ADR 0005 现有立场。
- [03 调研:macOS 无头内核 bin 的进程拓扑与分发先例](issues/03-kernel-daemon-topology.md) — 裸 bin 常驻不需要 `SMAppService`/`.app`,`launchctl bootstrap` + 手装 plist 是官方未废弃的一等公民路径(tailscaled 为先例),且比 `SMAppService` 更贴合「CLI 零 GUI 自拉起」;签名/分发现状不因裸 bin 化变差,但 GPL 义务的呈现位置(现挂「关于页」)必须补一条不依赖 UI 的落点(CLI 子命令 + 随包静态文本)。
- [01 前提确认:其他端野心、在飞工作处置、UI 可选的强度](issues/01-premises-confirm.md) — 四问面试钉死:①跨端是**当下承诺**、内核语言全重议(端范围连语言归 10 票,ADR 0001/0002 重开);②在飞工作走 (b) 合并+出口判据随重构重写、人工项顺延;③无 GUI 是一等公民,dangerous 无确认代理时默拒、确认代理可插拔;④裁决序:安全底线 > 法律义务 > agent-first > 人类便利。Destination 已按此改写并经确认。
- [09 调研:跨端内核的语言与平台成本盘点](issues/09-kernel-language-landscape.md) — Swift 跨端 Linux 扎实、Windows 官方自认仍在补课;本机实测平台绑定面仅 AppKit 三个壳 target(2386 行/18.9%),其余 10213 行纯逻辑可携带(3476 行 POSIX 需 Glibc 桥接);Go 是品类绝对先例但同语言反而放大 mihomo 嵌入的 GPL 风险,ADR 0007 独立子进程红线语言无关必须保留;Windows 是常驻/UDS/POSIX 三处都需重设计的一档;纯逻辑代码里唯一 macOS 假设是 `AAPaths.swift` 的 socket 路径。
- [10 决定:内核语言与跨端范围](issues/10-kernel-language-decision.md) — 四问面试钉死:①端范围 = macOS+Linux 当下承诺,Windows 远景且不设预留约束;②内核语言 = **TS 重写**(用户先排除 Swift;定性「内核是控制面」+ 插件北极星裁为「agent 现场写插件」后 TS 胜出;Go/Rust 落选;运行时基线 Bun 单 bin,11 票实测背书,翻车则 04 票复议运行时、语言不重开;Mac 壳留 Swift 经 UDS);③ADR 0001/0002 皆废止重立,ADR 0007 红线保留并泛化为插件通用边界;④04 票解锁但补 11 票为其输入。
- [12 决定:mihomo 不随包分发,脚本化安装与托管](issues/12-mihomo-distribution-form.md) — 用户主动裁定:mihomo 不打进任何分发物,我们只提供「安装脚本、配置管理、开机自启、存活检测」;GPL 义务面从「分发合规」收缩为「调用外部程序」(15 票关于页/重签校验的降级归 08 票),ADR 0007 独立子进程红线不变;托管归属与用户自装 mihomo 共存策略归 04 票。
- [11 调研:TS 内核运行时与单 bin 分发实测(Bun 基线)](issues/11-ts-runtime-bun-verification.md) — 本机完整实测:Bun compile 产物 60.5MiB/冷启动 ~8ms/常驻 RSS 26.4MiB,`--target=bun-linux-x64` 交叉编译成功产出合法 ELF(90.2MiB);**插件北极星核心机制验证成立**——编译产物内部 `Bun.spawn(process.execPath,...,{BUN_BE_BUN:"1"})` 可把 agent 现场写的外部 `.ts` 当子进程拉起,但插件 `import` npm 包严格要求 `node_modules` 在场、不会现场联网装包(04 票需处理);`bun:ffi`+`node:net` 拿 fd 调 `getpeereid()` 在 macOS 上完整打通、可作对端 UID 凭据来源;Node SEA/Deno compile 因不支持运行时执行外部脚本被文档级排除。基线假设成立,04 票可据此设计。
- [05 决定:dangerous 确认模型重设计](issues/05-dangerous-confirm-redesign.md) — 五问钉死,替代 ADR 0005 第 4 条:①**三层叠加**——无确认器默拒 fail-closed / 拒绝报文自带「人类如何完成」精确命令(agent 只转告)/ 有确认器走带外升级(确认永不过 agent 之手),`--yes` 永禁;②确认器长连接即在场、断线即降级、内核校验对端 UID;③TTY 交互确认禁止,CLI 永不阻塞保持;④跨端确认器只定协议插槽,V1 唯一实现 = mac 菜单栏壳,Linux 默拒即设计行为;⑤agent-delegation 审批收敛到内核统一仲裁。术语统一:**确认器**替代「确认代理」。
- [04 决定:内核边界与进程模型](issues/04-kernel-boundary-process-model.md) — 七问钉死:①**单 bin 多模式**(CLI 与内核同一编译产物,`a2 daemon run` 常驻模式——07 票定名);②常驻 = **系统托管+显式安装**(`a2 service install` 落 launchd/systemd user 单元,自启/自愈归系统,未装时 CLI 结构化指引、永不隐式拉起);③mihomo 挂**自己的 unit 系统托管+内核监督**(配置/reload/存活/启停),数据面不随控制面起落;④共存 = **检测并优先复用至实例级**(用户明确解除产品层「不接管用户 mihomo」约束;运行实例 API 接管但进程生死归原托管方、二进制只读复用、全无则脚本装锁定版本,升级永远显式);⑤旧可执行**全换不并行**(aahost 职责全迁 TS 内核、aa 被接替、aa-agent 挂起,Swift 逻辑+测试降为行为规范参考);⑥插件进程模型钉死(进程外 `.ts` 子进程,`BUN_BE_BUN` 拉起),协议/依赖/审批毕业成 13 票;⑦路径统一 **`~/.a2`**(A2_HOME 覆写;socket 父目录 0700+bind 后显式收权;原裁 `~/.aa`,随 07 票 a2 命名连动修订)。
- [06 决定:UI 壳新契约](issues/06-ui-shell-contract.md) — 四问钉死:①壳 = **对等客户端+角色注册**(确认器/订阅者皆为长连接上注册的角色),V1 不验签、同 UID 冒名记为已知边界、协议留身份强化字段;②状态同步 = **订阅推送**(全量快照+增量),壳模型 = 内核事件流投影,零轮询;③UI 资产**全套保留改喂养源**(模型/渲染器分离原封,快照测试继续当壳侧门禁,XcodeGen .app 工程保留——Touch ID/通知的 bundle 身份前提);④**V1 交付壳**,无壳 = 静默+日志+CLI 可查+dangerous 默拒,**「退出即还原」废除**、还原动作改挂内核显式命令,壳退出仅断连。
- [13 决定:插件协议与装载审批](issues/13-plugin-protocol-loading.md) — 三问钉死:①协议 = **exec 一次一调**(`describe` 出清单/schema/dangerous 声明,`call` stdin/stdout JSON,退出码即成败;agent→内核维持纯 CLI;**MCP 不进 V1**,将来 adapter 包装、时点归 08;V1 插件无事件面/常驻态为已知限制;multica 调研:无进程级插件先例,其 skill 生命周期作装载实施参考);②依赖 = **装载期 install+bundle、运行期全员单文件**(`bun build --target=bun` 打包工件,node_modules 即用即弃,怪包拒绝+指引,BUN_BE_BUN 跑 build 留实施首步 spike);③**装载零闸、调用层唯一仲裁**(`a2 plugin add` 即生效+审计推送,dangerous 只在 tool 调用层走 05 票三层——同 UID 模型下装载闸不新增防御)。
- [08 收图:ADR 批次修订 + 路线图修订](issues/08-adr-roadmap-revision.md) — 三问钉死并收图:①分发 = **单文件直接下载+curl 脚本**(Homebrew 列后续),GPL **重签校验废除**、关于页降级为外部程序声明、**`a2 about`+随包静态文本**为必有落点;②**ADR 批次七条**(新增总纲与插件协议两 ADR、0001/0002 废止重立、0005/0007 修订、agent-delegation spec 修订指令),正文撰写随 /to-spec 落地;③路线图:**Phase 1 出口 = 蓝图第⑤步**,17 票作行为规范参考,5 条人工项顺延⑤后按新形态重定义,**TS 门禁 = bun test+契约金标快照+壳快照+新 e2e**(428 断言按行为对等映射),MCP adapter 继续挂起;④收图检查通过,13/13 票 resolved,destination 到达。
- [07 决定:目标架构映射与迁移切法](issues/07-target-architecture-mapping.md) — 四问钉死:①**同仓 monorepo**(新增 `kernel/` TS 工程,Swift 壳留 `Sources/`,逻辑 target 降参考、切换后退场);②契约 **TS 为源**(zod 类 schema 导出 JSON Schema,Swift 手写 Codable 对照+金标报文快照防漂移,不设生成链);③命名 **a2 系**(用户裁定品牌级改名:bin `a2`、常驻 `a2 daemon run`、服务 `a2 service`、壳 `a2-panel`/「A2 Panel」;路径连动 `~/.a2`+`com.a2.*`,04 票⑦随之修订;shell 撞名命令行 shell,工程标识符弃用);④切步 **①契约骨架→②控制面→③mihomo 监督→④仲裁确认器→⑤壳原子切换(唯一门禁切换点)→⑥插件宿主**,每步门禁绿;红线等价物:插件=进程外+协议白名单,`a2-panel` 不得含业务逻辑。

## Not yet specified

(收图时清空——最后四条余项(分发/GPL 处置、MCP adapter 时点、TS 门禁口径、人工项落位)全部由 08 票裁决,见其 Answer。)

## Out of scope

- **重构的实施本身**:本图产出决定与蓝图;动代码按后续效fort开图拆票。
- **其他端的 UI**:用户明言先不做。
- **其他端内核的实际移植**:本图至多裁「是否/如何预留」,不做移植与多端构建。
- **既有暂缓清单**:TUN、内嵌 Codex、运行时第三方插件、市场、云、App Store、静默更新——继续暂缓。
- **v1-core-proxy 17 票与人工项的执行**:排期方向在 01 票裁,执行不在本图。
