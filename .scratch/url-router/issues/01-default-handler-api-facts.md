# 01 macOS 默认浏览器注册/还原的 API 事实

Type: research
Status: resolved
Blocked by: —

## Question

内核命令 `a2 url-router takeover|restore` 要替 `com.a2.panel` 注册/还原系统 http/https
handler。落 spec 前需要钉死这些平台事实(参考项目 `set-as-default.sh` 已实证:第三方 CLI 进程
用 `xcrun swift -e` 调 `LSSetDefaultHandlerForURLScheme` + `LSSetDefaultRoleHandlerForContentType`
可行,系统会弹确认框):

1. **API 选型**:`LSSetDefaultHandlerForURLScheme`(deprecated)vs
   `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`(macOS 12+)—— 各自的
   最低系统版本、弃用状态、回调/返回语义;A2 min macOS 13,该用哪个。
2. **发起进程**:从任意 CLI 进程(bun 内核 spawn 一段 `swift -e` 或小工具)替另一个 bundle id
   注册,弹框归属哪个进程、结果(用户点了「使用」还是取消)能否被发起方感知?同步还是异步?
3. **候选列表条件**:.app 要出现在「系统设置 → 默认网页浏览器」候选里,Info.plist 需要什么
   (`CFBundleURLTypes` 声明 http/https 之外还有没有条件)?ad-hoc 签名、LSUIElement=true
   是否影响注册资格或弹框行为?
4. **还原语义**:restore = 把 handler 设回兜底浏览器 bundle id(与接管同一 API)。用户在弹框
   取消时 API 返回什么;还原目标 .app 不存在时的行为。
5. **CLT 依赖**:`xcrun swift -e` 路线要求 CLT 在场(本机红线保证有,但 spec 要写清依赖);
   有没有免 CLT 的路线(如壳当机械执行器、内核经 UDS 命令壳调 NSWorkspace ——
   这与 ADR 0008 的边界如何相容)。

**纪律**:只读研究。可读当前 handler(`LSCopyDefaultHandlerForURLScheme` 等),
**严禁真的改动本机默认浏览器**。

产出:`docs/research/url-router-default-handler.md`,落 `research/url-router-default-handler`
分支。1/2/5 的答案直接喂 [04](04-takeover-confirmation-ux.md)、[05](05-uninstall-precondition-revision.md)。

## Answer

五问全部落定,findings 全文见 [docs/research/url-router-default-handler.md](../../../docs/research/url-router-default-handler.md)。一句话版:

1. **API 选型**:用 `NSWorkspace.setDefaultApplicationAtURL:toOpenURLsWithScheme:`(macOS 12+);旧 LS API 已标弃用。
2. **结果可感知**:新 API 的 completion 在用户点完系统弹框**之后**才回调(SDK 头注原文),拒绝可感知;旧 API 返回码即时、不含用户决定 —— 04 票「系统弹框当确认器」的技术前提成立,仅限新 API 路线。
3. **候选列表**:参考项目实证组合 = `CFBundleURLTypes`(http/https)+ `CFBundleDocumentTypes`(public.html/xhtml/url);ad-hoc + LSUIElement 不碍事。A2 Panel 照抄。
4. **还原**:同 API 设回兜底浏览器;还原目标先 `urlForApplication(withBundleIdentifier:)` 解析,nil 即可提前结构化报错;悬空 handler 系统自动回落(中置信度,施工期断言钉死)。
5. **CLT**:`swift -e` 依赖 CLT 不可假设;免 CLT 路线两条 —— 预编译小工具随包 / **壳当机械执行器**(内核 UDS 下发指令、壳调 NSWorkspace、completion 回传)。取舍裁定归 04/05。

## Comments

- 2026-09-03 铺图会话:已派 research 子代理(Opus,worktree 隔离)。
- 2026-09-03:子代理连撞 API 529 过载,用户裁定收回主会话执行;findings 直接落工作区(未分支),调研完成。
