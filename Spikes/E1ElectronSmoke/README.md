# E1 — Electron 本机最小闭环冒烟 spike（PROTOTYPE — 抛弃式，不进产品代码）

> 回答的票：`.scratch/electron-recon/issues/07-local-smoke-spike.md`。目的：在**白板机**（无 Node/npm/Homebrew）上实测「用户态装 Node → 装 Electron → 悬浮窗冒烟(E1a) → UDS 冒烟(E1b)」全链路能否走通，给裁决提供本机证据。`docs/research/electron-recon/pet-window.md` 不存在，人工验收清单按本票第 3 条自检项拟定（见下）。

## 结论一句话

**通过。** 从白板（无 Node）到两项冒烟全绿，实际操作耗时约 27 分钟（其中安装类命令合计约 70 秒，其余是调试一个自己代码里的 bug + 记录耗时）；全程未触碰 Xcode/CLT/sudo/Homebrew。

## 运行

```bash
# 1) 用户态装 Node（一次性；产物不入库，见下方“Node 安装”）
cd Spikes/E1ElectronSmoke
NODE_HOME=/path/to/node-v24.18.0-darwin-arm64 ./run.sh
```

`run.sh` 会：装 Electron（若 `node_modules/electron` 不存在）→ 后台启动 app → 2.5s 后采一次 `ps` RSS → 等 app 自行退出（硬上限 8s，spike 里实际约 3.5s）→ 打印 `run.log`（含自检 JSON）。

## 1. 用户态装 Node

- 代理 `http://127.0.0.1:33888` 已通过环境变量（`http_proxy`/`https_proxy`/`all_proxy`）生效，未额外加 `-x`。
- 下载 `https://nodejs.org/dist/v24.18.0/node-v24.18.0-darwin-arm64.tar.gz`（当前 LTS "Krypton"）到 scratchpad，解压，`export PATH`。
- **版本**：`node v24.18.0` / `npm 11.16.0`
- **耗时**：下载 50s（52MB）+ 解压 <1s ≈ **51s**
- 全程免 sudo，未装 Homebrew，未碰系统目录。

## 2. 装 Electron

- `cd Spikes/E1ElectronSmoke && npm install electron --no-audit --no-fund`（用户态 Node/npm，同一代理环境变量，未加任何 `ELECTRON_GET_USE_PROXY`/`ELECTRON_MIRROR` — **第一次就直接成功**，未触发那两条预案）。
- **版本**：`electron 33.4.11`（Chromium 130.0.6723.191 / 内置 Node 20.18.3）
- **耗时**：`npm install` 总计 **20s**（含 postinstall 脚本从 GitHub Releases 拉取的 Electron 预编译二进制，233MB 解包后的 `Electron.app`）
- **是否需要 CLT/Xcode**：**否**。`Electron.app` 是预编译好的 ad-hoc 签名 arm64 二进制（`codesign -dv` 显示 `flags=0x20002(adhoc,linker-signed)`），没有 `com.apple.quarantine` 属性（npm/curl 下载不打隔离标记），启动时**没有触发 Gatekeeper 弹窗**、无需用户确认。

### 坑 1：npm 11 的 `allow-scripts` 警告

`npm install` 打出：
```
npm warn allow-scripts 1 package has install scripts not yet covered by allowScripts:
npm warn allow-scripts   electron@33.4.11 (postinstall: node install.js)
```
这是 npm 11 内置的新特性（`lib/utils/allow-scripts-*.js`），不是本项目 `.npmrc` 配置出来的。**尽管有警告，postinstall 脚本照常执行**（`Electron.app` 确实落地、`electron --version` 正常输出），未被阻断。自动化流程里这条只是噪音，但如果将来 npm 把它改成默认阻断，需要显式 `npm approve-scripts` 或 `--foreground-scripts` 之类的开关，记一笔备查。

## 3. E1a — 悬浮窗冒烟（`Spikes/E1ElectronSmoke/main.js`）

`BrowserWindow{transparent:true, frame:false, alwaysOnTop:true, hasShadow:false}` + `setAlwaysOnTop(true,'screen-saver')` + `setVisibleOnAllWorkspaces(true,{visibleOnFullScreen:true})` + `setIgnoreMouseEvents(true,{forward:true})`，加载 `pet.html`（透明背景 + 一个 🐈 emoji），300ms 让合成器稳定后读回自检标志、`capturePage()` 存 PNG。**全程未打开 DevTools**（显式监听 `devtools-opened` 并强制关闭），**8 秒硬上限内自动 `app.quit()`**（实测约 3.5s 完成收尾）。

自检 JSON（实测输出，见 `run.log` / `selfcheck-result.json`）：

```json
{
  "isAlwaysOnTop": true,
  "isVisibleOnAllWorkspaces": true,
  "isVisible": true,
  "isFocused": false,
  "isResizable": false,
  "isFullScreenable": true,
  "hasShadow": false,
  "bounds": { "x": 1000, "y": 510, "width": 240, "height": 240 },
  "primaryDisplayWorkArea": { "width": 2240, "height": 1235 },
  "ignoreMouseEventsGetterAvailable": false
}
```

- **已知 API 缺口**：Electron 没有 `isIgnoreMouseEvents()` 这样的读回接口，`setIgnoreMouseEvents` 是 fire-and-forget，只能靠行为验证（见下方人工验收清单），程序化自检覆盖不到这一项。
- **截图存证**：`e1a-capture.png`（480×480，8-bit RGBA，因 Retina 2x 缩放）。用脚本手动解析 PNG chunk 校验：`colortype=6`（RGBA）；(2,2) 角像素在 `filter=0` 的行里读到 `[0,0,0,0]`，即**该点完全透明**，证明 `transparent:true` 在 `capturePage()` 里确实被保留（不是被合成成白/黑底）。
- `e1a.duration_ms`: **340ms**（含 300ms 的人为稳定等待）。

## 4. E1b — UDS 冒烟（同一 `main.js` 里，`node:net`）

Electron 主进程内 `net.createServer()` 监听 `/tmp/e1-electron-smoke-<pid>.sock`；`child_process.spawn(NODE_BIN, ['uds-client.js', socketPath])` 拉起一个**真正外部的 `node` 进程**（`process.env.NODE_BIN` 指向 scratchpad 里装的那个 Node，不是 Electron 内置 Node —— client 端打印 `isElectron:false` 自证）。客户端写一条 JSON、服务端 echo 回一条 JSON，退出时 `fs.unlinkSync` 清理 socket 文件。

实测结果（`e1b` 字段）：
```json
{
  "ok": true,
  "exit_code": 0,
  "roundtrip_ok": true,
  "server_reply_seen_by_client": {
    "pong": true,
    "server_pid": 22661,
    "server_is_electron_main": true,
    "received": { "hello": "from-external-node-client", "pid": 22665, "isElectron": false, ... }
  },
  "duration_ms": 33
}
```
Round-trip **33ms**。收尾后确认 `/tmp/e1-electron-smoke-*.sock` 已被删除（`ls` 无匹配）。

### 坑 2（本次唯一的真 bug，出在我自己写的 spike 代码里）

第一版 `uds-client.js` 只 `client.write(json)`，没调用 `.end()`。服务端逻辑是等 socket 的 `'end'` 事件（对端半关闭）才解析+回包——客户端不主动 `end()`，服务端永远收不到 `'end'`，两边死等，直到客户端自己的 5s 超时把连接摧毁。**这不是环境/网络问题**，是应用层逻辑 bug；独立写了一个不经 Electron 的最小复现脚本确认（纯 `node` 对 `node` 一样会卡死），定位后改成 `client.end(JSON.stringify(payload))`（写入的同时半关闭），立刻通。

### 坑 3（未完全查明，但有实测数据，值得记录给「8 秒硬上限」这条硬规则参考）

**第一次**跑通完整流程时（`npm install` 刚结束、`Electron.app` 和 scratchpad 里的 `node` 二进制都是第一次被执行），`e1b` 同样因为坑 2 的 bug 卡死超时，但**总耗时是 33.4 秒**，远超代码里设的 8 秒硬 quit 定时器（`setTimeout(finishAndQuit, 8000)`）——也就是说那次运行**违反了「8 秒内必须退出」的硬规则**，且 `quit_reason` 仍显示走的是正常完成分支而不是超时分支，说明当时进程内的 JS 定时器本身被顺延了，不是逻辑没生效。**同样的 bug**，在**第二次**运行（同一批二进制，只是不是首次执行）耗时降到 5.46 秒（精确对应客户端自己 5000ms 超时+开销），第三次（修完 bug）降到 3.48 秒。查了 `/usr/bin/log show`（`syspolicyd`）那段时间的日志，没看到明显的网络阻塞/长间隙证据，所以**没能 100% 坐实**是 Gatekeeper/AMFI 对「刚下载、从未执行过的二进制」做首次签名校验导致主线程阻塞，但"首次执行明显更慢、之后同一二进制变快"的模式很典型，先如实记下现象与怀疑，不下确定结论。

**对硬规则的实际影响**：如果生产代码真的需要「无论如何 8 秒内退出」这条不可违反的红线，**不能只在同一进程里用 JS `setTimeout` 兜底**——那次异常里主线程本身被顺延了，进程内定时器救不了自己。稳妥做法是加一个**进程外看门狗**（另起一个进程用 `setTimeout`+`SIGKILL`，不依赖被看护进程自己的事件循环）。这是本次 spike 意外挖到的、值得写进 04/裁决票的一条硬数据。

## 5. RSS 采样（`ps -axo pid,rss,comm`，app 存活期间采样一次；main.js 特意 hold 3s 供外部采样窗口）

| 进程 | RSS (KB) | RSS (MB, 约) |
|---|---:|---:|
| Electron（主进程） | 122,096 | 119.2 |
| Electron Helper (GPU) | 60,480 | 59.1 |
| Electron Helper（通用/utility） | 32,864 | 32.1 |
| Electron Helper (Renderer) | 78,432 | 76.6 |
| **合计（4 进程）** | **293,872** | **≈ 287** |

（`ps` 里混进一条 `/Applications/Figma.app/.../chrome_crashpad_handler`，与本 spike 无关，已从表里剔除；那是本机常驻的另一个 Electron 应用。）单窗口、单 UDS server 的最小场景下，4 个 Electron 相关进程合计常驻内存约 **287MB**，这是给 04 票内存预算的本机数据点。

## 6. 坑清单汇总

| # | 坑 | 结论/解法 |
|---|---|---|
| 1 | npm 11 `allow-scripts` 警告 | 噪音，postinstall 照跑，Electron 二进制正常落地 |
| 2 | UDS client 没调 `.end()` 导致死等 | 应用层 bug，改 `client.end(payload)` 立即修好 |
| 3 | 首次执行全新二进制耗时异常（33s vs 之后 3-5s） | 现象记录在案，未 100% 坐实成因，建议生产用进程外看门狗兜底硬超时 |
| — | 代理 | 环境变量已生效，npm install/Electron 二进制下载全程一次成功，未用到 `ELECTRON_GET_USE_PROXY`/`ELECTRON_MIRROR` 两条预案 |
| — | Gatekeeper/签名 | `Electron.app` ad-hoc 签名、无 quarantine 属性，启动无弹窗无阻断 |
| — | CLT/Xcode | 全程零依赖，`clang`/`xcodebuild`/`swiftc` 一次都没被调用 |

## 总耗时

从「Node 下载开始」到「E1a+E1b 全绿收尾」实测约 **27 分钟**，构成：
- Node 下载+解压：约 51s
- `npm install electron`（含二进制下载）：20s
- 首次整体跑通 + 定位坑 2/坑 3、加调试日志、独立复现脚本、改代码重跑 3 次：其余约 25 分钟（这部分是人工/agent 调试时间，不是"装机"耗时）

即：**纯安装类操作（Node+Electron）总计约 71 秒**；剩余时间花在发现并修复自己写的 UDS bug、以及记录一个耐人寻味的"首跑变慢"现象上。

## 复现步骤（从零开始）

```bash
# 1. 用户态装 Node（换成当前 LTS 版本号即可，见 https://nodejs.org/dist/index.json）
mkdir -p /path/to/scratch && cd /path/to/scratch
curl -sSL https://nodejs.org/dist/v24.18.0/node-v24.18.0-darwin-arm64.tar.gz -o node.tar.gz
tar -xzf node.tar.gz
export PATH="/path/to/scratch/node-v24.18.0-darwin-arm64/bin:$PATH"
node -v && npm -v

# 2. 装 Electron + 跑 spike
cd Spikes/E1ElectronSmoke
NODE_HOME="/path/to/scratch/node-v24.18.0-darwin-arm64" ./run.sh
```

产物：`run.log`（含自检 JSON）、`selfcheck-result.json`、`debug.log`（分阶段耗时打点）、`rss-sample.txt`、`e1a-capture.png`（入库，44KB）。`node_modules/` 已 `.gitignore`。

## 待用户真机人工验收清单

本 spike 是**无人值守的自动冒烟**（程序化自检 + 截图存证 + 8 秒自动退出），不构成完整交互验证。以下几项需要人真机盯着看（对照本票第 3 条自检项；`pet-window.md`/02 票产出的清单尚不存在，届时以那份为准）：

- [ ] **透明边缘**：肉眼看 `e1a-capture.png`（或真机跑起来时）宠物窗四周有无白底/黑底描边
- [ ] **置顶（screen-saver 档）**：真机上确认该窗口能盖过普通应用窗口、甚至其他应用的全屏窗口（`isAlwaysOnTop()` 读回 `true` 只证明标志位被接受，不代表实际窗口层级观感）
- [ ] **点击穿透（forward 模式）**：真机悬停/点击宠物位置，确认事件穿透到下层窗口/桌面——本 spike 全程设的是永久穿透（无交互窗口验证"开关"手感），且 Electron 无 API 可程序化读回这个标志，只能人工点
- [ ] **全空间 + 全屏辅助存留**：切 Space、进入另一个 app 的全屏模式，确认宠物窗仍然可见（`isVisibleOnAllWorkspaces`+`visibleOnFullScreen` 读回为 `true`，但实际跨 Space/全屏渲染表现未经真机验证）
- [ ] **拖拽 + 多显示器**：本 spike 未实现拖拽区域（`-webkit-app-region: drag` 未加，且窗口全程 `ignoreMouseEvents`），如果产品需要可拖拽宠物，需要另外补一个开关态的验证
- [ ] **睡眠恢复**：合盖唤醒后进程/窗口状态是否正常（本 spike 生命周期仅 3.5s，未覆盖睡眠场景）
