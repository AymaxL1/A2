# spec:URL 分流进 A2(url-router)

状态:**定稿**(06 票产出,2026-09-03 用户 CR 通过)
决策台账:[map.md](map.md)(铺图 7 条前提 + 01–05 票 Answer);术语见根 [CONTEXT.md](../../CONTEXT.md)
语义母本:`/Users/Shared/Workspaces/claude-url-router-agent-kit`(照抄语义、移植实现)

## 0. 一句话

A2 Panel.app 注册为系统默认浏览器;点任何 http/https 链接 → 壳原样转发内核 →
内核按域名两分:命中 routedDomains 进 RoxyBrowser 指定 profile(CDP→API→launcher
三级降级),其余进兜底浏览器;接管/还原是 dangerous 内核命令,系统弹框即确认器。

## 1. 范围

**做**:内核 `url-router` 能力组与 CLI 面、壳注册/转发/兜底/机械执行器、配置、卸载前置、
门禁断言、ADR 修订。**不做**(见 map Out of scope):泛化映射表、独立 router .app、
非 mac 端、实机 Roxy 参数填写(施工/部署期人工项)。

## 2. 架构与职责切分

```text
用户点链接
  → Launch Services 拉起/唤醒 A2 Panel.app(已注册 handler)
    → 壳(纯机械):经 UDS 调 url-router.route(url)
        ├─ 内核可达:内核决策 + 执行(spawn `open -b` / CDP / Roxy API)
        └─ 内核不可达(连接失败或超时 1.5s):壳把 URL 原样交给
           「最后已知快照的兜底浏览器」,无快照则 com.apple.Safari;
           宕机后首次兜底弹一条节流通知
```

- **内核**:全部决策与执行(域名两分、Roxy 三级降级、打开浏览器、配置、接管编排)。
- **壳**:四件机械事——① LS 注册载体(Info.plist);② 收 kAEGetURL 原样转发;
  ③ 降级兜底(03 票四条硬边界);④ 接管/还原的机械执行器(04 票:调 NSWorkspace、
  completion 回传,不含任何判断)。
- **ADR 0008 红线不破**:③④ 是豁免与受令执行,措辞见 §10。

## 3. 能力契约(ADR 0004 全要素,进 capability 注册表)

沿 envelope `{"v":1,"id":…,"ok":…}` 与既有退出码词表(docs/agents/a2-cli.md)。

| 能力 ID | 类 | 风险 | 语义 |
|---|---|---|---|
| `url-router.status` | query | safe | 当前系统 handler、是否 = com.a2.panel、悬空诊断(05)、配置健康(解析错误/目标 app 存在性)、快照版本 |
| `url-router.decide` | query | safe | 对一条 URL 只出决策不执行(CLI `route --dry-run` 的落点);输出 `decision`:`fallback-browser` / `roxy-cdp:<port>` / `roxy-api` / `roxy-launcher` / `unsupported` |
| `url-router.route` | command | normal | 决策 + 执行打开(可逆写:开标签页/拉起 app,无系统状态变更);壳与 CLI 走同一条 |
| `url-router.takeover` | command | **dangerous** | 把 com.a2.panel 设为 http+https 默认 handler;确认模型见 §5 |
| `url-router.restore` | command | **dangerous** | 设回兜底浏览器;`--to <bundleid>` 显式覆写(05);目标缺失在任何 LS 调用前结构化报错 |

契约要素逐条:输入/输出 JSON Schema 施工期落 `kernel/contract/schema`(golden 同步);
幂等——takeover/restore 以「当前 handler 已是目标」为幂等判据(已是则 ok:true +
`already: true`,不弹框);超时/取消见 §5;错误码词表见 §5/§7;可逆性——takeover 的补偿
即 restore;测试样例:成功 / 校验失败 / confirmation_denied / 幂等 / 目标缺失 五类各至少一例。

## 4. CLI 面

```bash
a2 url-router status --json
a2 url-router route <url> [--dry-run] --json
a2 url-router takeover --json
a2 url-router restore [--to <bundleid>] --json
```

等价能力调用写法照旧(`a2 capabilities call url-router.route --input …`)。
机读面永不掺散文;`route <url>` 的 URL 作为独立 argv,无注入面(02)。

## 5. 接管/还原:确认模型与错误面(04 票)

- **系统弹框 = 确认器**(可复用原则,ADR 化见 §10):OS 强制呈现、agent 伪造不了、
  结果经 NSWorkspace completion 可感知(01)。**必须走新 API**
  `setDefaultApplication(at:toOpenURLsWithScheme:)`;禁用旧 LS API(结果不可感知,
  不满足原则)。
- **执行链**:内核收到 takeover → 壳未装?→ `guidance`(先装 A2 Panel.app,exit 2)
  → 壳未跑?→ 内核 `open -b com.a2.panel` 拉起(显式变更的一步,不算隐式)
  → 经 UDS 下发执行指令帧(§6)→ 壳调 API → 系统弹框 → completion 回传。
- **错误面复用既有词表**:无 GUI 会话/壳不可用 → `confirmation_unavailable`(exit 2,
  guidance:到 Mac 桌面会话执行,或系统设置手选);用户点取消 → `confirmation_denied`
  (exit 2,不重试);等满 **120s** 没人点 → `confirmation_timeout`(exit 3,guidance:
  稍后 `a2 url-router status` 核实——用户晚点才点也算数)。
- http 与 https 两个 scheme 各弹一次框是 OS 行为,如实等待两次 completion;
  部分成功(一个同意一个取消)如实报 `partial`,guidance 给补齐命令。

## 6. UDS 协议增量

1. **URL 转发:零新帧**。壳作为客户端调 `url-router.route`,与 CLI 同一能力面。
   壳侧调用超时 **1.5s**(含连接),超时/失败即入兜底路径。
2. **配置快照**:既有「全量快照 + 增量推送」新增 `urlRouter` 节,最小集
   `{fallbackBrowserBundleID}`;壳每次收到即写 UserDefaults
   (键 `urlRouter.fallbackBrowserBundleID`,com.a2.panel 域)。(03)
3. **执行指令帧**(内核→壳,新增):`{op:"set-default-handler", schemes:["http","https"],
   bundleID:"…", timeoutSeconds:120}`;壳回
   `{outcome:"confirmed"|"denied"|"timeout"|"error", perScheme:{…}, error?}`。
   壳对该帧**零判断**,唯一合法反应是调 API 并回传。

## 7. 壳侧改动

- **Info.plist(经 build-app.sh)**:照抄参考实证组合(01)——`CFBundleURLTypes`
  http+https(`LSHandlerRank: Owner`)+ `CFBundleDocumentTypes`
  `public.html/public.xhtml/public.url`(Viewer)。ad-hoc / LSUIElement 不碍事。
- **URL 事件**:AppDelegate 注册 kAEGetURL + `application(_:open:)`,收到即转发(§6.1);
  不解析、不记内容(日志脱敏沿参考 `sanitize` 语义,落壳日志)。
- **兜底(03 四条硬边界)**:内核不可达 → 取 UserDefaults 快照值,无则 com.apple.Safari,
  `NSWorkspace.open` 交出去。宕机后首次兜底弹本地通知
  「A2 内核未运行,链接已交给兜底浏览器」,后续静默;UDS 重连成功重置节流位。
- **机械执行器**:§6.3 帧的实现;completion 的 NSError 原样序列化回传(域/码施工期实测,
  01 遗留项)。

## 8. 配置

- **落点** `~/.a2/url-router.json`($A2_HOME 覆写照旧);无文件 = 全缺省。
- **字段**(承接参考 config.example.json 全参数,兜底项按 CONTEXT.md 改名):

| 字段 | 缺省 | 注 |
|---|---|---|
| `fallbackBrowserBundleID` | `com.apple.Safari` | 原 defaultBrowserBundleID;**必须显式 bundle id,永不查系统默认**(递归) |
| `routedDomains` | `["claude.ai","claude.com","anthropic.com"]` | 含子域名后缀匹配 |
| `roxyApplicationPath` | `/Applications/RoxyBrowser.app` | 02:本机实况 |
| `roxyProcessMatch` | `/RoxyBrowser.app/Contents/MacOS/RoxyBrowser` | 02:纯配置值替换 |
| `roxyProfilePathMarker` | `/browser-cache/` | 施工期人工核对(02 遗留) |
| `roxyProfileID` | `""` | |
| `roxyAPIHost` / `roxyAPIOpenPath` / `roxyAPITokenHeader` | `null` / `/browser/open` / `token` | |
| `roxyAPIKey` | `null` | **敏感:只留本机文件,不入 git,不进快照推送,不进日志** |
| `roxyWorkspaceID` / `roxyForceOpen` | `null` / `false` | |
| `roxyAPITimeoutSeconds` / `roxyStartupAttempts` / `roxyStartupDelaySeconds` | `5.0` / `10` / `0.2` | |

- 日志并入内核日志纪律(不设独立 logPath);query/fragment 脱敏照参考。
- V1 配置管理 = 直接编辑文件,`url-router.status` 负责解析校验与报错;
  `config` 子命令留作后续(不进本期)。
- 卸载 `rm -rf ~/.a2` 时随之清理(既有口径,无新增)。

## 9. 体验章(旅程)

- **接管**:面板入口按钮或 `a2 url-router takeover` → 系统弹两框(http/https)→
  点「使用 “A2 Panel”」→ 命令返回 ok → 此后点链接走 §2 流程。
- **日常热路径**:<100ms 无感(02 实测);Roxy 未跑时 API/launcher 路径秒级,属预期。
- **降级故事**:「退出 A2」连带 service stop(ADR 0008 修订)→ 此后点链接 LS 重新拉起壳
  → 内核不可达 → 兜底 + 首次节流通知。分流失效可见、链接永远打得开。
- **卸载(双路径,05)**:面板路径 restore 打头、拒即中止,再 proxy off → service
  uninstall → 删文件;`install.sh --uninstall` 第四条前置:还接管就拒删 bin。
- **野路径**:直接删 .app → 系统自动回落(施工期断言钉死);服务侧不动手,
  `status` 诊断悬空 + 修复指引。

## 10. ADR 清单

1. **修订 ADR 0008 第 5 条**(壳职责):在「投影 + 确认器」外增列两条受限例外——
   ① 降级兜底,原文写入 03 四条硬边界(不解析 URL 内容 / 不做域名匹配 / 唯一分支条件 =
   内核可达与否 / 配置知识只来自内核推送快照、永不读内核文件),定性「哑管道 + 断电开关」;
   ② 机械执行器:仅执行内核下发的白名单指令帧并回传结果,零判断。
2. **新立 ADR 0015「URL 分流与默认浏览器接管」**:决策总纲(Panel 承载 + 内核决策 +
   语义照抄母本)+ 可复用确认器原则:「OS 强制呈现、不可伪造、结果可感知的系统确认,
   可充当 dangerous 命令的确认器」(三条件缺一不可,防类推滥用)。
   三判据齐:难逆(确认模型/协议形状)、后人会问为什么、真取舍(双确认/独立 app 都被否)。

## 11. 门禁修订

- **build-app.sh 断言**:APP14 = Info.plist 含 CFBundleURLTypes 且恰为 http+https;
  APP15 = CFBundleDocumentTypes 含 public.html/xhtml/url。可执行清单(APP8)不变。
- **kernel 测试面**:决策纯函数单测(域名两分、子域名、大小写、**`#` 编码差异**——02 的坑,
  必须有用例);配置缺省合并;takeover/restore 幂等判据;install.sh 第四条前置
  (进 `kernel/test/install-script.test.ts` 既有套件);contract golden 增量。
- **施工期实测钉死**(research 遗留):用户取消时 completion 的 NSError 域/码(01);
  悬空自动回落行为断言(01);`open -b` 成功路径 e2e(02);roxyProfilePathMarker
  对 RoxyBrowser 实况核对(02)。

## 12. 移植对照表

以 [docs/research/url-router-ts-port-facts.md](../../docs/research/url-router-ts-port-facts.md)
草表为准,唯一补充:AppDelegate/kAEGetURL/自杀计时器不移植(壳职责,且壳常驻无需自杀)。

## 13. 验收清单(施工 effort 开票依据)

1. 接管旅程:takeover → 双弹框确认 → status 确认 handler = com.a2.panel;取消/超时/无 GUI
   三条错误路各出对应 code 与 guidance。
2. 分流正确性:routedDomains 命中进 Roxy(CDP/API/launcher 三级各可触发),
   其余进兜底浏览器;带 fragment 的 URL 不截断。
3. 降级:kill 内核后点链接 → 兜底浏览器打开 + 恰一条通知;内核恢复后再宕 → 通知再来一次。
4. 卸载:面板路径 restore 打头且拒即中止;install.sh 第四条前置生效;还原后 status 干净。
5. 门禁:APP14/APP15 + kernel 新增测试全绿;`swift build/test` 与既有断言无回归。
6. 真机人工项:弹框实感、Roxy 实配(profileID/APIKey)、悬空回落实测。

## 14. 施工切票建议(另立 effort)

① 内核决策核心 + 配置模块(纯函数 + 单测,含 `#` 用例)→ ② capability/CLI 面 + contract
golden → ③ 快照 `urlRouter` 节 + 壳转发/兜底/通知 → ④ 执行指令帧 + takeover/restore 编排
→ ⑤ Info.plist/门禁断言 + 卸载双路径前置 → ⑥ e2e + 真机验收 + ADR 落笔。
每步可合并、门禁绿(沿 kernel-bin-recharter 六步纪律)。
