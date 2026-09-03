# 06 e2e + 真机验收 + ADR 落笔

Status: claimed
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

### e2e 半票完成(2026-09-04,子代理;ADR/修正案仍在主循环手里,故 Status 保持 claimed)

**产出**:旗舰 e2e 六幕 → **十幕**,断言 **50 → 90**(+40)。八步 check.sh 全绿
(① bun test 655 / ② swift test 283 / ③ 旗舰 e2e 90 / ④ 插件 e2e 50 / ⑤ .app 出包),
结构一步没动。

| 幕 | 覆盖 | 断言 |
|---|---|---|
| ⑦ URL 分流(spec §13.2) | 未命中 → fallback-browser;命中(子域名)+ 没跑 Roxy + API 没配 → roxy-launcher;真 route 交给假 open 的 argv **逐字节**相等(URL 独立 argv、`#` 之后不截断);报文脱敏 | 9 |
| ⑧ status | 配置健康(configSource=file + 兜底/域名表逐字来自现写的文件)+ handler **未能判定**(不猜) | 6 |
| ⑨ 接管(spec §13.1) | 执行器不在场 → 拉壳一次 → `confirmation_unavailable`(2)+ guidance;**真指令帧往返** → 0 + confirmed + perScheme 逐条 ok + 壳侧逐 scheme 各调一次;幂等复跑 → `already:true` 且壳一帧没收到 | 17 |
| ⑩ purge ⓪e(spec §13.4 CLI 野路径) | 还挂着 → 拒(1)+ `service_purge_url_handler_taken` + 指引 + **零删除**;设回兜底 → 放行 + home 真清 | 7 |
| R-4 红线自查 | url-router 五个外部程序**全部**打在假件上(它们走绝对路径,PATH 那道防线无效) | 1 |

**提交**(分支 `feature/url-router-06-e2e`):
- `c6fce40` test(probe):无头替身可当机械执行器(`--executor` + `ScriptedHandlerSetter`)
- `46c91e5` test(e2e):旗舰 e2e 接上 url-router 四幕

**probe 执行器现状与取舍**:接手时 `a2-panel-probe` **不注册**执行器角色(它调的是
`A2PanelSession(configuration:delegate:)`,executor 缺省 nil)。但生产装配那一句就在
`A2PanelAppDelegate` 里,且 04 票为的正是这个留了 `A2DefaultHandlerSetting` 这道缝 ——
于是取「往返活体做实」:探针加 `--executor` 开关 + 一个系统 API 替身,**产品代码零改动**
(同一个 Runner、同一个 `executor != nil` 注册开关,只有最末那次 `setDefaultApplication`
是替身)。它与 `--decision approve|deny` 同源:那是人的替身,这是操作系统的替身。
**故「往返活体」不再是真机人工项**;真机项只剩 spec §11 那条(用户取消时 NSError 的域/码)。

**偏差三处**:
1. **takeover 错误三路只进 e2e 两路**(不在场 / confirmed 往返 + 幂等)。`denied` 与
   `timeout` **有意不进**:本版壳按设计只产 `confirmed` / `error`
   (`A2URLRouterExecution.swift` 头注写明,分辨"取消"要等 06 真机回填 NSError 域/码),
   让探针假造一个 `denied` 就是让它撒一个**真壳做不到**的谎 —— e2e 的价值恰恰在于被测体是
   真壳代码。这两路已在 `kernel/test/cli-url-router.test.ts` 用假执行器验全(退出码 2/3 + 报文)。
2. **⑩ 另起一个沙盒 home**。票面写「按既有 e2e 里 service 场景的形状最小化」,而既有旗舰
   e2e 里**根本没有 service 幕**;`--purge` 又只对缺省 `~/.a2` 放行(18 票白名单),且会把整个
   `$A2_HOME` 删掉。于是照 `cli-service.test.ts` 的沙盒形状最小化:`HOME` 指到一个新临时目录,
   它下面的 `.a2` 就是被测进程眼里的缺省 home;主沙盒那份(正跑着 daemon)一个字节都不碰。
3. 顺手补了 `mkdir -p .build`:刚 checkout 的工作树里它不存在,构建日志那次重定向会当场失败,
   而报出来的样子是「a2-panel-probe 构建失败」——一条把人引向错误方向的假象。

**环境备注**(不入库):新工作树要先在 `kernel/` 跑一次 `bun install`,否则 ⓪a/①/②b/⑤ 四步
会因为解析不到 `zod` 而红(③④ 反而是绿的 —— bun 跑源码入口时会自动装,于是这种红最容易被误判)。
