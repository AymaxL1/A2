# 01 内核决策核心 + 配置模块

Status: claimed
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
