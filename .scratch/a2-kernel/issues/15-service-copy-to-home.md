# 15 — 面板自足·内核侧:`service install --copy-to-home` + 线上内核版本 + `status.binPath`

**What to build:** 内核长出「被面板引导」所需的全部机制,面板只当调用者:`a2 service install --copy-to-home` 把自身原子拷贝到 `$A2_HOME/bin/a2` 并让 unit 指向拷贝(含「bin 内容变了且服务在跑 → 重启服务」的收敛升级语义);hello/全量快照携带内核版本(面板升级检测的依据);`service status` 机读面补 `binPath`。契约改动走全套:wire zod → JSON Schema → golden 金标 → Swift A2Contract 手写镜像 → 对等覆盖表。

背景:「面板自足」方案已拍板(见 14 票背景节与 ADR 0012)。unit 指向拷贝而非 .app 的理由:免疫 macOS translocation、app 挪位/删除不断服;`service uninstall` 只拆 unit 不删拷贝(look before delete 的对位:数据同侧的东西留给显式清理)。

**Blocked by:** 无(与 14 票并行,文件集不相交)。

**Status:** done — cb06e3d `--copy-to-home` 原子拷贝 + 收敛升级(内容判据)+ `status.binPath` 读盘上那份 unit;hello 的内核版本查明本就在 `snapshot.status.version`(同一真值源),不新造第二个字段。

- [x] `service install --copy-to-home`:原子拷贝(临时文件 + rename,0755)process.execPath → `$A2_HOME/bin/a2`;unit ProgramArguments 指向拷贝;幂等(内容相同不报拷贝 action,报「本来就是这样」);非编译态(`Bun.main` 非 `/$bunfs/` 前缀)结构化拒绝,exit code 走既有约定
- [x] 收敛升级语义:拷贝内容变化且服务在跑 → 重启服务并如实报 action(仅 `com.a2.kernel`,经 supervisor 抽象;测试全走假 supervisor,绝不真 launchctl)
- [x] `service uninstall` 行为不变(只拆 unit,拷贝的 bin 留下),文档口径写明
- [x] hello/全量快照携带 kernelVersion(与 `a2 version` 同一版本源,不出现第二个真值);`ServiceStatusResult` 补 `binPath`(unit 实际指向的可执行)
- [x] 机读面从面板可达:`service install/uninstall/status` 三条命令均可输出机读 JSON(按仓库既有 `--json` 约定实现;当前 service 子命令拒绝一切多余参数,需放行该旗标,别发明第二套输出)
- [x] 契约全链同步:wire zod + JSON Schema + golden + Swift A2Contract 镜像 + 对等表更新;swift test 全绿
- [x] bun test 覆盖全部新分支(含 dev 态拒绝、幂等、内容变化重启、binPath),关键断言做变异验证;门禁 8 步全绿

## 实施记(与票面不同的三处,均已在报告与 nightlog 里留账)

1. **hello 的内核版本本来就在**:`KernelSnapshot.status` 就是 `StatusResult`,它自 03 票起带 `version`,
   取自 `runtime/version.ts`(← `package.json`)—— 与 `a2 version` 同一个真值源。再加一个 `kernelVersion`
   字段就是**造第二个真值**,与票面括号里的要求相反。故本票的落点是:补一条活体断言
   (注册那一帧的 `snapshot.status.version` 与 `a2 version` 输出逐字相等)+ 在此写明口径,不改 wire。
2. **`--json` 早就通了**:`main.ts` 在分发前就把 `--json` 从 argv 里摘掉了,所以 service 三条命令从 05 票
   起就能 `--json`(既有测试里一直这么调)。票面「需放行该旗标」的前提不成立。真正要放行的只有
   `--copy-to-home`;顺带把 `service.ts` 顶部「三条命令都不接受参数」那句注释改成真话。
3. **`binPath` 必须读盘,不能给计划值**:面板是从 `.app` 里跑 `service status` 的,若答「本次调用会写什么」,
   它会看到 .app 内那份 bin,而 unit 其实指着 `$A2_HOME/bin/a2`。故新增 `unitBinaryPath()`(两个渲染器的
   反向物,含 XML 转义与 systemd 引号/`%%` 的还原),status 先读盘上那份 unit;**只有 unit 不在、
   或形状解不出**(不是本内核写的 / 被人改坏了)这两种情形才回落到计划值
   (与 `unitPath` 未安装时给出「install 会写的位置」同一口径)。
