# 06 e2e + 真机验收 + ADR 落笔

Status: resolved
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

## Answer

三个半票全部落地,2026-09-04 收束(细节见下方 Comments 与各提交):

1. **e2e 半票**:旗舰 e2e 六幕 → 十幕(50 → 90),含**真指令帧往返活体**(probe `--executor`
   替身,产品代码零改动)与 R-4 红线自查;check.sh 结构一步没动。
2. **ADR 半票**(主循环亲笔):新立 [ADR 0015](../../../docs/adr/0015-url-router-default-browser.md)
   (含可复用确认器原则三条件);ADR 0008 三条修订(壳两条受限例外 + 拉壳澄清);
   ADR 0012 两处随动;spec §15 施工修正案十条;分发 runbook 人工项 **#13–#17**。
3. **收尾小施工**:面板「设为默认浏览器…」入口(白名单 +takeover 共十三条,壳侧零确认框
   ——系统弹框即确认器),补上 spec §9 / 地图 04 票裁定漏排的那一块。

spec §13 验收对账:①接管旅程(e2e ⑨ 两路 + 单测 denied/timeout 假件路 + 真机 #13)
②分流正确性含 fragment(e2e ⑦)③降级+节流通知(swift 单测)④卸载三防线(e2e ⑩ +
bootstrap/install-script 测试)⑤门禁 APP1–15 + 两侧全绿 ⑥真机人工项 → runbook §8 #13–#17。
终局门禁在合并后的 main 上实跑:**八步 PASS=8 FAIL=0**(bun 655 / swift 296 / 旗舰 e2e 90 /
插件 e2e 50 / .app 出包 APP1–15)。真机项交用户,可与 mihomo 内嵌线验收并一次仪式。

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

### 收尾小施工:面板「设为默认浏览器」入口(2026-09-04,子代理;Status 仍 claimed)

spec §9 与地图 04 票裁定的「面板入口按钮」在 01–05 施工里全无落点,本次按 spec §15
修正案第 10 条补齐,分支 `feature/url-router-06-takeover-entry`,提交 **`29ca9fe`**
(feat(panel):白名单 +1 + 菜单一项)。

**产出**

| 面 | 落点 |
|---|---|
| 白名单 | `A2BootstrapCommand.urlRouterTakeover` = `url-router takeover --json`(共十三条)。经内嵌 bin 子进程 —— 修正案第 3 条的死锁理由逐字沿用 restore 那条 |
| 动作 | `A2BootstrapMenuAction.takeoverDefaultBrowser`,`confirmation == nil`(**壳侧不加框**:系统弹框就是确认器,再问一遍即双确认) |
| 菜单 | `A2MenuModelBuilder.defaultBrowserItems`:一项「设为默认浏览器…」,挂在 mihomo 区段之后。可见性只看内嵌 bin 在不在,**不读也不存**「现在是不是已经默认」 |
| 编排 | `A2BootstrapCoordinator.dispatch` 加一格,读 `commandSucceeded`(回执里的 `handler`/`already` 有意不读);**无前置序列** —— 卸载要先 restore 是因为它会删掉收拾残局的那条命令,接管不会 |
| 在途/失败 | ⏳ 行说全「http/https 各一次、至多 120s」;失败走既有失败面,内核 `code` + `guidance` 逐条原样转达 |

**测试**:`swift test` **283 → 296(+13)**——白名单三条逐字对照 + 单射 + 只有卸载带确认框;
接管四路收场(confirmed / already 幂等 / denied / unavailable,夹具全是**真金标**);在途守卫;
菜单项在场、每份带 bin 的装置里常驻、断连置灰、在途禁用 + ⏳ 行、失败行 + 指引、`⇒` 角标。
九份含内嵌 bin 的 golden 各 +1 行(`AA_SNAPSHOT_RECORD=1` 重录,文本 diff 逐份核过)。
bun 侧与 e2e 无白名单条数断言,故零改动。

**门禁**:`bash Scripts/check.sh` **8 步全绿**(① bun test 655 / ② swift test 296 /
③ 旗舰 e2e **90**(零回归)/ ④ 插件 e2e 50 / ⑤ .app 出包 APP1–APP15)。

**偏差两处**

1. **断连时置灰**(票面只要求 inFlight 期间的显示与 restore 一致)。理由:接管的编排全在
   内核里(拉壳、下发指令帧、等 120s),内核没跑时点了只会等来「daemon 不可达」。
   置灰口径**照抄同族的「重启代理内核」**(它也因「重启经内核服务」在断连时置灰),
   不是新发明;可见性一如票面要求 —— 引导面就绪即显示,从不消失。
2. **动了两处文档**(票面只说改代码与测试):ADR 0012 第 3 条加一条修订,把上一条
   「takeover 不在白名单里、共十二条」明确作废(否则 ADR 0015 第 5 条与 0012 互相打架);
   分发 runbook 的人工项 #13 与「五条白名单」那句随动。
