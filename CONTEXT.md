# A2

mac-only、local-first、agent-first 的代理管理产品:无头内核 bin `a2` 持有全部业务逻辑,
菜单栏壳 `A2 Panel.app` 是可选的对等客户端(见 docs/adr/,尤其 0008)。
本文件只是词汇表 —— 不收实现细节,实现决策归 ADR。

## Language

### URL 分流(2026-09-03,url-router 铺图会话定名)

**URL 分流(url-router)**:
按域名把系统级 http/https 打开请求派给不同浏览器目标的内核能力;子命令组 `a2 url-router`。
_Avoid_:路由、route —— 在本产品的代理域专指 mihomo 规则分流,两词不得混用。

**兜底浏览器**:
未命中分流域名、或内核不可达时接收 URL 的浏览器;必须显式配置 bundle id,
不得动态查询系统默认(A2 Panel 自己就是系统默认时会递归打开自己)。
_Avoid_:日常浏览器、默认浏览器(后者留给「系统默认 handler」这个系统概念)。

**接管 / 还原(takeover / restore)**:
接管 = 把 A2 Panel 注册为系统默认 http/https handler 的显式动作;还原 = 把 handler
设回兜底浏览器。均为 dangerous 级系统状态变更,与系统代理接管/还原同构。
_Avoid_:设置默认浏览器(口语,不指明方向)。
