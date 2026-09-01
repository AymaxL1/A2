# 17 — 卸载补全:`service uninstall --purge` + 面板卸载框「同时删除 ~/.a2」勾选

**What to build:** 把「显式卸载」做完整,补齐 14–16 票留下的「删 app ≠ 卸干净」缺口:内核长出 `a2 service uninstall --purge`(拆 kernel unit → 拆托管的 `com.a2.mihomo`(若在)→ 删整个 `$A2_HOME`,先看后删、如实列账);面板的卸载确认框加一个默认不勾的「同时删除 ~/.a2(内核拷贝、数据与托管的 mihomo)」勾选,勾了就走 `--purge`。此后小白的零残留路径 = 菜单卸载(勾选)→ 拖 .app 进垃圾桶(只剩 macOS 惯例的偏好 plist)。ADR 0012 白名单与卸载对等两条挂修订记。

背景:用户裁定采纳小修(不动 launchd 架构、不上 SMAppService)。multica 的对照事实:它没有任何卸载逻辑,靠「不注册系统服务」绕开,数据目录照留——a2 选择把显式卸载做全,而不是学它。红线重申:**用户自己的 mihomo(`io.metacubex.mihomo`,pid≈553,33888)永远不在任何清理范围内**,purge 只碰 `com.a2.*` unit 与 `$A2_HOME`。

**Blocked by:** 14/15/16(已全部落地,HEAD fe94c0d)。

**Status:** done — 980ee0a+6c0e86f(CR 尾款 e6e7347+131e933) 卸载补全落地:`service uninstall --purge`(拆两个 com.a2.* unit + 删 $A2_HOME,接管态 fail-closed 拒绝且零删除)+ 面板卸载框默认不勾的「同时删除 ~/.a2」勾选,白名单恰增一形态

- [x] `a2 service uninstall --purge`:既有拆 kernel unit 之后 → 经 supervisor 抽象拆 `com.a2.mihomo`(不在则不报该 action)→ 删 `$A2_HOME` 整目录;actions 如实新增(如 `mihomo_unit_removed`/`home_purged`),机读面列出移除的 unit 与路径(先看后删的对账面);`--purge` 仅对 uninstall 合法,install/status 带它报 usage 错
- [x] **系统代理仍处接管态时 purge 结构化拒绝 + 指引**(先 `a2 proxy off` 或面板「关闭系统代理(还原)」再来)——否则删掉托管 mihomo 会当场断网且还原依据随 `$A2_HOME` 一起消失;判定用接管记录的既有机制(不经 daemon 可读),拒绝路径有测试
- [x] 自删合法性:从 `$A2_HOME/bin/a2` 运行 purge(删除正在执行的自身)正常完成并退出干净,编译产物链有测试
- [x] 契约同步:actions 词表 + 机读移除清单走既有 schema/golden 纪律(`ServiceChangeResult` 的 Swift 镜像豁免已覆盖面板用法,按需更新豁免注记);`--json` 面照既有约定
- [x] 面板:卸载确认框加默认不勾的勾选(accessory,不用 suppression 按钮——语义不对);勾选状态流入执行器,argv 白名单**恰增一形态** `service uninstall --purge`(白名单断言同步);两种模式的文案各自如实(不勾:只拆服务、数据留下;勾:列明删什么、用户自己的 mihomo 永不在内);purge 被拒(代理未还原)时失败面如实呈现指引
- [x] ADR 0012 第 3 条(白名单)与第 6 条(卸载对等)挂修订记(日期 + 理由:删=净的显式路径);`docs/runbooks/distribution.md` §4.1 小白卸载路径改写;`docs/agents/a2-cli.md` 补 `--purge`
- [x] 门禁 8 步全绿;变异验证:拒绝判据抹掉看拒绝测试红、purge 范围断言(绝不含 `io.metacubex.*`)改错看红、面板 argv 白名单加第六形态看断言红

---

## CR 尾款(2026-08-10,`e6e7347` 内核 + `131e933` 面板/文档)

双轴 CR 均「过,有尾款」;尾款扎在题眼上 —— 那把 `rm -rf $A2_HOME` 缺护圈。本轮全收:

- [x] **必修 1 rm 地板**:`purge-guard.ts` 四条不变量(绝对路径 / 非根 / 非家目录本身 / 非家目录祖先),
      纯函数 + 家目录可注入 → 病态值在**单元缝**上验完,门禁绝不真造 `A2_HOME=/` 去跑删除。
      新码 `service_purge_unsafe_home`(6:这条请求在这个 $A2_HOME 上根本不成立)。
- [x] **必修 2 symlink 假账**:`lstat` 判链 → 结构化拒绝 + 给出链目标;dangling 同样如实。
      拒绝后链在、链目标那棵树完好、unit 未动,有 CLI 缝用例。
- [x] **必修 3 多 A2_HOME**:注释补齐(label 每用户一个 × home 每次调用一个);
      **交叉核对**读盘上两份 unit 各自的 home 指纹(内核 = `A2_HOME`,mihomo = argv[0] 落点),
      对不上即拒(`service_purge_home_mismatch`,1);两份都不在则放行。读不出指纹同样拒。
- [x] **必修 4 runbook 数错行**:`--purge` 替代第 2、3、5 条,不含 `install.sh --uninstall`。
- [x] 顺手 5–10 全收(`^/` pattern、mihomo 拆不净用例、guidance 第 11 份快照、退出码两段式、
      「那两个 launchd 服务」措辞、两处注释改真)。
