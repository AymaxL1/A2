# 16 — 旗舰场景验收(Phase 1 出口)

**What to build:** 验收辞逐字兑现:「Codex 经 `aa` 开代理/切节点全程零 GUI 打断;换订阅源必触发宿主确认」。产出 E2E 验收脚本(模拟 agent 只经 `aa` 完成 开代理→切模式→选节点→更新已有订阅 全链,断言零确认弹窗、输出与退出码全对)+ 真 Codex 实测记录(含 prefix_rule 一次批准后沙箱外执行的完整路径)+ 换源场景批准/拒绝两分支点验记录。

**Blocked by:** 05, 07, 09, 10, 12

**Status:** **脚本部分 done(2026-08-04);两条人工实测未做 → Phase 1 出口尚未达成。**
原票面的限定**继续有效,不因本次改动而放宽**:「**正式验收以 `.app` 形态为准**」——
今晚这条 E2E 跑的是 `swift build` 出的裸可执行(`$BIN/aa` + `$HOST_BIN`),不是 12 票打出来的 `.app`。
故它证明的是「能力链本身通」,**不是**「装好的 `.app` 里这条链通」。后者要等 13 票签名仪式落地、
以 `.app` 形态重跑一遍,才算正式验收。(双轴 CR 抓到这条限定在 Status 行里丢了,补回。)

**验证环:** 脚本部分已在门禁里跑通(`bash Scripts/check.sh` PASS=428 FAIL=0);正式验收仍需人在场(真 Codex + 真弹窗)。

- [x] E2E 脚本:normal 全链零 GUI 打断,全程仅经 `aa`,断言逐步输出与退出码
      → `Scripts/check/flagship-e2e.sh`(断言组 FS,5 条),排在 `menubar.sh` 之后、`mihomo-real-e2e.sh` 之前。
- [ ] 真 Codex 按 `aa docs agents-md` 引导接入,prefix_rule 一次批准后完成旗舰操作,留实测记录
      → **未做,必须有人在场**。理由见下「为什么这两条今晚不能做」。
- [ ] 换源:Codex 发起 → 宿主弹确认;批准/拒绝两分支行为与记录齐全
      → **未做,必须有人在场**。门禁里走的是 `AA_CONFIRM_AUTO` 这条 test-only seam,**没有任何一次真 NSAlert 被人看见过**。
- [~] 验收结论回写 roadmap Phase 1 状态行(通过即 Phase 1 出口)
      → 已回写 `docs/v1-roadmap.md` Phase 1「验收 = 旗舰场景」段,**如实写明出口尚未达成**;
        **没有**回写成"通过"—— 上面两条人工项没做完,Phase 1 出口就不成立。

---

## 做了什么(脚本部分)

### `Scripts/check/flagship-e2e.sh` —— 断言组 FS(恰好 5 条,任何失败路径下条数不变)

**这一组的独特价值不是"再测一遍各能力"**(06/07/09/10 已逐条测过),而是把它们串成验收辞描述的
那一条真实路径,并断言「零 GUI 打断」这件**整体性质**(单条能力各自不弹窗 ≠ 整条链跑下来没弹过窗)。

* 前置(**不属于旗舰链**):用一个独立的、带 `AA_CONFIRM_AUTO=approve` 的宿主装上并激活一个订阅
  ——验收辞里的链是「更新**已有**订阅」,新增/换源才是 dangerous 那条。装完即关,日志窗口另起。
* 旗舰链:**一个宿主实例**,**不带** `AA_CONFIRM_AUTO`,九步全部经 `aa` 域子命令:
  `subscription list`(发现 id,不硬编码)→ `proxy on` → `proxy mode --mode global`(+读回)
  → `proxy node --group PROXY --node FS-B`(+读回)→ `proxy subscription update`(+两次读回)。
  第 4 步之前**把订阅源文件换成 v2**(mode 变 `direct`、候选多出 `FS-C`),于是"更新真的重新拉取并生效"
  有硬凭证(读回 `mode=direct` / `now=FS-C` / `all=[FS-A,FS-B,FS-C]`),不是 `updated:true` 一句自述。

**五条断言**

| # | 断言 | 判据 |
|---|---|---|
| FS1 | 旗舰链四步全部成功 | 九步逐步骤 rc=0 + 每步结果经**读回**核实(接管落到 6/6 项且盖掉原第三方代理、mode=global、PROXY now=FS-B、更新后 v2 生效) |
| FS2 | 全链**零 GUI 打断** | 三条证据合证,见下 |
| FS3 | 反向对照:dangerous 换源确实触发确认 | 同一路由、同一订阅目录,`AA_CONFIRM_AUTO=deny` 起第二个宿主 → `aa proxy subscription add` 退出码=2 + `code=denied` + 宿主日志有含本次 name/source 的 `[confirm]` 行 + catalog 零留痕(仍只 1 条) |
| FS4 | 全链只经 `aa` | argv 凭证 + 流量对账,**证明力边界见下** |
| FS5 | `aa docs agents-md` 提到的能力 id 都真实存在于注册表 | 从引导文本抽出形如 `<域>.<段>` 且首段是**注册表真实存在的域**的候选(于是 `error.code`/`AGENTS.md` 不会被误当能力 id),逐个核对;抽不到候选 → 显式 FAIL(不许"没发现不一致"当绿) |

### 「零 GUI 打断」到底证到了什么强度(FS2)

宿主**不带** `AA_CONFIRM_AUTO` 启动 = 确认路由处于 `interactive`(真 NSAlert)档。三条证据缺一不可:

1. 宿主日志有 `dangerous 确认模式: interactive` —— 确认路由确实处于**会弹窗**的档位,不是被 auto 短路;
2. 全窗口内**没有任何** `[confirm] ` 行(该行在 `confirmDangerous` 最开头**无条件**打,早于
   `AA_CONFIRM_AUTO` 的任何分支)、无 `dangerous 确认结果`、无 `自动拒绝计时到` —— 确认层压根没被触达;
3. 每步都有 **25s 墙钟超时**(超时即 `kill -9` 并记账 → FS2 红),且响应里没有 `"pending":true` / `requestId`。
   —— 这两条各挡一种假绿:「因为超时被杀所以看起来没弹窗」和「其实返回了 pending、弹窗正在后台开着」。
   (04 票把 dangerous 改成异步 pending 之后,"CLI 没阻塞"**不再**能当零打断的证据,故必须查 pending。)

**证明力边界(如实)**:这条证的是「这条链在**无人值守的 headless 门禁里**没有触达确认层」。
它证明不了"真人坐在屏幕前跑时不会有别的 GUI 打断"(那要人眼),也不覆盖真 Codex 这一侧的交互。

**反向对照(FS3)是这一组里最重要的一条**:没有它,"零打断"可能只是因为**确认路由整个坏了** ——
那样全绿反而是最危险的。已实测过其红路径(见下「红路径实测」)。

### FS4「全链只经 aa」的证明力边界(**降级说明,如实**)

UDS 服务端**不记录对端进程身份**(没取 `LOCAL_PEERPID`),所以没有任何日志能证明"发这条请求的进程是 aa"。
本条不硬凑那个强度,它硬证的是两件可核验的事:

* **argv 凭证**:旗舰链每一步都经唯一入口 `fs_step` 执行,argv 逐行落盘;逐行核对**每一行都以 `$BIN/aa` 开头**
  (没有任何一步是 python 裸 UDS / curl / networksetup);
* **流量对账**:窗口内宿主实收 UDS 请求**条数**必须恰好等于按步骤形态推算的期望值
  (域子命令 = `capabilities.list` + `capabilities.call` 两次往返 × 9 步 = 18),且**每一条**请求的
  op/capability 都在白名单内。多一条计划外流量(哪怕内容合法)就红。

于是"链上有一步偷偷用裸 UDS 做掉了"被堵死:那要么让 argv 出现非 aa 命令,要么让宿主多收到一条请求。
**但它证的是「这条链没走别的道」,不是「外部进程不可能绕过 aa 直连宿主」** —— 后者是 04/10 票
「裸 UDS 直连仍被确认拦下」那两条的职责,本票不重复。

### 安全边界

* **绝不调真 `networksetup`**:`AA_NETWORKSETUP_FAKE_STATE` 指向 `$BUILD` 下的文件后端假件(既有 E2E 同口径)。
* **绝不碰用户自己的 mihomo**:只起仓库树内的 `Scripts/fake-mihomo.py`;清场只按绝对路径 pkill。
  finalize.sh 的「未触碰仓库外的 mihomo」守卫两次运行均绿(`[553 ]` 跑前跑后一致)。
* 订阅目录 / 接管态标记全部导向 `$BUILD` 临时区;finalize.sh 的"未污染真实 AppSupport"四条守卫均绿。
* 旗舰链宿主额外带 `AA_AUTO_DENY_SECONDS=8` —— **纯安全网**:只在真弹窗分支生效。万一将来有人把链上
  某条能力误标成 dangerous,弹窗 8s 后自动拒绝并留日志,而不是把模态框永远挂在用户屏幕上。
  它一旦真被用到,FS2 照样红(判据是"压根没有 `[confirm]` 行")—— 买的是"别劫持用户的屏幕",不是"让断言好过"。

## 实测记录

* 门禁基线 PASS=423 → 本票后 **PASS=428 FAIL=0 rc=0**(+5,恰为本组 5 条,无既有断言被动)。
  连跑两次均 428/0,耗时 ~117s / ~118s(与 ~115s 基线一致,本组增量 ~7s)。
* **红路径实测(变异测试,已回滚)**:把旗舰链宿主改成 `AA_CONFIRM_AUTO=deny`、第 4 步换成 dangerous 的
  `proxy.subscription.add`,同时把反向对照宿主改成 `approve`。结果 **PASS=424 FAIL=4**(总数仍 428,
  条数不变这条纪律成立),四条红各自给出可读原因:
  - FS1 红:步骤4 退出码=2、缺 `updated=true`、三条读回全不符;
  - FS2 红:「宿主未处于 interactive 确认档」+「竟带了 AA_CONFIRM_AUTO=deny」+「日志出现确认行 `[confirm]`」;
  - FS3 红:「换源退出码=0(期望2)」+「响应竟出现 added」+「deny 竟留痕」+「订阅条数=2」;
  - FS4 红:流量对账 `n=18 bad=1` → 「有 1 条请求的 op/capability 不在白名单内」。
  → **反向对照会真的红**,不是摆设。

## 为什么第 2、3 条今晚不能做(需要人在场做什么)

| 条目 | 为什么不能无人值守 | 人要做什么 |
|---|---|---|
| 真 Codex 接入 | 拉起真 codex 会**消耗用户真实配额**;`prefix_rule` 的一次批准本身就是**交互式**的(要人在会话里按批准),无人值守拿不到。Claude 走 `bypassPermissions` 对文件系统无隔离,更不该在门禁里拉起。 | 装好 `.app` 后跑 `aa docs agents-md` 把片段贴进 AGENTS.md;在交互式 codex 会话里一次性批准 `prefix_rule ["aa"]` + `sandbox_permissions: "require_escalated"`;然后让 Codex 自己走一遍 开代理→切模式→选节点→更新订阅,记录全程是否零打断、每步输出与退出码。 |
| 换源真机点验 | 判据是「**宿主 GUI 真的弹出 NSAlert**」——门禁 headless 无人看,`AA_CONFIRM_AUTO` 只是短路那个弹窗的 test-only seam,验的是短路之后的等价路径。真弹窗的样子(文案、参数是否看得见、批准/取消两按钮)只能人眼确认。 | 让 Codex 发起 `aa proxy subscription add --name X --source <URL>`;确认弹窗**真的出现**且文案里看得见本次 name/source;分别点「确认执行」与「取消」,记录两分支:批准→订阅入清单、退出码 0;拒绝→`code=denied`、退出码 2、catalog 零留痕。 |

## 已知不足(如实)

* **FS5 覆盖面很薄**:当前 `aa docs agents-md` 文本里只出现 **1 个**能力 id 候选(`demo.echo`),
  proxy 那些 id 只在散文里以 "status, mode, node, subscription" 形式提到、不是 id 形态,抽不出来。
  这条断言的机制是对的(将来有人往引导里写 `proxy.xxx` 而它不存在就会红),但**今天它只守住一个 id**。
  若要它真有分量,应把引导文本改成用真实 id 举例 —— 那是改文档的活,不在本票范围,记债。
* **本票的"agent"是 shell 脚本**,不是真 Codex。脚本证明「这条链在 `aa` 这一侧是通的」,
  证明不了「Codex 会正确地选择走这条链」——那正是上面第 2 条人工项的职责。
