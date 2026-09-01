# 01 — ADR 批次七条与路线图修订

**What to build:** 把收图裁定的决策写成正式决策记录:七条 ADR 批次落笔(新增两条、废止重立两条、修订两条、一条 spec 修订指令),`docs/v1-roadmap.md` 出口判据按新架构重写。读者(人或 agent)翻 docs 即可完整理解新架构的 why 与边界,不必回读 wayfinder 地图。

**Blocked by:** None — can start immediately。

**Status:** done — 3bba450(+ CR 修复 8625b09) 七条 ADR 批次全部落笔(新增 0008–0011、0001/0002 标 superseded、0005/0007 修订、agent-delegation spec 附修订指令)+ v1-roadmap.md Phase 1 出口判据与门禁口径重写;门禁 PASS=429 FAIL=0;Fable 5 两轴 CR 已过(4 必修 1 酌情,已修)

- [x] 新增总纲 ADR「内核 bin 化与 UI 可选」:架构反转、CLI 唯一必需面、无 GUI 一等公民(dangerous 默拒)、裁决序(安全底线 > GPL > agent-first > 人类便利) → `docs/adr/0008-kernel-bin-ui-optional.md`(7 条 Decision,含壳契约、常驻形态、a2 命名)
- [x] ADR 0001 标 superseded,新 ADR 记「macOS+Linux 当下承诺、Windows 远景不设预留、UI 仅 Mac」 → 0001 frontmatter `status: superseded by ADR-0009` + 顶部废止说明;新文 `docs/adr/0009-kernel-platform-scope.md`
- [x] ADR 0002 标 superseded,新 ADR 记「TS 内核(Bun compile 单 bin 基线)+ Mac 壳 Swift;翻车复议运行时、不重开语言」 → 0002 frontmatter `status: superseded by ADR-0010` + 顶部废止说明(并注明重立的是内核语言、不是 UI 路线);新文 `docs/adr/0010-ts-kernel-bun-runtime.md`(含 Go/Rust 落选理由与账单)
- [x] ADR 0005 修订:第 4 条替换为三层仲裁模型(默拒 fail-closed / 拒绝即指引 / 确认器带外升级),长连接即在场、TTY 确认禁止、`--yes` 永禁;术语「确认器」入文 → 第 4 条整条重写 + 标题/引言更新 + 第 5 条(MCP 挂起)与 Consequences 连带更新 + 文末「修订记录(2026-08-04)」7 条;第 3 条只作术语对齐
- [x] ADR 0007 修订:mihomo 外部安装、义务面收缩为「调用外部程序」、重签校验废除、`a2 about`+随包静态文本为必有落点、独立子进程红线保留并泛化为插件通用边界 → 正文重写 + 文末「修订记录(2026-08-04)」7 条
- [x] 新增 ADR「插件 exec 协议与装载」:describe/call 约定、装载期 install+bundle、装载零闸调用层仲裁、MCP 挂起 → `docs/adr/0011-plugin-exec-protocol-loading.md`;另附「与 ADR 0003 的关系」节(行使 0003 自己预留的 supersede 范围条款),ADR 0003 同步加一条修订记录指回
- [x] agent-delegation spec 附修订指令(不改正文实现):审批收敛内核统一仲裁、执行器将来内核内 TS 重生、壳侧无专属通道 → `.scratch/agent-delegation/spec.md` 文末「修订指令(2026-08-04)」4 条(第 4 条如实记「发起方决定确认强度」本批未裁、继续挂 fog),顶部 Status 加读前提示;正文实现一字未改
- [x] `docs/v1-roadmap.md`:Phase 1 出口判据改为「蓝图第⑤步(壳原子切换)完成」;17 票价值转为行为规范参考;5 条人工项顺延⑤后按新形态重定义(签名→a2-panel.app、TCC/通知→确认器、实测→对 `a2` 重跑);门禁口径记 TS 门禁四件套 → Phase 1 整节重写(出口判据 6 条、六步切法表、门禁口径、在飞处置、人工项新形态表、Linux 口径);连带更新页首决策依据与现行 ADR 索引、总览表、Phase 0 历史注、Phase 2/3 落位、排期外(MCP 挂起、插件市场与本机插件的界分)
