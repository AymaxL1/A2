# 06 e2e + 真机验收 + ADR 落笔

Status: open
Blocked by: 05

## Question

spec §10/§11/§13:

- e2e:分流正确性(命中/未命中/fragment 不截断)、降级(kill 内核 → 兜底 + 恰一条
  通知)、takeover 错误三路(无 GUI/取消/超时)以可自动化的部分入既有 e2e 套件。
- ADR 落笔:修订 ADR 0008 第 5 条(兜底四条硬边界 + 机械执行器两条受限例外)、
  新立 ADR 0015「URL 分流与默认浏览器接管」(含可复用确认器原则三条件)。
- 真机人工项(spec §13.6):弹框实感、Roxy 实配(profileID/APIKey/profilePathMarker
  核对)、悬空自动回落实测、用户取消 NSError 实测回填 spec §11。
  可与 mihomo 内嵌线的真机验收并一次仪式。

验收:check.sh 8 步全绿;ADR 两篇入库;人工项清单交用户。

## Comments
