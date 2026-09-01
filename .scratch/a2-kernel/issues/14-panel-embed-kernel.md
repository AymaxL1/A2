# 14 — 面板自足·打包与门禁:内核 bin 嵌入 .app + APP8 修订 + ADR 0012

**What to build:** `A2 Panel.app` 从「纯壳」变「自带内核的完整分发单元」:`kernel/dist/a2` 嵌入 `Contents/Resources/a2` 并纳入签名链;build-app.sh 的 APP8 结构红线从「恰 1 个 Mach-O」修订为「恰 2 个」;新增嵌入 bin 的新鲜度/版本断言;release-assemble 与发布元数据如实记录「面板内嵌内核」;ADR 0012(面板自足引导)成文,并给 ADR 0008 第 6 条挂修订记。CLI 分发渠道(单文件 + install.sh)一字不动。

背景:multica 调研结论(桌面端把 Go 二进制打进 .app、GUI 只当发起者、GUI 不装 CLI 到 PATH、bin 版本随 app 走)已被采纳为 a2 的「面板自足」方案;区别于 multica 的是 a2 保留 launchd 系统托管(RunAtLoad + KeepAlive.Crashed),不学它的无看门狗 fork。三个已拍板的决策:首启弹一次确认框;unit 指向 `$A2_HOME/bin/a2` 拷贝(不指进 .app,免疫 translocation 与挪包断服);面板不提供「装 CLI 到 PATH」。

**Blocked by:** 无(与 15 票并行,文件集不相交)。

**Status:** done — 8bcaa7c .app 内嵌内核 bin(先内后外签名)+ APP8→2 个可执行 + APP9/APP10 + 发布元数据内嵌版本三处对账 + ADR 0012

- [x] build-app.sh:`kernel/dist/a2` → `Contents/Resources/a2`(0755);先签内嵌 bin、再签 bundle(ad-hoc 缺省,真身份沿用 `AA_CODESIGN_IDENTITY`);`kernel/dist/a2` 缺失或相对源码不新鲜时 FAIL(复用 11 票新鲜度判据,不发明第二套)
- [x] APP8 修订:恰好 2 个可执行(`a2-panel` + `Resources/a2`),注释改口径并引 ADR 0012;新增断言:内嵌 bin 执行 `version` 输出 = 本次构建的内核版本,且为 arm64 单架构
- [x] 门禁 8 步保持全绿;.app 步覆盖以上新断言
- [x] release-assemble:panel zip 即小白完整包(命名/说明如实);`a2-release.json` 记录 panel 内嵌内核版本;自检断言 zip 内嵌版本与 manifest 一致;NOTICE/GPL 义务不变(未新增任何 GPL 二进制,mihomo 仍不随包)
- [x] ADR 0012「面板自足引导」成文:显式点击边界(壳仍不隐式拉起,显式点击经嵌入 bin 的 service 命令引导)、执行器白名单(service install/uninstall/status、version)、copy-to-home 理由、升级永远显式、卸载对等、translocation/quarantine 备注;ADR 0008 第 6 条加修订记指向 0012
- [x] docs/runbooks/distribution.md:小白路径改写(下载 → 打开 → 点「安装并启动」),「先敲 a2 service install」口径仅保留给 CLI 渠道

**CR 尾款(589d0f5,2026-08-10)**:双轴 CR 过(Standards 有轻尾款、Spec 无必修),10 条一次收掉 —— APP9/APP11/版本步的一次性 `A2_HOME` 补 `mktemp` rc 守卫(必修:否则回落真 `~/.a2` 且「无残留」恒真)、`AA_BUN` seam 进出对称(check.sh 候选首位 / build-app.sh 硬 FAIL)、`export AA_KERNEL_BIN` 移进 ②b 成功分支、四处 `APP1–APP10` → `APP1–APP11`、组装探针多匹配即红、`bun build --compile` 成本口径三处统一(热 1 秒 / 冷十几秒)、`APP_VERSION` 挂「发版前待裁」注、`swift-parity-map` APP-8 补带日期批注。门禁 8 步全绿(bun 418 · swift 187)。
