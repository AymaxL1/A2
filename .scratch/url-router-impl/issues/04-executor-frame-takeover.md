# 04 执行指令帧 + takeover/restore 编排

Status: claimed
Blocked by: 03

## Question

spec §5/§6.3:

- UDS 新增内核→壳执行指令帧 `set-default-handler`(schemes/bundleID/timeoutSeconds)
  与回执(confirmed/denied/timeout/error + perScheme);壳零判断,调
  `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`(禁旧 LS API),
  completion NSError 原样序列化回传。
- 内核编排:壳未装拒(guidance)/未跑 `open -b com.a2.panel` 拉起/等待 120s;
  错误面映射既有词表 —— `confirmation_unavailable`(2)/`confirmation_denied`(2)/
  `confirmation_timeout`(3);http+https 双框、部分成功报 `partial`;
  restore `--to` 覆写与目标缺失前置报错(先 urlForApplication 解析)。
- 施工期实测钉死(spec §11 遗留):用户取消时 completion 的 NSError 域/码记入票面。

验收:bun + swift test 绿;真机弹框旅程留到 06 票人工项,本票以假执行器测编排。

## Comments

- 2026-09-04 实施完毕(分支 `feature/url-router-04-executor-takeover`,三笔):
  - `695ec4d` feat(contract):执行指令帧那一族 + 确认模式标记
  - `f4dd97f` feat(kernel):takeover/restore 的真编排
  - `d0d7530` feat(panel):机械执行器(NSWorkspace 新 API,零判断,禁旧 LS API)

### 仲裁标记的实现方式(一句话)

`CapabilityDescriptorSchema` 加可选字段 `confirmation`(`confirm-agent` 缺省 / `os-dialog`,
契约可见、进 `capabilities list`),`registry.invoke` 的 dangerous 分支多一个条件
`confirmationModeOf(descriptor) === "confirm-agent"` —— 标 `os-dialog` 的跳过 confirm-agent
三层直接进 handler,由 handler 里那趟执行指令帧的往返充当确认仪式本身。
缺省归一只有一处(`confirmationModeOf`),它同时是 registry 的判据与门禁断言的判据。

### 「既有 dangerous 行为一个字不变」的断言落点(三处,由内到外)

1. `kernel/test/url-router-executor.test.ts`「**os-dialog 的名单恰好是那两条**」——
   拿**生产注册表的全量能力清单**筛 `confirmation === "os-dialog"`,断言排序后恰为
   `["url-router.restore", "url-router.takeover"]`。多一条即红。
2. 同文件「**既有 dangerous 能力一个字都没变**」—— 全量 dangerous 逐条断言
   `confirmationModeOf === "confirm-agent"` **且 `descriptor.confirmation === undefined`**
   (manifest 上根本没有这个字段才是"一个字没变"的字面意思);先断言 dangerous 表非空,
   免得这条断言在空集上假绿。
3. 同文件「行为对照」+ `kernel/test/cli-url-router.test.ts`「代理面照旧 fail-closed 默拒」——
   前者在同一个注册表里让两种 dangerous 并排跑(confirm-agent 那条:默拒 + handler
   一次都不被碰到 + 一次都没去问确认器;os-dialog 那条:直接进 handler),
   后者从最外面那条 CLI 缝再验一遍(`demo.wipe` 照旧 exit 2 / `confirmation_unavailable`)。
   另有一条:`capabilities list` 的机读面里,别的 dangerous 一律**不带** confirmation 字段。

### 与 02 票的差异:一条错误码退场

`url_router_executor_unwired` **退场**(不是保留)。04 票把执行链接上之后它永远不会再出现,
留一条不可达的码等于让 agent 为一个不存在的分支写代码 —— 与 mihomo 那两条退场码同一条口径,
在 `ErrorCode` 表上留了退场记录。它的三条真实出口是 `confirmation_unavailable` /
`confirmation_denied` / `confirmation_timeout`。

### CR 口径(三条值得复议的取舍)

1. **收场以 `perScheme` 为准,不以壳自报的 `outcome` 为准**。`denied` / `timeout` 两个词只有壳
   知道(照直映射),其余一律按逐 scheme 的事实数数:全成 / 全没成 / 成了一半。理由:
   `outcome` 是一句概括,`perScheme` 是逐条的事实;两者万一不一致(壳写错、将来加 scheme),
   以事实为准才不会报出"成功了但其实没有"。有用例专门喂一份自相矛盾的回执(壳说 confirmed、
   perScheme 只成一半),断言内核报 `url_router_partial_takeover`。
2. **「一个都没成」用 `capability_failed`(5),没有为它造新码**。票面要求「不造新码,除帧协议
   自身需要的」;`partial` 造了(它的下一步是"补齐",与"这件事没办成"不同,而且报文要带
   perScheme),而目标 app 不在的下一步永远是"把目标改对再来",一句 guidance 说得清。
3. **restore 的目标缺失由壳解析、内核映射**。spec §5 说「任何 LS 调用前结构化报错」,而
   `urlForApplication(withBundleIdentifier:)` 的真值只在壳那侧。内核**不预判**目标存在性
   (预判只会得到第二份可能过时的答案);壳执行的第一步就是解析,解析不到就
   `outcome:"error"` + 说清"目标 app 不存在"——**一个系统 API 都没调、一个框都没弹**,
   语义与「前置报错」等价,而真值只有一处。有用例断言"解析不到时 setter 一次都没被调"。

### 施工期实测钉死项 —— **未取得,留待 06 票真机人工项回填**

spec §11 要求钉死「用户取消时 completion 的 NSError 域/码」。**本票拿不到真机弹框**
(门禁绝不真调 `setDefaultApplication`),所以这两个值**没有人编造**:

* 壳侧因此**不判断** NSError 是不是"用户取消",本版只产出 `confirmed` / `error`;
* `denied` / `timeout` 两个取值已立在契约词表里,内核侧的映射与用例也已就位
  (喂一条 `outcome:"denied"` 的假回执 → `confirmation_denied` / 退出码 2);
* 06 票真机拿到域/码之后,壳只需在**一处**(`A2URLRouterExecutorRunner.Ledger.record`)
  加一个判断即可,协议一个字都不用改。那次改动要连同「谁来判」一起过一次 CR ——
  眼下有源码级断言禁止执行器认得任何具体的 domain/code。
* 金标样本里那份 `NSOSStatusErrorDomain / -10814` 是**占位**,样本 why 栏写明了。

### 门禁

* `kernel/`:`bun test` **629 条全绿**(597 pass + 32 skip,新增 21 条),`bun run typecheck` 干净;
  contract schema 已 `bun run schema` 随动,金标新增 10 份(7 valid + 3 invalid)。
* Swift:`swift build` **零 warning**,`swift test` **276 条全绿**(新增 17 条)。
* 两侧永不真改本机默认浏览器、永不真弹系统框:内核侧执行器整个是注入的假件,
  壳侧执行动作走 `A2DefaultHandlerSetting` 协议,CLI e2e 里那个"壳"是 `fake-client` 的替身。

### 与 spec 的偏差

**无偏差**。三处口径在 spec 允许的范围内做了具体化,已在上面「CR 口径」逐条记明
(perScheme 优先、`capability_failed` 复用、前置报错由壳的解析步承载)。
