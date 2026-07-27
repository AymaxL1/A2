# 02 — 宠物悬浮窗:S1 验收项在 Electron 的对标

Type: research
Status: open

## Question

S1 spike(Swift `NSPanel`+`NSHostingView`,已用户验收)的验收项,在 Electron 上逐条的 API 对应、成熟度与已知坑:

1. **点击穿透可动态切换**:`setIgnoreMouseEvents(true, {forward: true})` 的行为与限制(forward 在 mac 的事件类型覆盖、与 DevTools 的冲突、命中区域方案——CSS `-webkit-app-region`?mouseenter/leave 轮询?)。
2. **置顶稳定**:`setAlwaysOnTop(true, 'screen-saver')` 各 level 与 NSWindow.Level 的映射;与全屏 app 抢层级的已知问题。
3. **全空间与全屏辅助**:`setVisibleOnAllWorkspaces(true, {visibleOnFullScreen: true})` 对应 `collectionBehavior` 的哪些位;Spaces 切换时闪烁/丢层级的已知 issue。
4. **透明+无边框窗**:`transparent: true, frame: false` 的历史坑(阴影、圆角、GPU 合成、点击区域、resize)在近版 Electron 的现状。
5. **多显示器拖拽**与**睡眠恢复**:已知 issue 检索(GitHub electron/electron 仓库)。
6. 结论:给出「E1 冒烟 spike」应验证的清单(供 07 票执行)与「只能真机人工验收」的残余项;以及与 S1 对照的能力缺口表(若有)。

## Context

- S1 验收原文:`Spikes/S1PetOverlay/README.md`;路线图 S1 段:`docs/v1-roadmap.md`。
- ADR 0002 理由 2 称「窗口能力是同组 NSWindow 原语的本体,Electron 是其封装」——本票就是在检验这层封装漏了什么。
- 检索时以 2026-07 的近版 Electron(以 npm 上 latest 为准)为基线,老 issue 要确认是否仍开放。

## Output

`docs/research/electron-recon/pet-window.md`(中文,逐项给证据链接;GitHub issue 注明 open/closed 与最后活跃时间)。
