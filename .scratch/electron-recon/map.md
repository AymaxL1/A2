# 地图:Electron 回退预研 — 不让 Xcode 卡 V1 进度

Labels: wayfinder:map
创建:2026-07-28(深夜;用户 AFK,按用户指令充图与研究票 AFK 并行,问题汇总留至 `questions-for-user.md`)

## Destination

一份事实齐备、可当面裁决的回退评估:在「初版尽快落地、不被 Xcode 卡进度」的新动机下(2026-07-28 深夜用户原话),把 ADR 0002(Swift 原生)的裁决理由逐条重检,给出 Electron+TS 路线对已锁定决策集(agent-first、注册表唯一调用面、代理插件首发、S1–S3 已验场景)的等价实现图景、代价清单与本机实测证据;所有需要用户拍板/澄清的问题一次性汇总为 `questions-for-user.md`。**是否翻案 ADR 0002 是 HITL 终裁票(09),不在 AFK 部分。**

## Notes

- **既有决定**:`docs/adr/0001–0007`(均 accepted)、`docs/v1-roadmap.md`、旧图 `.scratch/v1-mac-recharter/`。本图不重开的原则:local-first、构建时可信插件、注册表唯一调用面、agent-first、mihomo 子进程红线。
- **新动机(本图存在的理由)**:用户 2026-07-28:「我的诉求是希望把初版快速开发出来,不希望 Xcode 卡我进度」;更早消息:「Swift 要弄 Xcode 等编译环境非常麻烦,不够通用」。注意历史脉络:Phase 0 三 spike 全部通过、路线图三条回退硬门**均未触发**——本图是硬门框架之外的新裁决动机,不是硬门触发;终裁票须直面这层关系。
- **本机事实(2026-07-28 探针,详见 01 票)**:CLT 的 C/C++ 链健康(坏的只有 Swift 头);**Node 生态零安装**(白板,非损坏);codesign/notarytool 工具齐但钥匙串 0 签名身份;网络经本地代理 127.0.0.1:33888,npm registry 与 GitHub 均通。
- **分工(用户 2026-07-28 指令)**:Fable 5 主会话只做方案设计与决策;闭环操作(调研/探针/spike)由 Sonnet 5 子代理执行。
- **产物落点**:研究结论 `docs/research/electron-recon/<slug>.md`(本 worktree 分支);冒烟 spike 在 `Spikes/E1ElectronSmoke/`;HITL 票不 AFK 解决,其问题进 `.scratch/electron-recon/questions-for-user.md`。
- **tracker 约定**:`docs/agents/issue-tracker.md`。子代理只写自己的票文件与研究文档,**不改本文件**——Decisions so far 由主会话统一回写,避免并发覆盖。
- **文档语言**:中文。

## Decisions so far

<!-- 主会话在各票 resolved 后统一回写 -->

## Not yet specified

- **若翻案**:ADR 修订批次(0002 翻案文;0001 是否连动)、路线图与 Phase 0 spike 清单的 Electron 重排、原调研文档已废弃章节(§1/§3/§4.1 等)的复活修订、S1/S2 Swift 资产的处置方式。
- **若不翻案**:装 Xcode 一次性仪式的排程与验证清单;vfsoverlay 直编法在过渡期的去留。
- **「通用性」若指将来 Windows**:那是重画目的地的新效fort(见 Out of scope),这里只收集澄清信号(08 票)。

## Out of scope

- **实施本身**:真正的栈迁移/重写(或 Xcode 安装仪式)是终裁后的新效fort。
- **ADR 0001(Mac-only)的重开**:本图只澄清「通用性」动机,不裁决平台边界。
- **既有暂缓清单**:TUN、内嵌 Codex、运行时第三方插件、市场、云、App Store、静默更新等,全部维持暂缓。
- **Tauri**:维持出局(03 票裁决,用户不熟 Rust);本图不重开,除非用户明天主动提出。
