# URL 分流:决策核心 Swift→TS(bun)移植的平台事实(02 票)

调研:2026-09-03,url-router 铺图 02 票。实测环境:本机(Darwin 24.6.0,bun 1.3.14),
基准脚本见会话 tmp(`bench-url-router.ts`,只读探测)。母本:参考项目 `ClaudeURLRouter.swift`。

## 结论先行

1. **进程探测可行且便宜**:bun `Bun.spawnSync` 跑 `/bin/ps axww -o pid=,command=` 全表
   中位 **15.6ms**;`/usr/sbin/lsof -nP -a -p <pid> -iTCP -sTCP:LISTEN` 单进程中位 **21.3ms**,
   对自己用户的进程**无须 sudo**(实测)。参考实现「每次点击都 ps+lsof」的形状搬进 bun
   代价约 40–60ms(1–2 个候选 pid),无须换机制。
2. **CDP 交互直译即可,唯一真坑是 `#`**:GET `/json/version` `/json/list`、PUT `/json/new?<url>`
   都是裸 fetch;超短超时用 `AbortSignal.timeout(800)`,拒绝端口错误路径实测 **9.1ms**、
   错误码干净(`ConnectionRefused`)。编码差异:Swift `.urlQueryAllowed` 会把 `#` 编成 `%23`,
   而 JS `encodeURI` **不编 `#`** —— 直接换会让带 fragment 的 URL 在 `/json/new?` 处被截断。
   移植必须 `encodeURI(url).replaceAll("#", "%23")`(或等价自定义编码);`encodeURIComponent`
   则过度编码(`:/` 全变 `%xx`),与参考语义不符。此差异建议进 kernel 测试。
3. **打开浏览器走 `/usr/bin/open`**:`open -b <bundleID> <url>` 语义对齐参考实现
   `NSWorkspace.open(activates:true)`(open 默认前置目标 app);错误路径实测:bundle id
   不存在时 exit 1 + stderr 明说(`LSCopyApplicationURLsForBundleIdentifier() failed …`),
   结构化可判。成功路径未实测(会真开浏览器,违反只读纪律),man page 语义明确,施工期
   e2e 补。URL 作为独立 argv 传入,无注入面。
4. **RoxyBrowser 兼容 = 纯配置值替换**:本机 `/Applications/RoxyBrowser.app`,可执行
   `RoxyBrowser`,bundle id `com.roxybrowser.app`。参考项目的匹配逻辑(命令行子串
   `roxyProcessMatch` + `roxyProfilePathMarker`)形状不用动,配置值改为
   `/RoxyBrowser.app/Contents/MacOS/RoxyBrowser`;`/browser-cache/` 标记与 profile ID
   需 Roxy 跑起来才能核对(本次未启动——不碰用户 Roxy),列入施工期人工核对项。
5. **延迟预算(用户点击 → 浏览器动)**:热路径(壳常驻 + Roxy 已跑)≈ UDS 往返(个位 ms)
   + ps/lsof(~40ms)+ CDP 校验与 PUT(~20ms)≈ **100ms 内,无感**。冷路径大头:
   LS 拉起壳(未测,常识几百 ms)与 Roxy API 启动 profile(秒级,参考实现本就带重试探测)。
   值得在 spec 里列的**选项**(不裁定):缓存上次命中的 CDP 端口、失败才全量探测;
   内核常驻侧维护 Roxy 端口 watcher。以热路径实测看,V1 不加缓存也成立。

## 移植对照草表(喂 06 spec)

| ClaudeURLRouter.swift | bun 落点 |
|---|---|
| `EffectiveConfig.load()`(JSON+缺省合并) | 内核配置模块,落 `~/.a2`(03 票已裁快照下发) |
| `Router.decision(for:)` 域名两分 | 纯函数直译,进 kernel 单测 |
| `roxyMainPIDs()` / `listeningPorts(forPID:)` | `Bun.spawnSync` ps / lsof(实测 1/2 条) |
| `devToolsPortMatchesProfile` / `openInExistingRoxy` | fetch GET / PUT + `AbortSignal.timeout`(注意 `#` 坑) |
| `openViaRoxyAPI` | fetch POST + 启动重试循环,直译 |
| `openURL(withBundleIdentifier:)` | `open -b`(结论 3) |
| `sanitize`(日志脱敏 query/fragment) | 直译,沿内核日志纪律 |
| AppDelegate / kAEGetURL / 自杀计时器 | **不移植** —— 壳侧职责(收 URL 转发),内核无此形态 |

## 证据

- 基准数据:ps 15.6ms / lsof 21.3ms / fetch 拒绝 9.1ms(各 5 次取中位,本机实测)。
- 编码对照:`encodeURI("…#frag")` 保留 `#`(实测输出),Swift `.urlQueryAllowed` 不含 `#`(CharacterSet 定义)。
- `open` 错误路径实测 exit=1;RoxyBrowser Info.plist 只读提取。
