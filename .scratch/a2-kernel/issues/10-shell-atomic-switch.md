# 10 — 壳原子切换:a2-panel 接新内核、旧可执行退场、门禁切换

**What to build:** 蓝图第⑤步——唯一门禁切换点,**完成即 Phase 1 出口**。菜单栏壳更名 `a2-panel`(.app 显示名「A2 Panel」),喂养源原子切换:模型从直读 runtime 改为内核事件流投影(09 票客户端层),确认器角色上岗(点按/Touch ID 呈现确认);「一个模型两个渲染器」与手搓快照测试原封平移。`aahost`/`aa`/`aa-agent` 及其逻辑 target 退场;门禁由 `check.sh` 原子切至 TS 门禁四件套,flagship e2e 对 `a2` 重写。

**Blocked by:** 07(代理控制面)、09(契约对照层)。

**Status:** done — 288f528(接线)+ 4678692(退场与门禁切换)+ 本次收口提交

- [x] `a2-panel` 以对等客户端接入内核:subscriber 投影驱动菜单栏状态(零轮询),confirm-agent 呈现 dangerous 确认;壳内不含业务逻辑(红线),仅事件投影+确认呈现
- [x] 壳退出仅断连:代理照跑,内核收到断线立即把 dangerous 降回默拒;壳缺席时事件入日志、CLI 可查
- [x] 旧可执行 `aahost`/`aa`/`aa-agent` 及其逻辑 target 从构建图退场;Swift 包收敛为壳 target 群(a2-panel + UI 资产 + 契约对照)
- [x] 壳快照测试全量跟切并保绿;.app 以 a2-panel 身份出包(签名/TCC 人工项顺延不阻塞)**〔勾选注记(11 票 CR 尾款 b,2026-08-05):票面原文写的是「XcodeGen .app 工程」,实际交付物是 `Scripts/build-app.sh` 直接出包 —— 本机无 Xcode 故 `.xcodeproj` 没有消费者(见偏差 3)。验收实质(以 a2-panel 身份出包 + 结构/签名核验进门禁)已达成,勾的是它。〕**
- [x] flagship e2e 重写为对真实 `a2` bin + 假 mihomo 的端到端旗舰场景(agent 开代理/切节点零打断、订阅源变更触发确认器/无确认器默拒)
- [x] 门禁原子切换:**旧引擎退役、入口与接口保留**(`bash Scripts/check.sh` 一条命令全绿),新门禁 = `bun test` + 契约金标快照 + 壳快照 + 新 flagship e2e;宣布 Phase 1 出口达成**〔勾选注记(11 票 CR 尾款 b):票面原文「`check.sh` 退役」与交付不符 —— 退役的是 `Scripts/check/` 那套旧引擎,入口脚本一直在(偏差 1 已如实记)。roadmap 判据 6 同步改字。〕**

## 逐框证据

**框 1(接内核)**:`Sources/A2Panel`(纯逻辑:模型/构造器/投影/会话/确认呈现)+ `A2PanelMacOS`(两个渲染器 + 确认器窗 + 关于页 + 装配)。注册 confirm-agent 一次往返拿全量快照,六族增量事件叠加。**零轮询有实证**:旗舰 e2e `PANEL_IDLE: before=4 after=4`(空闲 2 秒里壳发出的请求数一条不涨)。**壳内零业务逻辑**:`capability` 事件只产出「重读那三条 safe 能力」这一个效应,绝不自己把 `SubscriptionChangeResult` 叠进本地清单(有专门一条断言 ▸ capability 事件不被壳自己解读)。

**框 2(退出仅断连)**:`applicationWillTerminate` 只 `session.stop()`;旗舰 e2e 幕 4 断言 4-1(壳一断连内核当场判定确认器不在场)、4-2/4-3(下一条 dangerous 回到第①层 `confirmation_unavailable`)、4-5/4-6/4-7(代理照跑:`proxy status` 照答话、`running=true`、mihomo pid 全程没变且此刻还活着)、4-8/4-9/4-10(事件仍落 NDJSON、`a2 arbitration status` 查得到默拒与 `confirmer_left`)。

**框 3(退场)**:16 个 target(22444 行)+ `Scripts/check/` 整棵 + `Snapshots/menubar/` + 随包 GPL 二进制。`Package.swift` 收敛为 `A2Contract` / `A2KernelClient` / `A2Panel` / `A2PanelMacOS` / `A2PanelFixtures` + 三个可执行(只有 `a2-panel` 进 products)。旧断言逐条落定见 `kernel/test/swift-parity-map.md`「10 票收口」。

**框 4(快照跟切 + 出包)**:`Tests/A2PanelSnapshotTests`(**判据搬进 swift test**),golden 在 `Snapshots/a2-panel/`,**四态**(比 14 票多一态:与内核断连)。`Scripts/build-app.sh` 出 `A2 Panel.app`(bundle id `com.a2.panel`)+ ad-hoc 签名 + 8 条结构/签名核验,进门禁第④步。

**框 5(flagship e2e)**:`Scripts/a2-flagship-e2e.sh` 六幕 46 条。真 `a2` bin(`kernel/dist/a2`)+ 假 mihomo + 壳的真代码路径(`a2-panel-probe` 复用 `A2Panel` 全套)。

**框 6(门禁切换)**:`Scripts/check.sh` 换引擎、**接口逐字不变**。`bash Scripts/check.sh` → 步 PASS=6 FAIL=0。

## Phase 1 出口 6 条判据自查(2026-08-05)

| # | 判据 | 结论 | 证据 |
|---|---|---|---|
| 1 | 单 bin `a2` 承担全部主逻辑 | **达成** | Swift 侧已无任何业务逻辑;`bun test` 263 条 |
| 2 | `a2 service …` + 系统托管 + 永不隐式拉起 | **达成** | 05 票 + 真 launchctl 活体冒烟 28/28 |
| 3 | mihomo 监督面在位 | **达成(一条如实缺口)** | 06/07 票;缺口 = 全程假 mihomo,「真 mihomo 接受这份配置」无自动化断言 → 顺延人工项(对等映射表 10 票 G 组) |
| 4 | 三层仲裁与确认器协议在位 | **达成** | 08 票 + 旗舰 e2e 幕 2/3/4 对真内核 + 真壳跑通三条收场 |
| 5 | `a2-panel` 接新内核,旧三可执行废除 | **达成** | 本票框 1/2/3 |
| 6 | 门禁原子切换,`check.sh` 退役 | **达成(口径微调)** | 旧引擎整棵退场;**入口路径保留**、接口逐字不变(11 票「换引擎接口不变」的先例) |

**结论:Phase 1 出口达成。** 不含 5 条人工项、四条做不到项、agent-delegation 那 8 条排期未定的顺延账。

## 偏差 / 做不到项(如实)

1. **门禁入口路径没删**。票面写「`check.sh` 退役」;实际是**引擎退役、入口保留**(与 11 票同一种安排:接口是契约,实现可换)。删掉入口只会让所有记着这条命令的人/文档失效,而门禁的「一条命令」本来就是那条接口。roadmap 与脚本头注都按这个口径改写了。
2. **门禁比四件套多三步**:`tsc --noEmit`、`swift build` 零 warning、`.app` 出包核验。前两条此前散在 nightlog 与旧 `check/build.sh` 里,收进同一条命令;第三条是验收框 4 的要求。都不改「一条命令、清楚 PASS/FAIL」这条接口。
3. **XcodeGen 仍未使用**(12 票的范围变更原样继承):本机无 Xcode → 无 `xcodebuild` → `.xcodeproj` 无消费者。产物是 `Scripts/build-app.sh`。
4. **两条 GUI 事实没有自动化断言**:①「人点了菜单项、AppKit 真把 action 发出去」;②「双击 `.app` 真能起来并挂上状态栏」。14 票靠两个 `#if AA_TESTING` env seam 摸到了①的一半,新壳**一个测试专用 seam 都没有**(人的替身住在独立可执行 `a2-panel-probe` 里),故如实记为做不到项,归人工项。
   **未测带的边界比上面那两句更宽(11 票 CR 尾款 d 补记,2026-08-05)**:①里 `actionTapped` → `session.call` 的**接线本身**、以及菜单项发起 `proxy.subscription.add` 时**参数怎么收集**(弹输入框、取值、拼 input),同样没有任何自动化断言 —— `a2-panel-probe` 走的是投影与确认那半边,不点菜单项、也不收参数。也就是说「点了之后调对了哪条能力、带了什么参数」这段目前只有人眼验过。归同一条人工项。
5. **真 mihomo 的 REST 语义无兜底**(新出现的缺口,见判据 3)。
   **一个候选补法(11 票 CR 建议,2026-08-05 只记文字、未实现)**:给旗舰 e2e 加 env seam `A2_REAL_MIHOMO_BIN=<路径>`,有它时多跑一幕真核 —— 真 mihomo 接受 a2 渲染的 `config.yaml`,再拿三条 REST 与我们的客户端逐条对照;并把那次人工实测的**真回包**收进金标,用来钉住 `kernel/test/support/fake-mihomo` 这份假件。**需用户裁定**:本机跑着用户自己的 mihomo(绝不触碰是施工红线),这一幕只能在用户另行指定的二进制上跑。同文也记在 `docs/v1-roadmap.md` 人工项一节。
6. **agent-delegation 的 89+21 条断言顺延到一份没有排期的 spec**:本 spec 的迁移六步表里没有它的位置。这是撞上的一处 spec 遗漏,已在对等映射表 A 组与 roadmap 里如实记明 —— 要不要单立票由用户/编排者裁。
7. **随包的 43MiB GPL mihomo 二进制被删除**(ADR 0007 修订版:不再分发 GPL 二进制)。两样跟着搬家而不是丢掉:锁版实测记录 → `kernel/contract/MIHOMO-VERSION.txt`(`cli-mihomo.test.ts` 的同源断言随之改路径);GPL-3.0 全文 → `docs/legal/`。
8. **bundle id 从 `com.aa.host` 换成 `com.a2.panel`**(aa 系命名全面退场)。换 id 的代价通常是 TCC 授权重置,但旧 id 从未上过真证书也从未授过权,此刻代价为零。授权仪式(人工项 3)要对着新 id 做。
9. **未联网;未 launchctl 任何真 unit;未删 CLT;用户 mihomo(33888)全程未碰**。
