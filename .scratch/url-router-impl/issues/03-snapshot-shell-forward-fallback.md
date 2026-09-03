# 03 快照 urlRouter 节 + 壳转发/兜底/通知

Status: open
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
