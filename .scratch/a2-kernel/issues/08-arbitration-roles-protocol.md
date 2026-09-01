# 08 — dangerous 三层仲裁 + 角色注册与订阅推送协议

**What to build:** 蓝图第④步。dangerous 仲裁从「一律默拒」长成完整三层模型,协议面长出角色注册与订阅推送:客户端在 UDS 长连接上注册 confirm-agent(确认器)或 subscriber(订阅者)角色;确认器在场(=长连接在)时 dangerous 升级为带外确认,断线立即降回默拒;订阅者连上先收全量快照、之后增量推送。内核校验对端 UID。壳尚未接入,用测试夹具客户端验收协议——Linux 无确认器形态在本票先天成立。

**Blocked by:** 04(控制面)。

**Status:** done — 48c4915

- [x] 三层行为齐备:无确认器默拒 `confirmation_unavailable`(fail-closed);拒绝报文带机器可读「人类如何完成」命令;确认器在场时 dangerous 请求经带外确认后放行,确认内容不出现在发起方 CLI 通路上
  - 第①层报文**一字未改**(04 票承诺兑现,金标 `response-confirmation-unavailable.json` 原样);第③层新增 `confirmation_denied`(退出码 2)与 `confirmation_timeout`(退出码 3,3 的唯一产出面)。
  - 「确认内容不出现在发起方 CLI 通路上」有活体断言:批准后的 stdout 里既没有确认器的名字,也没有那条确认请求的 id。
  - 三码**都必带 guidance**,由 `ConfirmationErrorSchema`(`WireError` 的收窄版)在契约层强制,不是靠注释;另有三条「活体报文 ≡ 金标(除 id/路径/超时窗口值)」对照断言。
- [x] 角色注册协议落契约:confirm-agent / subscriber 在长连接上注册,预留身份强化字段(V1 不验签,已知边界记录在案);连接断开即视为离场,进行中的 dangerous 请求立即按默拒收尾
  - `roles.register` op + `ClientRole`/`ClientIdentity` 契约;`codeDirectoryHash`/`teamIdentifier` 两个插槽**收下不校验**,「同 UID 冒充」写进 `wire.ts` 该节头注、`ADR 0008` 已有对应决策,并有一条活体断言(冒名注册**成功**,而审计里自称的 name 与验过的 uid 分开记)。
  - 断线即离场:`server.ts` 的 `close` 回调摘角色 → `arbiter.rosterChanged()` → 确认器归零就把在途请求按 `confirmation_unavailable` 收尾(审计 `downgraded`),**不等超时**(断言用 60s 窗口把关:若降级没生效,测试只会超时红)。
- [x] 对端 UID 校验:经 `getpeereid`(macOS)/`SO_PEERCRED`(Linux)取凭据,非同 UID 连接拒绝
  - `daemon/peer.ts`:macOS 分支**实测打通**(顺带更正了研究文档 §4.4 的一条口径 —— `Bun.listen` 的 Socket 本身就有 `fd` 取值器,不必换 `node:net`);Linux 分支代码 + 类型覆盖,**实机验收随 5 条人工项顺延**(与既有 Linux 口径一致)。
  - 活体拒绝路径经 `A2_PEER_EXPECT_UID` 验证 —— 这个开关**只能让校验更严**(把期望值换成别的 uid,结果是连自己都被拒),没有任何写法能让外来 uid 被放行。
  - 取不到凭据时的处置**如实记账**:放行 + stderr 大声留痕,理由写在 `peer.ts` 文件头(前两道门 `run/` 0700 与 socket 0600 由 OS 强制,别的用户 connect() 就进不来;把整个内核锁死不是 fail-closed,是不可用)。
- [x] 订阅推送打通:subscriber 连上收全量状态快照,此后代理状态/节点/mihomo 存活变化增量推送,零轮询;快照与推送报文入契约金标样本
  - 快照 = `status` + 能力全集 + 仲裁面 + 存活监督 + 审计,**注册与首帧快照同一次往返**(没有"注册成功但还没拿到状态"的中间态)。
  - 增量五族:`arbitration` / `confirmation`(只给确认器)/ `confirmation-pending`(只给发起方)/ `audit` / `supervision` / `capability`。代理状态与节点变化走 `capability` 事件(**带 output**,订阅者直接投影);mihomo 存活变化走 `supervision` 事件(07 票的载荷形状一字未改,有「推送 ≡ 查询」逐字段相等断言)。
  - 零轮询有实证:订阅者整场只发过一条 `roles.register`,却收得到全部变化;safe 档**一条事件都不产**(不制造噪音)。
  - 金标 23 份新样本(含 6 份 PushEnvelope、KernelSnapshot、ConfirmationRequest/PendingConfirmation 等)+ JSON Schema 40 份。
- [x] dangerous 全流程产出审计事件(日志 + 推送);`--yes` 与 TTY 交互确认在全命令面不存在;仲裁行为断言映射入 `bun test`
  - 审计 11 个动作词表封闭,NDJSON 落 `<A2_HOME>/log/arbitration.log` + 推送 + `a2 arbitration status`(safe 能力,**没有确认器时照样查得动**,否则就成了死锁)。请求与收场**配对可查**(同一个 confirmation id)。
  - `--yes` 在 **7 条命令面**上逐条验过一遍(全部 exit 1 + `usage`),且确认器在场也不会偷偷触发一次确认;「内核里没有任何读 stdin / 认 TTY 的代码」是**结构性断言**(扫 `src/**/*.ts`,唯一提到 isatty 的地方是帮助文本里的禁令)。
  - 「Linux 形态由构造保证」也是结构性断言:协议与仲裁 6 个文件里没有任何平台分支,平台差异只住在 `peer.ts`。

## 落地清单

**新增**:`src/daemon/{peer,hub,audit,arbitration}.ts`、`src/capability/arbitration.ts`、`test/support/fake-client.ts`、`test/cli-arbitration.test.ts`、23 份金标样本 + 14 份 JSON Schema。
**改动**:`contract/{wire,emit,exit-codes}.ts`、`daemon/{server,router,runtime}.ts`、`client/uds-client.ts`、`capability/registry.ts`、`proxy/supervision.ts`、`cli/{main,domain,usage}.ts`、`test/support/harness.ts`(独立地跟着改长连接)、`test/cli-{subscriptions,supervision}.test.ts`(补 07 票留的账)。

## 本票裁定的几件事(供 CR 复核)

1. **退出码 3 归 `confirmation_timeout`**,且语义改判:旧的 3 是「客户端等 socket 等腻了」,新的 3 是「人没在窗口内做决定」。传输层等不到响应仍归 4。
2. **旧 `pending` 态 + `capabilities.result` op 整体淘汰**(不是顺延):改用自描述的 `confirmation-pending` 推送帧延长客户端等待 —— 一次往返、零轮询,且确认窗口的一致性由协议保证而不是两个进程读同一个环境变量。已知限制:等确认期间那条连接占着。
3. **在途降级复用 `confirmation_unavailable`**:对发起方而言「一个确认器都没有」与「刚才有、现在没了」是同一件事,客户端不该为此多写一个分支。
4. **04 票 CR 遗留两小项**:(a) `wire.ts` 的 `guidance` 注释改说实话(包封层可选,因为 `unknown_op` 这类本来就没有指引可言),真正必带的那一族由 `ConfirmationErrorSchema` **在 schema 上强制**,配一份 invalid 金标;(b)「活体 ≡ 金标」对照断言已补(三条)。
5. **`arbitration.status` 定为 safe 能力 + `a2 arbitration status` 域子命令**:仲裁面是 daemon 进程内状态,只能经注册表拿;定 safe 是因为「没有确认器时连查都查不了」会成死锁。

## CR 修复(2026-08-05,Fable 5 两轴)

**UID fail-open 裁定:接受**(仲裁保护受认可路径,不对抗同 UID 敌意进程;fail-closed 是零收益换不可用),但有整改。10 项全做完:

| # | 项 | 处置 |
|---|---|---|
| 1 | **读侧多字节解码洞**(真缺陷) | `LineBuffer` 改**字节级**:按 `\n`(0x0A)切,**整行到齐才 decode**。三个消费点同步(server / uds-client / 两个测试夹具**各自独立**改)。补 5 条断言,含"把一个汉字精确切在分片边界上"与"逐字节喂一整帧" |
| 2 | **写队列无界 + O(n) 合并**(真缺陷) | 抽出 `daemon/writer.ts`:队列 = **数组 + 游标**(`send` 摊还 O(1),不再每次 concat);积压上限 4 MiB,超限 = 判定慢消费者 → 断连 + `backpressure_dropped` 审计。补 4 条断言(半写接住 / 先进先出 / 超限只叫一次且清干净 / 正常消费者不累积) |
| 3 | **发起方断连不收尾在途**(真缺陷) | `PendingEntry` 记 `requester`;连接 `close` → `arbiter.cancelFor()` 取消它发起的在途确认。收场方式选**最简那种**(CR 允许二选一):不新增事件族,照走 `finish` 统一出口 → 确认器收到 `arbitration`(待办清空)+ `audit`(`cancelled`),它若拿旧 id 来 resolve 得到 `confirmation_unknown` —— 那条报文早已把「发起方已断开」列为收场原因,现在名副其实。补 1 条断言(含"handler 一次都没跑"的反证) |
| 4 | **逐连接静默 fail-open** | `judgePeer` 返回三种 `unverified` 原因(`fd-unavailable` / `reader-unavailable` / `credential-unreadable`);`createUnverifiedPeerLog` **按原因去重 + 60s 限频 + 带累计数**,每次都记 `peer_unverified` 审计。纯逻辑可单测(时钟是参数),补 1 条断言 |
| 5 | **已知边界入 ADR** | ADR 0005 加「实施补记:在场机制的两条已知边界」(同 UID 冒充 / fail-open 各一条,引 06 票威胁模型口径并标未入库);ADR 0008 加「实施补记:安全边界的显式范围」(保护谁 / 不保护谁 / UID 校验的定位) |
| 6 | **注册顺序语义钉死** | 快照**先取**(含注册者自己),进场事件**不推给注册者自己**(`hub.broadcast(event, except)` + `audit.record(…, {exceptPush})`),别人照收。契约文字进 `KernelSnapshotSchema` 头注:「快照即基线,此后才是增量」。补 1 条断言(第一帧必须是响应 + 自己收不到自己的进场 + 别人收得到) |
| 7 | `A2_PEER_EXPECT_UID` 措辞与实现 | 表述改准确:「**只能替换那个唯一允许值,不能扩集、不能关**」;实现里**显式拒绝 0**(root 该走 OS 门)与任何非正整数,覆写作废并落一行 stderr。补 2 条断言(纯函数 + CLI 缝) |
| 8 | peer.ts 错引 ADR | 「ADR 0008 第 7 条」(那是命名与路径)→ 改为 **ADR 0005 修订后第 4 条** |
| 9 | 研究文档引用标注 | `ts-kernel-runtime-bun.md` 的两处引用都标「**未入库**」 |
| 10 | `as unknown as JsonValue` | `payload()` 从 `capability/proxy.ts` 提到 `contract/wire.ts` 导出,router / capability/arbitration / proxy 三处共用;**全内核只剩这一次类型放行** |

**契约增补(09 票需同步)**:报文**形状一字未改**,但 `AuditAction` 封闭词表**加了三个取值** —— `cancelled` / `peer_unverified` / `backpressure_dropped`(逐条理由见 `swift-parity-map.md` 08 节 C 段)。JSON Schema 已重导出;金标样本无需改(现有样本的取值都还在表上,invalid 样本仍非法)。

**CR 后门禁**:`bun test` 248 → **262 pass / 0 fail**(14 个文件;源码 + 编译产物两遍);`tsc` 干净。**新增三次变异验证**:①退回逐片 decode → 2 红;②进场事件也推给自己 → 1 红;③发起方断线不取消 → 1 红。

## 做不到 / 顺延

- **Linux `SO_PEERCRED` 未实机验证**(代码 + 类型 + 无平台分支断言进门禁),随 5 条人工项顺延。
- **真确认器(菜单栏壳)不在本票**:协议由假确认器/假订阅者夹具验收,壳是 09/10 票。
