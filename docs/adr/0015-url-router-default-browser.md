---
status: accepted
date: 2026-09-04
---

# URL 分流与默认浏览器接管:Panel 承载 handler、内核决策、系统弹框即确认器

把 claude-url-router-agent-kit 的 URL 分流语义收进 A2:A2 Panel.app 注册为系统默认浏览器,
按域名把链接派给 RoxyBrowser 指定 profile(CDP → API → launcher 三级降级)或兜底浏览器;
接管/还原是 dangerous 内核命令,由操作系统自己的弹框充当确认器。

## Context

- 决策台账:`.scratch/url-router/`(wayfinder 图,6 票 + spec 定稿,用户 CR 2026-09-03 通过);
  实施台账:`.scratch/url-router-impl/`(6 票,双轴 CR);两份平台事实调研在
  `docs/research/url-router-{default-handler,ts-port-facts}.md`。语义母本
  `/Users/Shared/Workspaces/claude-url-router-agent-kit`(照抄语义、Swift→TS 移植实现)。
- 两条硬事实框定了整个形状:**macOS 默认 handler 必须是 .app bundle**(`a2` 内核 bin 没有
  参选资格),而 [ADR 0008](0008-kernel-bin-ui-optional.md) 第 5 条钉着「壳不得含业务逻辑」。
- NSWorkspace 新 API(macOS 12+)的 completion **在用户点完系统弹框之后**才回调 ——
  接管结果可被发起方感知;旧 LS API 返回码即时、不含用户决定(SDK 头注,research 01)。

## Decision

1. **承载与分工**:A2 Panel.app 经 `CFBundleURLTypes`(http+https)+ `CFBundleDocumentTypes`
   (public.html/xhtml/url)注册 Launch Services(实证组合照母本)。壳只做四件**机械**事:
   注册载体、原样转发(经 UDS 调 `url-router.route`,零新帧)、降级兜底、机械执行器 ——
   后两条是 ADR 0008 第 5 条修订里的受限例外。决策/配置/执行全在内核 `url-router` 能力组:
   `status`/`decide`(safe)、`route`(normal)、`takeover`/`restore`(dangerous),
   域名两分与三级降级语义照母本;配置住 `~/.a2/url-router.json`(敏感 `roxyAPIKey`
   只留本机、不进日志/快照/报文)。
2. **可复用确认器原则**:「**OS 强制呈现、agent 伪造不了、结果可被发起方感知**的系统确认,
   可充当 dangerous 命令的确认器」—— 三条件缺一不可(第三条把旧 LS API 排除在外)。
   实现为 capability descriptor 的 `confirmation: "os-dialog"`(缺省 `confirm-agent` 即原行为,
   缺省判据单一出处):registry 对 os-dialog 跳过 confirm-agent 三层,由 handler 里
   「执行指令帧 → 壳调 `setDefaultApplication(at:toOpenURLsWithScheme:)` → completion 回传」
   的往返充当确认仪式本身。**这不是少一道闸,是闸挪进了 OS**:没有任何报文能让 agent 自批,
   框由 OS 弹、由人点。错误词表零新造:无执行器 → `confirmation_unavailable`(2)、
   人点取消 → `confirmation_denied`(2)、120s 未决 → `confirmation_timeout`(3);
   仅「两 scheme 成了一半」有专码 `url_router_partial_takeover`(5,报文带 perScheme 与补齐命令)。
   os-dialog 名单由门禁断言钉死(当前恰 `url-router.takeover|restore` 两条),
   其余 dangerous 能力的仲裁行为一字未变(三处断言)。
3. **兜底身份链**:内核快照 `urlRouter` 节(现读磁盘)→ 壳 UserDefaults 持久化 →
   硬编码 Safari。兜底浏览器**必须显式 bundle id、永不查系统默认**(A2 Panel 自己就是
   默认 handler 时会递归打开自己);壳侧另有防打转熄火窗与双投递去重(均为字符串级机械规则)。
4. **卸载纪律(三处同构防线)**:面板卸载序列 restore 打头、拒/超时即中止;
   `install.sh --uninstall` 第四条前置(LS 用户设定表里有 `com.a2.panel` 即拒删 bin,
   判据宁宽勿漏、不依赖 daemon);内核 purge ⓪e 门(`service_purge_url_handler_taken`,
   只拦确知、未能判定放行)。悬空 handler **只诊断不动手**(`status` 报悬空 + 修复指引,
   mdfind 只读探询 + fail-open)。
5. **壳发起走内嵌 bin,不走会话**:壳自己是执行器 —— 会话线程自发起 takeover/restore 会与
   内核的反向指令帧互等成死锁。故面板侧的 restore(卸载前置)与 takeover(菜单入口)
   一律经 [ADR 0012](0012-panel-self-sufficient-bootstrap.md) 的内嵌 bin 白名单以**子进程**
   发起;白名单为此恰增 `url-router status|restore|takeover` 三条,其余纪律原样。

## Consequences

- agent 面一次学会:`a2 url-router …` 五条命令,机读 envelope 与退出码与全产品一致;
  dangerous 的两条在 `capabilities list` 里可见 `confirmation: "os-dialog"`。
- 确认器原则是**可复用**的,但三条件是硬闸:将来任何想标 os-dialog 的能力都要过
  「OS 强制 + 不可伪造 + 结果可感知」三问,并进那条名单断言。
- 代价如实记:http 与 https 是两次独立系统弹框(OS 行为),部分成功是真实状态,
  由专码 + 幂等重跑兜住;用户取消的 NSError domain/code 待真机回填
  (回填前壳只产出 confirmed/error,denied/timeout 词表与内核映射已就位)。
- 真机人工项(弹框实感、候选列表、悬空回落、Roxy 实配、通知授权)见
  [分发 runbook](../runbooks/distribution.md) §8 #13–#17。
