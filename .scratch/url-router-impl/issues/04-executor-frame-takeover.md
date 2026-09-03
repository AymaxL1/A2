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
