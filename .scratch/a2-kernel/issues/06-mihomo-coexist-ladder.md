# 06 — mihomo 共存阶梯:检测、复用、脚本安装

**What to build:** 蓝图第③步的装备半边。内核长出 mihomo 获取与共存能力(mihomo 不随包分发,12 票):`a2` 检测本机 mihomo 现状并按阶梯就位——①运行中实例(external-controller 可达)→ 经 API 接管配置与监督,进程生死归原托管方;②仅有二进制 → 只读复用,配置/数据/unit 全套自建;③全无 → 安装脚本从官方渠道拉取、版本按发布元数据锁定,挂 `com.a2.mihomo` 系统 unit(自启/崩溃重拉归系统)。升级永远显式。

**Blocked by:** 04(控制面)、05(unit 管理机制)。

**Status:** done — a24597d(06 主体)+ ccd7bb6(05 票 CR 尾款)三档阶梯 + 兼容地板 + 显式升级全落地(bun test 114/0、tsc 干净、check.sh PASS=429 FAIL=0),用户自己的 mihomo 全程未被触碰

- [x] 检测命令机读报告本机 mihomo 现状(运行实例/仅二进制/全无)及将采用的阶梯档位
      → `a2 mihomo status --json` 出 `MihomoStatusResult`:`presence` 三态 + `rung` 三档 + `provisioned` + 双方各自的事实
        (别人的实例/别人的二进制/a2 自管那份)+ `compatibility` + `lockedVersion`。三态**都是退出码 0**(与 `a2 service status` 同口径)。
        **扫描面全注入**:`A2_MIHOMO_BIN_DIRS` / `A2_MIHOMO_CONFIG_FILES` / `A2_MIHOMO_CONTROLLER` / `A2_MIHOMO_CONTROLLER_PORT` /
        `A2_MIHOMO_RELEASE_BASE` / `A2_MIHOMO_EXPECT_SHA256`;无端口扫描、无进程表遍历,**非回环端点一律不探**(如实报 `skippedController`)。
- [x] 实例接管档:经 external-controller API 接管配置与存活监督;实例死亡只产出报警事件+结构化指引(含人类可执行的重启命令),内核不越权重拉
      → `install` 在收编档只落一笔**收编记录**(`<A2_HOME>/mihomo/adopted.json`),不装二进制、不写 unit;
        存活监督 = 只读 `GET /version` + `GET /configs`(controller.ts 里只有这两条 GET,没有任何写/重启端点)。
        实例没了 → `mihomo_unreachable`(退出码 5)+ 指引里带**从检测事实拼出来的那条前台命令**
        (`<别人的二进制> -d <配置目录> -f <配置>`),内核绝不重拉。
      **一处如实说明**:「报警**事件**」的推送面(订阅/确认器)归 08 票;本票产出的是同一份内容的**结构化报文**。
      **一处补注(07 票回填)**:本票落地的是「**只读**监督」那一半 —— `controller.ts` 里只有 `GET /version`
        与 `GET /configs`,标题里的「接管**配置**」当时并未落地,配置写面(`PATCH /configs` 等)顺延 07 票。
        **已由 07 票落地**(收编档写面到配置为止,`/restart`、`/upgrade` 仍永不触碰)。
- [x] 二进制复用档:只读引用既有二进制,配置/数据目录与 `com.a2.mihomo` unit 自建;兼容性下限不达标时回退隔离安装并说明原因
      → 落点 `<A2_HOME>/mihomo/bin/mihomo` 是一个**符号链接**(只读复用的字面实现:真身一个字节都不写,有断言),
        配置/数据目录/unit 全套自建;不达地板 → `rung` 回退 `managed_install` 且 `result.fallback` 写明原因。
- [x] 脚本安装档:安装脚本落锁定版本 mihomo 与 `com.a2.mihomo` 系统 unit,杀掉 mihomo 进程由系统按策略重拉
      → 锁定版 `v1.19.28`(与旧仓 `MIHOMO-VERSION.txt` 同源,有一条测试当场核对两处);下载 → gunzip →
        **SHA-256 校验 → 才落位**(校验不过时磁盘上一个字节都没写,有断言);unit 复用 05 骨架的同一套渲染器,
        `KeepAlive.Crashed` + `RunAtLoad` / `Restart=on-failure` + `WantedBy=default.target` 逐键有断言。
      **一处做不到项**:mihomo 侧**没有**真 launchd 活体冒烟(那意味着在跑着用户自己 mihomo 的机器上 bootstrap 一个
        `com.a2.mihomo` 并拉起一个真 mihomo)。unit 内容与编排在假件上逐条有断言,真 supervisor 的自愈语义已由 05 票活体冒烟证过
        (同一套 plist 键、同一个渲染器)。补做应与 5 条人工项同批、在干净机器上进行。已记进 `swift-parity-map.md` 06 票 C 组末尾。
- [x] mihomo 升级是独立显式命令,任何路径都不静默换版本;全流程测试用假 mihomo 夹具,绝不触碰本机用户自己的 mihomo(施工红线)
      → `install` 在已有自管二进制时**绝不下载**(渠道上摆着新资产也视而不见,有断言:去掉这条判断即红);
        只有 `a2 mihomo upgrade` 会换版本,且换完显式重启进程(旧进程攥着旧 inode)。
        升级对象只能是 a2 自管的下载版:收编档与复用档一律 `mihomo_not_managed`。
        **红线**:门禁里的每一个「mihomo」都是 `test/support/fake-mihomo/`(行为假件,不下载真内核);
        全程未连 33888、未 launchctl 任何 mihomo 相关 unit、用户的 pid 553 跑完照旧。
