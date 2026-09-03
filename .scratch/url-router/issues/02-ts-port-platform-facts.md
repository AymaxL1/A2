# 02 决策核心 Swift→TS(bun)移植的平台事实

Type: research
Status: resolved
Blocked by: —

## Question

路由决策核心要从参考项目的 Swift(`ClaudeURLRouter.swift`)移植进 TS 内核(bun,ADR 0010)。
语义原样:命中域名 → Roxy 指定 profile(CDP → API → launcher 三级降级),其余 → 兜底浏览器。
移植前钉死平台事实:

1. **进程探测**:bun 下等价实现 `ps axww -o pid=,command=` 过滤 Roxy 主进程 +
   `lsof -nP -a -p <pid> -iTCP -sTCP:LISTEN` 抓 CDP 端口 —— spawn 开销、权限
   (无 sudo 能否 lsof 自己用户的进程)、每次点击链接都跑一遍的延迟数量级(实测)。
2. **CDP 交互**:bun fetch 对 `http://127.0.0.1:<port>/json/version|/json/list`(GET)与
   `/json/new?<url>`(PUT,新版 Chromium 必须 PUT)—— 参考实现的 percent-encoding 手法
   在 fetch 下的等价写法;超短超时(0.8s/2s)的实现方式。
3. **打开浏览器**:`open -b <bundleID> <url>` / `open -a <path> <url>` 与参考实现
   `NSWorkspace.open(activates: true)` 的行为等价性(激活、错误码、目标 app 不存在时)。
4. **本机实况**:Roxy 实际是 `/Applications/RoxyBrowser.app`(参考默认写的是 RoxyChrome.app,
   纯配置差异)—— 核对其主进程命令行形态、`--remote-debugging-port`/profile 路径标记是否
   与参考项目的 `roxyProcessMatch`/`roxyProfilePathMarker` 匹配逻辑兼容。**只读观察**,
   不碰用户的 Roxy 数据。
5. **延迟预算**:用户点击 → 浏览器响应的全链路(LS 启动壳[冷/热] + UDS 往返 + 决策 +
   ps/lsof/CDP)大致数量级;哪一段最贵,值得在 spec 里立什么缓存/短路策略(只列事实与
   选项,不做裁定)。

**纪律**:只读研究;探测/实验在 job tmp 或 worktree 内;不改系统状态、不动用户 mihomo/Roxy。

产出:`docs/research/url-router-ts-port-facts.md`,落 `research/url-router-ts-port-facts` 分支。
答案喂 [06](06-spec-final.md) 的 spec 定稿。

## Answer

五问全部落定(含本机实测数据),findings 全文见 [docs/research/url-router-ts-port-facts.md](../../../docs/research/url-router-ts-port-facts.md)。一句话版:

1. **进程探测**:bun spawn `ps` 全表 15.6ms、`lsof` 单进程 21.3ms(中位),免 sudo;参考形状照搬,单击成本 40–60ms。
2. **CDP**:裸 fetch + `AbortSignal.timeout` 直译;唯一真坑 —— `encodeURI` 不编 `#` 而 Swift `.urlQueryAllowed` 编,`/json/new?<url>` 必须显式补 `%23`,进 kernel 测试。
3. **开浏览器**:`open -b`;错误路径实测 exit 1 + stderr 结构化可判,成功路径 e2e 期补。
4. **RoxyBrowser**:纯配置值替换(`/RoxyBrowser.app/Contents/MacOS/RoxyBrowser`,id `com.roxybrowser.app`),匹配形状不动;profile 标记待 Roxy 跑起后人工核对。
5. **延迟预算**:热路径 <100ms 无感,V1 可不加缓存;冷路径大头是拉壳与 Roxy 启动(本就带重试),可选优化只列进 spec 不裁定。

附移植对照草表(Swift 段落 → bun 落点),直接喂 06。

## Comments

- 2026-09-03 铺图会话:已派 research 子代理(Opus,worktree 隔离)。
- 2026-09-03:子代理连撞 API 529 过载,用户裁定收回主会话执行;findings 直接落工作区(未分支),调研完成。
