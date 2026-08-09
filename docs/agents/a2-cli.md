# 给 agent 的 a2 接入指引

> **它有意写得短**：CLI 自己的帮助就是规格书，抄一份到文档里只会开始漂移。
> 凡是"具体有哪些命令、哪些参数、哪些能力"的问题，答案都在 `a2 help` 与 `a2 capabilities list --json` 里，
> 那是**这台机器上这一版内核**说的话，比任何文档都新。

## 一句话

用 Bash 起子进程执行 `a2 <子命令> --json`，从 stdout 读一条 JSON。零协议、零配置、零 SDK。

```bash
a2 capabilities list --json      # 这台机器上现在能调什么（含风险档与参数声明）
a2 capabilities call proxy.status --json
a2 proxy status --json           # 等价写法：域子命令面
```

`--json` 时 **stdout 上只有一条 JSON 包封**，成功与失败同一形状：

```jsonc
{"v":1,"id":"…","ok":true,"result":{ … }}
{"v":1,"id":"…","ok":false,"error":{"code":"…","message":"…","guidance":{ … }}}
```

无 `--json` 时才是给人看的散文（失败走 stderr）。机读面永远不掺散文。

## 退出码（粗分类走退出码，细因走 `error.code`）

| 码 | 含义 | 你该怎么办 |
|---|---|---|
| 0 | 成功 | 读 `result` |
| 1 | 用法错（参数写错、未知子命令） | 按 `guidance` 改命令再试 |
| 2 | denied（dangerous 被拒） | **不要重试**：把 `guidance` 原样转告用户，由人去完成 |
| 3 | 超时（确认器在场，但没人在窗口内做决定） | 告诉用户"那条确认还没人点"，可稍后重来 |
| 4 | daemon 不可达（没装 / 没跑） | 转告用户跑 `a2 service install`——内核**永不隐式拉起** daemon |
| 5 | 执行了但事没办成 | 读 `error.detail`，多半要改参数或先修环境 |
| 6 | 协议 / 校验错（参数不合声明、能力不存在） | 用 `a2 capabilities describe <id> --json` 对一遍参数 |

## dangerous：三层仲裁，没有旁路

风险三档写在每条能力的 manifest 里（`a2 capabilities list --json` 的 `risk`）：`safe` 只读直通、
`normal` 可逆写直通、`dangerous` 需要**真人在场证明**。

- 没有确认器在场 → `confirmation_unavailable`（退出码 2），**fail-closed**；
- 有确认器（mac 的菜单栏壳「A2 Panel」）→ 带外确认，人批准才执行，拒绝是 `confirmation_denied`（2）、
  没人应答是 `confirmation_timeout`（3）；
- **确认信息永不过你之手**：你既发不出批准报文，也看不到确认界面。

**永远没有的东西**：`--yes` 类旁路、TTY 交互确认、"帮用户点一下"。CLI 也永不交互阻塞——
它不会挂在那里等谁，所以你的执行流程不会被挂住。

## 拒绝即指引：你只转告，不代跑

每条"这条路走不通"的报文都带 `guidance`：

```jsonc
"guidance": {
  "summary": "…",
  "steps": [{"description": "…", "command": "a2 service install"}],
  "context": {"capability": "proxy.subscription.add", "risk": "dangerous"}
}
```

`steps[].command` 是**给人原样执行**的精确命令。把它转告用户，不要替他跑，也不要自己找绕路。

## 插件：现场写一个，当场可用

零依赖单文件 `.ts` 写完就能装，没有任何装载闸：

```bash
a2 plugin add ./hello.ts
a2 capabilities call plugin.hello.greet --input '{"who":"世界"}' --json
```

**协议规格书是 `a2 plugin --help`**——describe/call 的报文形状、退出码词表、一个可逐字抄走的最小例子、
带 npm 依赖的目录插件怎么交、打不进单文件时的拒绝面，全在那一屏里。这份文档不复述它。

## 常用环境变量

| 变量 | 作用 |
|---|---|
| `A2_HOME` | 覆写 `~/.a2`（socket、插件登记区、订阅、日志都在里面） |
| `A2_PLUGIN_TIMEOUT_MS` | 插件一次 describe/call 的窗口（默认 15000） |
| `A2_PLUGIN_BUILD_TIMEOUT_MS` | 目录插件装载期 install+bundle 的窗口（默认 180000，与上一条不是同一个旋钮） |
| `BUN_INSTALL_CACHE_DIR` | 装插件依赖时的包缓存（缺省 `~/.bun/install/cache`） |

## 装、升级、许可

- 安装与卸载口径见 [分发与安装 runbook](../runbooks/distribution.md)；
- **升级永远显式**（重跑安装脚本或换掉那个单文件），a2 不做静默更新；
- 许可与 GPL 声明读 `a2 about`（不依赖 daemon、不依赖任何 UI）。

### 服务面三条命令（`a2 service status|install|uninstall --json`）

它们**不经 daemon**——daemon 没跑的时候恰恰最需要它们答话，但机读面与走 daemon 的命令同一形状，
你看不出区别。两个字段值得单说：

| 东西 | 是什么 |
|---|---|
| `service status` 的 `binPath` | unit **实际指向**的那个可执行（读盘上那份 unit 的事实值）。unit 还不存在时给的是本次 `install` 会写进去的那个。「托管的是不是我这份内核」只有它答得了 |
| `service install --copy-to-home` | 把**当前这个 a2 单文件自己**原子拷进 `$A2_HOME/bin/a2`，并让 unit 指向那份拷贝。幂等（判据是内容）；拷贝换了而服务正跑着时会显式重启，如实报 `kernel_restarted`。mac 菜单栏壳「A2 Panel」走的就是这条（见 [ADR 0012](../adr/0012-panel-self-sufficient-bootstrap.md)） |

`--copy-to-home` 只对 `install` 有意义，用在别的子命令上是用法错（不会被默默忽略）。
源码态跑它会得到 `service_self_copy_unsupported`（退出码 6）——那时的"自身"是 bun 而不是 a2，
拷过去只是个跑不起来的空壳；拒绝时 unit / bin / supervisor 三处一个字节都不动。
`actions` 是封闭词表（`bin_copied` / `unit_written` / `unit_removed` / `supervisor_*` /
`kernel_started` / `kernel_restarted`），**空数组是合法且常见的**：幂等复跑什么都不改。
`uninstall` **只拆 unit**——`$A2_HOME/bin/a2` 那份拷贝与 `~/.a2` 里的数据要清理请显式删。

## 别处的权威

| 想知道 | 去哪儿 |
|---|---|
| 有哪些子命令、参数怎么写 | `a2 help`、`a2 <域> --help` |
| 这台机器现在能调什么 | `a2 capabilities list --json` |
| 某条能力要什么参数 | `a2 capabilities describe <id> --json` |
| 插件协议 | `a2 plugin --help` |
| 报文的机器可读契约 | `kernel/contract/schema/*.schema.json`（JSON Schema）与 `kernel/contract/golden/`（金标样本） |
| 为什么是这样设计的 | [docs/adr/](../adr/)（0004 能力面、0005 仲裁、0007 GPL、0008 内核 bin 化、0011 插件） |
