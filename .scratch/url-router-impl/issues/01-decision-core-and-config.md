# 01 内核决策核心 + 配置模块

Status: resolved
Blocked by: —

## Question

spec §2/§8/§12:把母本 `ClaudeURLRouter.swift` 的决策核心与配置移植进 `kernel/`,
纯函数 + 单测,不接 capability、不碰壳、不碰系统状态。

- 配置模块:`~/.a2/url-router.json` 读取 + 缺省合并(spec §8 字段表,含
  `fallbackBrowserBundleID` 改名与 RoxyBrowser 缺省值);无文件 = 全缺省;
  `roxyAPIKey` 敏感纪律(不进日志)。
- 决策纯函数:域名两分(host 归一、子域名后缀匹配、大小写、前后点号)、
  RouteDecision 五值(spec §3 `decide` 输出词表)。
- CDP URL 构造:`/json/new?<url>` 编码函数,**必须有 `#`→`%23` 用例**(02 票坑)。
- 单测:域名两分边界、配置缺省合并、编码差异;门禁 bun test 绿。

验收:`bun test` 新增用例全绿;无任何运行时接线(下一票的事)。

## Comments

- 2026-09-04 施工完成(bdea0fb,分支 `feature/url-router-01-decision-core`):
  `kernel/src/url-router/{config,decide,cdp}.ts` + `kernel/test/url-router-{config,decision}.test.ts`;
  `bun test` **480 pass / 32 skip / 0 fail**(新增 31 条,既有 449 无回归)。
  两处判据做过变异验证(去掉 `.domain` 的点、`#` 不补 `%23` —— 各自当场红)。
  **Status 保持 claimed**,待 CR。CR 时值得看的三处口径:
  ① 文件用不了(坏 JSON / 字段类型不合契约)→ **整份退回缺省**(母本语义),
     用 `source`/`problem` 交给 02 票的 `url-router.status` 去报,而不是留半份配置;
  ② 字段校验**只到类型**(与母本 JSONDecoder 同口径),值域下限的 clamp 留给使用侧 ——
     收紧的代价不对等(一个写歪的 `roxyStartupAttempts: 0` 会连带把兜底浏览器打回缺省);
  ③ `roxyAPIKey` 纪律的落点是「错误文本只报字段名、不带文件原文」+ `redactUrlRouterConfig`,
     两条都有「把钥匙写进文件再断言产物里搜不到」的用例。
- 2026-09-04 CR(Fable 主循环,双轴):**通过,零修改项**。三处口径全部成立(五值分词本就是
  spec §3 要求;整份退缺省是母本语义 + 诊断出口;类型级校验取舍论证正确,clamp 归 02 使用侧)。
  复核实测 480/0 + typecheck 干净。ff 合入 main = 35cf7ca,分支已删。→ resolved。
