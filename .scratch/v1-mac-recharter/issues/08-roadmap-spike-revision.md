# 08 — 阶段路线与 spike 清单修订

Type: grilling
Status: resolved
Blocked by: 04, 07

## Question

重写原调研文档 §11 的 Phase 0–4 与 §10 的 spike 清单，与用户定稿：

1. **Spike 定稿与顺序**（候选见「技术栈决定」票 Answer：宠物悬浮窗、capability 纵切含 CLI、Sparkle 更新链、Codex↔CLI 沙箱实测）；哪些必须在 Phase 0 完成、各自的通过/失败判据（含触发 Electron 回退候选的条件）。
2. **阶段划分**：平台骨架、宠物/提醒、代理插件的排期；代理插件是否提前（它是 agent-first 旗舰用例，也是用户当下刚需）。
3. **既有纵向设计的原生化改写清点**（原文档 §8 宠物/提醒）：哪些部分要按 Swift/原生词汇改写进新 spec。
4. **发布工程**（签名、公证、Sparkle、迁移备份）排入哪个 Phase。
5. **收图检查**：对照地图 Destination，确认产出齐备（ADR 批次、原文档处置、修订路线）；缺什么补什么，齐了则本图到达目的地。

产出：修订版阶段路线（替代原文档 §11），作为本图的收尾产物之一。

## Answer

**决定（2026-07-28，用户裁决四项，均取推荐）**，定稿落在 **`docs/v1-roadmap.md`**（取代原文档 §10/§11）：

1. **Spike 定稿**：Phase 0 三必做——S1 宠物悬浮窗（兼任「AI 自主改-编-测循环」实证）、S2 capability 纵切（注册表→菜单栏→aa CLI→UDS→dangerous 宿主确认全链）、S3 Codex↔CLI 沙箱实测（只出结论：UDS 放行与否，被拦则依序选备选）。Sparkle 更新链后移 Phase 3 首项；原 §10-2（Codex App Server）随前提 4 移除。最小签名仪式（证书/TCC/notarytool 凭据）Phase 0 一次做掉。各 spike 通过判据见路线文档。
2. **阶段划分**：代理插件提前首发——Phase 1 = 平台最小核 + 代理插件（agent-first 旗舰用例 + 用户刚需 + 覆盖面最全）；宠物/提醒退 Phase 2；验收 = 旗舰场景（Codex 开代理零打断、换订阅源必确认）。
3. **§8 原生化改写清点**：领域部分全保留（宠物高层能力面/任务状态驱动；提醒 once+cron/补发语义/presenter 回退），表现层改写（NSPanel+NSHostingView、NSStatusItem、UserNotifications、SwiftUI Preview+Fake host），Web 载体删除——保留/改写/删除三栏表在路线文档 Phase 2。
4. **发布工程**：拆两段——Phase 0 最小签名维持开发闭环；完整链（Developer ID、公证流水线、Sparkle、迁移备份、GPL 义务落地、冒烟集齐）为 Phase 3，首个对外分发前完成。
5. **回退条款**：仅三条结构性硬门触发回退 Electron+TS（宠物窗达不到参照水平 / AI 无法自主完成循环 / IPC 全拦无备选），Phase 0 收尾裁决一次，之后不回头；「开发慢」不触发。

**收图检查（对照 Destination）**：技术栈已锁（03/ADR 0002）✓；代理插件入首批且范围已定（04）✓；agent-first 方向已立（05/07/ADR 0005）✓；ADR 方向 → ADR 0001–0006 已成批草稿，且按本票检查补上代理缺口 **ADR 0007**（mihomo 子进程/锁版/GPL）✓；原文档处置 → 03 票清单 ✓；修订版路线 → `docs/v1-roadmap.md` ✓。产出齐备，**本图到达目的地**；ADR 全部 proposed，待用户过目后转 accepted。
