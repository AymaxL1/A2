# 04 — 常驻成本、系统集成与发布链

Type: research
Status: claimed

## Question

ADR 0002 给 Electron 记的三笔成本(常驻内存、8 周 major+Chromium 安全流水线、原生感隔层)在 2026 年的真实账,以及发布链对标:

1. **常驻足迹**:Tray-only(无主窗或隐藏窗)Electron app 的真实 RSS 参考(近版数据,区分主进程/GPU 进程/渲染进程;`backgroundThrottling`、销毁窗口只留 Tray 等策略的效果);与 Swift 菜单栏 app(~30-60MB 级)对照。24/7 代理场景这笔账要诚实。
2. **维护税**:8 周 major 的实际升级动作量(近一年 major 的 breaking changes 密度);只跟 LTS 式旧版行不行(安全修补支持窗口多长);Chromium CVE 对「不加载远程内容的本地 app」的实际暴露面。
3. **系统集成对标**:登录项 `app.setLoginItemSettings`(mac 15 上对应 SMAppService 的哪种;系统设置里怎么显示);`app.dock.hide`/LSUIElement;UserNotifications 对标(Electron `Notification` 在未签名/ad-hoc 下是否可用——Swift 侧无签名会崩,Electron 侧要核实);菜单栏 Tray 的模板图标/暗色适配。
4. **更新链**:electron-updater(或 Squirrel.Mac)做「用户确认才更新」(对标已定的 Sparkle 方案,不做静默)的支持度;更新包签名要求;无证书开发期怎么办。
5. **mihomo 打包复核**:内核二进制放 asar unpack/extraResources;electron-builder 对 extra 二进制的重签是否自动;子进程 spawn/生命周期管理在 Node 的形态;GPL 边界(子进程+REST)与 ADR 0007 义务不因栈变——确认。
6. **app 体积**:近版 Electron 的 .app/.dmg 基线体积(mihomo ~41MB 之外再加多少)。

## Context

- `docs/adr/0007-mihomo-subprocess-gpl-compliance.md`、02 票调研 `docs/research/mihomo-integration.md`(其中已含 Electron 侧壳先例,如 Clash Verge 前身/ClashX 对照——沿用别重查)。
- 路线图 Phase 3(Sparkle、EdDSA、用户确认更新)是被对标的既有决定。

## Output

`docs/research/electron-recon/resident-release.md`(中文;内存与体积给出多来源数据点而非单一数字;每笔「维护税」给出可核查来源)。
