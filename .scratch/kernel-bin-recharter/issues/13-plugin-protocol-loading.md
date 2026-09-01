# 13 — 决定:插件协议与装载审批

Type: grilling
Status: resolved

Blocked by: 04, 05

## Question

[10 票](10-kernel-language-decision.md)裁「agent 现场写插件」为北极星,[04 票](04-kernel-boundary-process-model.md)已钉进程模型层(插件 = 进程外 `.ts` 子进程,内核经 `BUN_BE_BUN` 自带运行时拉起,统一 `~/.a2` 路径约定——07 票 a2 命名定案后的口径)。本票裁三件强耦合的细活:

1. **协议形态**:插件↔内核的通信协议(stdio JSON-RPC?与 MCP 同构或直接采 MCP?)与能力面——插件能调内核什么、内核怎么向插件暴露 capability;registry 注册模型在「现场写」形态下怎么走(雾区「MCP adapter 时点」与此强相关,可顺带裁)。
2. **依赖机制**:插件 `import` npm 包严格要求 `node_modules` 在场、不会现场联网装包(11 票实测)——零依赖插件是否一等公民、npm 依赖经内核 `BUN_BE_BUN=1 bun install` 现场装的流程,及其网络/供应链风险面。
3. **装载审批**:agent 现场写的插件何时/怎么被批准运行——与 [05 票](05-dangerous-confirm-redesign.md)三层仲裁(默拒/拒绝即指引/确认器带外升级)怎么交接;插件声明 dangerous 能力的审批粒度。

## Answer

2026-08-04 现场面试三问钉死(用户逐项拍板;经两轮调研检验后用户推翻了我最初的 MCP 推荐,决策路径如实记录):

1. **协议 = exec 一次一调,`describe`/`call` 约定**。先把两条接口拆开:**agent→内核**维持纯 CLI(ADR 0005 既有立场:Bash 起子进程 `a2 … --json` 读 stdout,零协议零配置——multica 实证同型,其下游 agent 就这么调 `multica issue get … --output json`);**内核→插件**采最朴素的 exec 流:内核经 `BUN_BE_BUN` 拉起插件子进程,`plugin describe` 输出工具清单+schema+dangerous 声明(JSON),`plugin call <tool>` 参数 stdin JSON 进、结果 stdout JSON 出,退出码即成败(protoc/CNI 式成熟约定;Bun 冷启动 8ms 实测撑得住一次一调)。**MCP 不进 V1**(要配置、agent 反而要现学;将来若需对外可用 adapter 包装 exec 插件,时点归 08 票)。V1 插件**无事件面/无常驻态**,记为已知限制——壳所需事件全部源自内核自身状态(04 票 mihomo 监督在内核本体的推论),恰好不疼。注册模型:`a2 plugin add <path>` 登记进 registry。调研背书:业界命令面扩展 = exec 流(git/kubectl/cargo/gh),能力面扩展 = 常驻协议流(LSP/Terraform/MCP),agent 生态收敛 MCP;multica **无进程级插件**(扩展 = Markdown skills 提示词包 + MCP 配置透传给下游 CLI),不构成反例;其 skill 生命周期(`--on-conflict fail|overwrite|rename|skip`、多 root 优先级合并)作装载流程实施参考。
2. **依赖 = 装载期 install+bundle,运行期全员单文件**(用户提出的方案):零依赖单文件 `.ts` 直接登记(北极星主形态,Bun 内置 API 覆盖面大);带依赖插件(目录+`package.json`)在 `a2 plugin add` 时由内核 `BUN_BE_BUN` 临时 `bun install` + `bun build --target=bun` 打成单文件 JS 工件登记,node_modules 用完即弃;**运行期一律单文件**。边界:native addon(`.node`)/动态 require/外带资源的怪包打不进则拒绝+指引;`bun install` 默认不跑依赖 lifecycle scripts(供应链缓解);`BUN_BE_BUN` 下执行 `bun build` 属高置信推断(11 票未实测),**列为实施首步 spike**。
3. **装载零闸,调用层唯一仲裁**:`a2 plugin add` 即时生效——登记 + 审计事件(推送确认器/入日志,壳可见插件清单);dangerous 仲裁只在 **tool 调用层**(describe 声明 dangerous 的 tool 被调用时走 05 票三层)。依据:同 UID 威胁模型(02/06 票)——agent 本就能直接执行任意代码,装载闸不新增防御,只给北极星加摩擦(Linux 无确认器时每装一个插件都要人工转告)。
