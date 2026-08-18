---
status: accepted
date: 2026-08-18
---

# mihomo 内嵌子进程化（小白第一）：托管模式、子进程保活与 agent 指引

2026-08-18 用户裁定（六轮面试收口，两个中间方案被明确推翻）：**mihomo 从「独立 launchd unit」改为 a2 daemon 的直接子进程，随 a2 生、随 a2 死**；与本机 mihomo 的关系收敛为**三值托管模式** `off / observe / embedded`，「共存阶梯」概念退场。本 ADR 是该批决定的总纲；对 [ADR 0007](0007-mihomo-subprocess-gpl-compliance.md)/[ADR 0008](0008-kernel-bin-ui-optional.md)/[ADR 0012](0012-panel-self-sufficient-bootstrap.md)/[ADR 0013](0013-readonly-coexistence-and-suspended-write-face.md) 的修订各自文内注明。

## Context

- **目标用户重申**：这轮重审的第一句话是「我的目标是给小白用」。现状里 mihomo 挂自己的 `com.a2.mihomo` unit——机器上两个 launchd 服务、两条升级线、卸载两笔账，对运维者是清晰，对小白是费解。**子进程是最简单的心智模型：mihomo 是 a2 的一部分；代理出问题，退出 a2 就全关了。**
- **两个中间方案被推翻（记档防返工）**：①「维持 launchd 托管、只加 CLI 指引」——效果面现状已有，但小白心智模型不闭环，被推翻；②「a2 全面退为观察者+导游，安装配置自启全归 agent」——小白拿不到开箱可用，被推翻。
- **技术地基（2026-08-18 研究票，本机实测 macOS 15）**：launchd 对 job 的四种死法（bootout / 崩溃 / SIGKILL / 正常退出）都会清理**同进程组**子进程，但手段是**可捕获的 SIGTERM 而非必杀**；`AbandonProcessGroup` 默认 false（默认清组）；**`KeepAlive.Crashed` 不覆盖 SIGKILL**（jetsam 恰用 SIGKILL）。全文 `docs/research/launchd-child-subprocess-lifecycle.md`（research/launchd-child-lifecycle 分支，commit 96d2168）。
- **决策原文**：`.scratch/mihomo-embedded/`（map + 01 裁定底账 18 条 + 04/05 文案定稿——本机决策记录，未入库）；本 ADR 正文自足。

## Decision

1. **mihomo = a2 daemon 直接子进程**，随 a2 生死；`com.a2.mihomo` unit 退场，全机只剩 `com.a2.kernel` 一个 unit。[ADR 0008](0008-kernel-bin-ui-optional.md) 第 6 条「应用层不造看门狗」对 mihomo 开显式例外（a2 自身仍归系统 supervisor）；07 票「数据面不随控制面起落」不变量**废除**——a2 重启/升级 = 代理瞬断数秒，是「小白第一」下显式收下的代价。
2. **托管模式三值 `off / observe / embedded`**。`off` 出厂默认；`observe` = 只读旁观外来实例（[ADR 0013](0013-readonly-coexistence-and-suspended-write-face.md) 只读契约原样并入）；`embedded` = a2 子进程。模式是**用户显式裁定、一次性落盘**的配置（面板引导页 / `a2 mihomo enable --mode=…`、`a2 mihomo disable`）；daemon 每次启动照配置办事，外来实例出现/消失只出事件、**不自动切换**。
3. **首启引导（面板，04 票文案定稿）**：未检测到外来 mihomo → 弹窗**默认勾选**「启用内置代理内核（推荐）」，一次点击带过；检测到外来 → **双卡片必须人选**（无默认、不选不给继续）。首启那次点击的授权范围**含下载 mihomo 锁定版**——弹窗文案明写版本号与体积。「稍后」不再纠缠，菜单常驻入口。
4. **保活与编排（研究票四层）**：①子进程崩溃**节流重拉**，连续 N 次失败转**故障状态** + 结构化指引（带 stderr 原文与配置路径），不无限风暴；②spawn 恒同进程组（**绝不给 mihomo 套 setsid/daemonize**），plist 不设 `AbandonProcessGroup`；③daemon 收 SIGTERM → 转发给 mihomo → 超时 SIGKILL → **exit 0**（launchd 不对进程组升级 SIGKILL，这步只有 a2 能做）；④**启动认尸**：mihomo 的 pid+启动时间+二进制路径落盘，每次启动（含重拉）先校验身份杀残尸、再 spawn。不变量「a2 死 mihomo 死、不留孤儿、不双跑」由 组SIGTERM ∪ 退出钩子 ∪ 认尸 闭合。**顺带修复**：`com.a2.kernel` 的 KeepAlive 改 **`{Crashed:true, SuccessfulExit:false}`**，补上「kill -9 后不自愈」缺口（实测 OR 语义有效）；代价是**一切主动停止路径必须保证 exit 0**，值一条测试红线。
5. **配置权与生效**：agent 改 YAML 是唯一配置路径（[ADR 0013](0013-readonly-coexistence-and-suspended-write-face.md) 方向不变）；生效 = **`a2 mihomo restart`**（显式重启子进程，瞬断可接受）；REST reload 不做（暂缓）。写面九条维持摘注册留码。自家配置头部继续写 `external-controller`（仅回环 + secret），**读状态走 controller GET**——「不搞 restful」的准确口径是**不做写面**，读面照常。
6. **升级随 a2 走**：mihomo 版本锁死在 a2 里；a2 升级后锁定版变 → 下次拉起子进程前自动换二进制（授权由 a2 升级本身的显式性覆盖）。独立 `a2 mihomo upgrade` 退场；`reuse_binary` 档退场，embedded 一律下载锁定版（SHA-256 校验照旧）。**mihomo 仍不随包分发**（[ADR 0007](0007-mihomo-subprocess-gpl-compliance.md) 该条不动）：enable 时才从官方渠道拉取。
7. **并跑与端口口径**：选 embedded 时外来实例在跑 → **允许并行**（端口自动错开），指引建议**经用户同意后**停掉外来那份；系统代理谁后按谁生效，如实告知。observe 模式外来实例无 controller 时，`proxy system enable` **必须 `--port` 显式带参**——不猜端口，猜错 = 断网。
8. **迁移**：检出旧版 a2 自装的 `com.a2.mihomo` unit → embedded 启用时**自动 bootout + 删 plist**、审计留痕（自己的遗产自己收）；`service uninstall --purge` 继续认得旧 label 兜底。**别人的 mihomo 永不动**（硬红线）——任何路径都只指引、不动手。
9. **agent 接口（05 票文案定稿）**：面板菜单项「**复制 AI 助手使用说明**」——未安装也出现，内容随状态自适应（未装版 = 教 agent 引导用户点菜单安装，**明文禁止 agent 绕后调 `.app` 内嵌 bin**）；`a2 mihomo status` 的 guidance 六态逐字稿定稿（off 无外来 / off 有外来 / 故障 / observe 无 controller / 并跑提醒 / 未配置节点），**第一读者是 agent**，人以第三人称出现。CLI 仍不进 PATH（[ADR 0012](0012-panel-self-sufficient-bootstrap.md) 第 7 条不动）。
10. **「尚未配置节点」的小白落点**：面板不做配置 UI；状态提示行**可点击 = 复制 AI 助手说明**并反馈「已复制」，把人引向 agent。

## Consequences

- **全机一个 unit**：装/卸/排障的账都少一半；purge 范围事实收窄（子进程状态记录仍在 `$A2_HOME` 内，卸载面不变）。
- **既有机器三分处置**：**复用** = 下载/SHA-256/锁定版机器、监督循环（对象改为自己孩子）；**删码** = `com.a2.mihomo` unit 渲染与编排、reuse_binary symlink、独立 upgrade；**不动** = observe 只读契约、写面摘注册。07 票已验收断言中「杀掉 daemon，mihomo 照跑」一族随不变量废除**改判**（处置进实施 spec）。
- **面板白名单恰增数条** mihomo 域命令（enable/disable/restart/status 类），铁律不变：每条占一个枚举成员、逐字进断言、壳零业务逻辑；具体条目实施 spec 定。
- **节点合并 CLI 地位上升**：agent 改配置的趁手兵器，guidance「未配置节点」态第 2 步等它回填命令原文——命令名等五问仍待用户裁定（a2-kernel 20 票）。
- **接受的代价**：a2 升级/重启断流数秒；mihomo 进程生死与 a2 强耦合（这正是要的）；KeepAlive 双键要求一切正常退出路径 exit 0。
