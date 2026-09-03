# 03 快照 urlRouter 节 + 壳转发/兜底/通知

Status: resolved
Blocked by: 02

## Question

spec §6.1/§6.2/§7(除执行器):

- 内核:快照/增量推送新增 `urlRouter: {fallbackBrowserBundleID}` 节。
- 壳:kAEGetURL + `application(_:open:)` 注册;收到 URL 经 UDS 调 `url-router.route`
  (超时 1.5s);失败/超时走机械兜底(UserDefaults 快照值 → com.apple.Safari),
  宕机后首次兜底弹节流通知,UDS 重连成功重置;快照落 UserDefaults
  `urlRouter.fallbackBrowserBundleID`。
- 03 研究票四条硬边界是红线:壳不解析 URL、不匹配域名、唯一分支=内核可达、
  永不读内核文件 —— swift test 加反向断言可加则加。
- 本票**不**改 Info.plist(归 05 票,连门禁断言一起)—— 壳代码先行,注册后置。

验收:swift test 绿(转发/兜底/节流有测试);bun test 绿(快照节)。

## Comments

### 2026-09-04 施工完毕(分支 `feature/url-router-03-snapshot-shell`)

提交(四笔,末笔即本条):

| 哈希 | 内容 |
|---|---|
| `fb279f4` | fix(contract):url-router 六族契约补进 Swift 镜像范围表 —— **02 票遗留的门禁红**(见下) |
| `c37c121` | feat(kernel):快照 `urlRouter` 节 + 契约两侧金标/schema 随动 + kernel 测试 4 条 |
| `d621a90` | feat(panel):URL 事件转发 / 机械兜底 / 节流通知 + swift 测试 21 条 |
| (本条) | docs(scratch):票面完成记录 |

门禁(worktree 内跑,最终树):

* `bun test` **552 pass / 0 fail**(584 ran,32 skip)—— 基线 547,本票 **+5**
  (cli-url-router 4 条 + 新增的一份非法金标样本自动成一条);`bun run typecheck` 干净。
* `swift build` **零 warning**;`swift test` **259 passed / 0 fail** —— 基线 237 且**红着两条**
  (02 票遗留),本票 **+22**(21 条壳侧 + 1 条契约松紧)并把那两条修绿。

四条硬边界的落点(代码 / 断言各一句):

1. **不解析 URL 内容** —— `A2URLForwarder` 里 URL 只有 `String` 一种类型,`URL(string:)` 仅在
   `A2URLRouterMacOS`(NSWorkspace 入参)出现且源码写明「只是装箱」;断言:五种畸形/带片段/带中文
   URL 逐字节原样转发 + 源码级反向 grep(`URLComponents` / `.host` / `.scheme` / `hasSuffix` …
   在壳的分流代码里一次都不许出现)。
2. **不做域名匹配** —— 分流域名表不在壳的知识里(快照那一节只给一个 bundle id);断言:同上那张
   记号表含 `routedDomains` / `claude.ai` / `Roxy`,命中即红。
3. **唯一分支条件 = 内核可达与否** —— `A2URLRouteOutcome` 三值,兜底只有一个触发口
   `fallback(_:notify:)`;断言:「兜底的调用点恰好两处(refused / unreachable)」的源码计数断言 +
   routed 什么都不做 / refused 兜底但不通知 / unreachable 兜底且通知三条行为断言。
4. **配置知识只来自内核推送快照,永不读内核文件** —— 投影路径顺手把快照值写进 UserDefaults
   (`urlRouter.fallbackBrowserBundleID`,com.a2.panel 域),兜底读它、没有才用硬编码 Safari;
   断言:落盘只在变了时写、从没快照时退到 Safari,外加源码级反向 grep(`url-router.json` /
   `A2_HOME` / `FileManager` / `Data(contentsOf` 一次都不许出现)。

CR 口径(逐条请复核):

* **快照那一节是「现读」而不是缓存**,且读的时机在 `hub.register` **之前** —— 因为
  「`roles.register` 的响应是本连接第一帧」是协议保证,注册之后再 await 就会让别的连接触发的推送
  挤到响应前头。为此 runtime 上多了一个单独的口 `urlRouterSnapshot()`,`snapshot(urlRouter)` 仍是
  同步的(理由写在两处头注里)。
* **refused 也兜底,但不发通知**:通知原文是「A2 内核未运行」,内核明明在跑时弹它就是撒谎;
  而「链接永远打得开」要求那一路照样兜底。分支依据仍与 URL 无关(边界③不破)。
* **多做了两处小机械件,都在源码里写了理由**,请裁是否留:
  ① 兜底第二级(配的浏览器解析不到 → 退到硬编码 Safari)与**熄火窗**(同一条 URL 刚交给过系统缺省
  handler 就不再交第二次)—— 冲的是「A2 Panel 自己就是默认浏览器时,最后一级会把链接弹回自己」
  这条真实的打转风险;② kAEGetURL 与 `application(_:open:)` 两条投递路的**按字符串去重**(0.5s 窗)
  —— 谁先谁后由 AppKit 定,不去重则同一次点击可能开两个标签页。两者都只做字符串相等 + 看表。
* **转发的收场由发起方计时**(`A2URLRouteTicket` + 看门狗线程),而不是指望连接那侧报错:内核不可达
  时会话线程睡在重连间隔里,队列根本不会被翻。收场保证**恰好一次**(否则内核回来后同一条链接会被
  开第二次),有单测钉着;另有一条用真 `A2PanelSession`(socket 指向不存在的路径)的用例证明
  1.5s 那一档确实兜住了。
* **02 票遗留的门禁红**:02 登记了 url-router 六族契约却没在 Swift 镜像范围表里记账,
  `swift test` 自那时起一直红两条。本票判定为「有意不镜像」并逐条写了理由(壳只需要快照里那一个
  字段;route 的 output 壳一个字段都不读)。若 04 票要让壳读 handoff result,那张表要随之改判。

遗留(不在本票):Info.plist 的 `CFBundleURLTypes` 注册与门禁断言归 05 票 —— 在那之前壳代码先行,
本票的覆盖靠手工触发路径 + 单测;通知授权仪式是人工项(没授权即静默跳过,有 best-effort 分支)。

### 2026-09-04 CR(Fable 主循环,双轴):通过,四处偏差全部追认 → resolved

三级兜底 + 熄火窗 + 双投递去重 + refused 也兜底(不通知)—— 全部是内容盲的机械规则,分支
依据从不涉及 URL 内容,红线灵魂不破;熄火窗实为 spec 漏掉的必需安全阀(A2 Panel 自己是默认
浏览器时的打转风险真实存在)。**硬性后果记账**:06 票写 ADR 0008 豁免正文时,兜底触发口措辞
从「内核不可达」扩为「内核不可达,或内核如实答复『没能把链接交出去』」,节流通知仅限不可达;
spec §7 同步补修正案。02 遗留门禁红的补账(镜像范围表)追认——CR 流程自此两侧测试都跑。
复核实测 bun 552/0 + swift 259/0。ff 合入 main = 24f2fa9,分支已删。
