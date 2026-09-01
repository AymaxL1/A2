# 13 — 分发工件:curl 安装脚本 + `a2 about` + GPL 静态文本 + 随附 .app

**What to build:** V1 分发形态成型:用户单文件直接下载或 `curl` 一条安装脚本装好 `a2`(含 PATH 就位与 `a2 service install` 指引),`a2-panel.app` 作为可选客户端随附带包;`a2 about` 输出版本、许可与 GPL 声明(「调用外部 GPL 程序」口径),同一静态文本随包分发——GPL 义务履行不依赖任何 UI。发布元数据同时承载 mihomo 锁定版本(06 票安装档的版本源)。

**Blocked by:** 05(service)、10(壳切换后出包)。

**Status:** done — 172c3f5 + c206c54(CR 修复)

- [x] 安装脚本一条命令完成:下载对应平台单文件 `a2`、校验、落 PATH,结束时打印含 `a2 service install` 的下一步指引;卸载路径有文档口径
  - `Scripts/install.sh`(POSIX sh,不用 jq)。平台探测(`uname` → `<os>-<arch>`,平台键与 TS 侧的 `KERNEL_TARGETS` 有对账断言)→ 取发布元数据 → 按平台挑资产 → 下载 → **SHA-256 校验**(对不上一个字节都不落盘)→ chmod + `a2 version` 自检 → 同目录临时名 + `mv` 原子落位。
  - **PATH 落点**:默认 `~/.local/bin`(`--dir` / `A2_INSTALL_DIR` 覆写)。**不要 sudo、不改 shell 配置** —— 不在 PATH 时只打印该加哪一行。
  - **幂等**:同版本重跑不下载(断言判据是渠道那边的**请求数**没涨)、不改动、退出 0、指引照打。
  - **卸载**:`--uninstall` **先看后删** —— `com.a2.*` 的 unit 文件或 `<A2_HOME>/system-proxy.json` 还在就拒绝删 bin(删了就没有工具能收拾它们了),判据全是"文件在不在",不调任何 supervisor。完整顺序口径见 `docs/runbooks/distribution.md` §4。
  - 断言:`kernel/test/install-script.test.ts` 18 条(渠道用回环 `Bun.serve` 与本地目录两种夹具,不出网)。
- [x] `a2 about` 输出版本、许可信息与 GPL 声明(调用外部 GPL 程序口径);同一静态文本作为独立文件进分发包
  - `a2 [--json] about`:**不经 daemon、不碰任何状态**(断言:跑完 A2_HOME 里一个文件都没多)。内容 = 版本/协议、a2 本体许可口径、外部程序表(mihomo:GPL-3.0、锁定版、源码、发布渠道、**独立子进程红线原文**、`bundled: false`)、随包静态文本落点与在不在、升级口径(**没有静默更新**)。
  - 契约 `AboutResult` 进 `CONTRACT_SCHEMAS` + 金标两份(其中非法样本冲着 `bundled: true` 去 —— 「不随包分发」是 schema 层的承诺);Swift 侧登记为有意不镜像并写了理由。
  - 随包静态文本 = **`a2 about` 的输出原样落盘**(`NOTICE-external-programs.txt`),外加 `docs/legal/` 那份 GPL-3.0 全文。
  - 断言:`kernel/test/cli-about.test.ts` 15 条。
- [x] 发布产物集齐:macOS 与 Linux 的 `a2` 单文件、`a2-panel.app`(可选随附)、静态声明文本、承载 mihomo 锁定版本的发布元数据
  - `Scripts/release-assemble.sh` 一条命令产出全套 + `a2-release.json`(版本、各工件 SHA-256、**mihomo 锁定版**),末尾**自检**:用包里那个 bin 跑 `a2 about --json`,确认它看得见随包的两份文本。
  - 元数据 schema(`kernel/src/release/manifest.ts`)有两条 fail-closed 结构约束:**声明文本与 GPL 全文各恰好一份**、**不认识的文件不许混进发布包**。
  - **Linux 产物**:`--target=bun-linux-x64` 现场交叉编译通过(95,443,072 字节,`file` 报 `ELF 64-bit LSB executable, x86-64`,魔数 `7f 45 4c 46`)。**本机跑不了它** —— 只验到"能产出 + 文件头对",实机验收记为人工项。
  - 断言:`kernel/test/release-manifest.test.ts` 16 条(含摘要与系统 `shasum -a 256` 对照、组装脚本真跑两遍:假 bin 验结构 + 真产物验自检)。
- [x] Homebrew Formula 不做,列后续渠道备忘;静默更新不存在(升级永远显式)
  - 后续渠道备忘表(Homebrew / GitHub Releases / Sparkle / 包管理器 / App Store)在 `docs/runbooks/distribution.md` §7,每条写明"真要做时需要什么"。
  - 「升级永远显式」三处成文**并各有断言**:`a2 about` 的 `upgrade` 字段、安装脚本结束时的提示、分发 runbook §3 —— 三处由 `release-manifest.test.ts` ▸「三处落点都在文」一条钉住(CR 必修 6 补的:runbook 那处此前只是散文)。脚本不留定时任务、不写 shell 配置、不后台自查版本。

**12 票 CR 尾款(三项,同提交)**:
- a `bundle.ts` 异常路泄漏 + 构建区无启动清扫 → 工作区生死收敛到**一层**(失败/抛出即删,成功交调用方);新增 `sweepStaleBuildAreas()`,**按年龄**清扫(1 小时 = 构建超时默认值的 20 倍,不误删别的 daemon 正在飞的构建区),daemon 启动与每次 add 各扫一次。3 条断言。
- b install/build 输出撞 4MiB 被误报「失败(exit=-1)」→ 消费 `captureProcess` 的 `overflow` 标记,出**超限专属报文**(哪条流、上限多少、怎么自己查),`exit=-1` 不再出现在给 agent 的报文里。2 条断言(install / build 两处)。
- c `host.ts` remove 写清单无 try/catch → 补上并与 add **对称回滚**(把能力放回注册表)。1 条断言,**变异验证过**(去掉回滚那一行 → 当场红)。

**顺延 13 的 7 条对等映射账**:全部兑现,逐条见 `kernel/test/swift-parity-map.md` 的「13 票收口」一节。

**CR 修复(Fable 5 两轴,2026-08-05 中午)**:**已过** —— 2 条必修真缺陷 + 5 条小项,全部做完。
1. 随包 NOTICE 自述「GPL 全文不在此处」而它就在同目录,且烙进组装机绝对路径 → cp 挪到 about 之前 +
   人类面只说相对位置 + 自检加**字节级**(重跑 about 与落盘那份 `cmp`)与内容(无「不在此处」、无组装机路径)三条断言。
2. `--uninstall` 只查 `~/.config/systemd/user`,而内核尊重 `XDG_CONFIG_HOME` → 判据同源化(两条都查)+ 断言。
3. 校验工具探测的 `die` 在子壳里 → 前置成 `HASH_CMD`,开工前判死;断言是「渠道那侧一次资产请求都没有」(变异验证过)。
4. uname 映射双写 → 两个脚本的 `case` 表逐条对账断言。
5. `4MiB` 渲成「4096KiB」 → `formatBytes`(MiB/KiB/字节数)。
6. 框 4「三处各有断言」中 runbook 那处此前只是散文 → 补断言 + runbook 口径对齐。
7. 人工项清单归一:`docs/runbooks/distribution.md` §8 扩成**完整并集 9 条**(每条注原始落点),nightlog 与之逐条对齐。

CR 后门禁:步 PASS=8 FAIL=0(`bun test` 375 → **381**),日志 `/tmp/a2-check-13cr.log`;组装/安装链手工重跑一遍全对。
