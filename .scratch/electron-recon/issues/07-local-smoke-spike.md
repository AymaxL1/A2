# 07 — 本机 Electron 冒烟 spike(E1)

Type: task
Status: open

## Question

(任务票:做,不是决定。)在本机实测 Electron 最小闭环,给明天的裁决提供本机证据:

1. **用户态装 Node**:官方 darwin-arm64 tarball 解压到 scratchpad(免 sudo、不动系统、不装 Homebrew),记录版本与耗时。
2. **装 Electron**:`npm init -y && npm install electron`(走本机代理),记录版本、下载耗时、是否需要任何 CLT/Xcode 介入。
3. **E1a 悬浮窗冒烟**(S1-mini):transparent+frameless+`setAlwaysOnTop(true,'screen-saver')`+`setVisibleOnAllWorkspaces(true,{visibleOnFullScreen:true})`+`setIgnoreMouseEvents(true,{forward:true})`;程序化自检各标志读回值、`capturePage` 存证 PNG、几秒后自动退出(用户不在,别留窗)。
4. **E1b UDS 冒烟**(S2-mini):同一 app 内 Node `net` 起 UDS server,外部 node 客户端 round-trip 一条 JSON,记录成功与 socket 清理。
5. **RSS 采样**:app 运行时 `ps -o rss` 各进程内存,记进报告(04 票的本机数据点)。
6. 所有坑(代理、缓存、electron 下载镜像、arm64 等)如实记录。

产物放 `Spikes/E1ElectronSmoke/`(main.js、package.json、run.sh、README.md 含结果与截图;`node_modules/`、Node tarball、截图外的大文件不入库——README 里写复现步骤即可)。真机视觉验收(点透手感、Spaces 行为)留给用户明天,README 里列出待人工验收清单(以 02 票产出的清单为准,02 未出时按本票第 3 条自检项)。

## Context

- 探针已确认:本机无任何 Node(白板)、网络经 127.0.0.1:33888 通 npm/GitHub、clang 健康(本票预期全程用不到)。
- S1 验收原文 `Spikes/S1PetOverlay/README.md`;worktree 内工作,别动主 checkout。

## Answer

(执行后由子代理填写)
