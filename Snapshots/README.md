# Snapshots —— 入库的快照 golden

本目录放**入库的期望产物(golden)**,是门禁断言的比对基准。它是**刻意进仓库**的(不是构建产物);
比对不通过即红。

## `a2-panel/` —— 菜单栏壳 `a2-panel` 的菜单快照(10 票)

| 文件 | 对应状态 |
| --- | --- |
| `01-mihomo-down.{png,txt}` | 已连内核,mihomo 未运行 |
| `02-mihomo-running.{png,txt}` | mihomo 运行中(rule 模式 · 节点 HK-01 · 端口 7890 · 两个代理组 · 系统代理已接管) |
| `03-active-subscription.{png,txt}` | 有激活订阅(global 模式 · 两条订阅,激活「机场 A」) |
| `04-disconnected.{png,txt}` | **与内核断连**(代理照跑 —— 新架构才有的一态) |

四种状态的定义在 `Sources/A2PanelFixtures/A2PanelFixtures.swift`。它们同时是**纯逻辑「状态如实反映」断言**
喂的那四种状态 —— 即「图片画的」与「断言验的」物理上是同一批装置,不可能各说各话。

**比对的判据住在 `swift test`**(`Tests/A2PanelSnapshotTests/`),不在任何 shell 脚本里 ——
这是 10 票门禁原子切换的一部分(新门禁口径明写「壳快照(swift test)」)。

### `.png` 与 `.txt` 各是什么

* `.png` —— 由**渲染器 B**(`A2MenuModel → 自绘 NSView → PNG`,见
  `Sources/A2PanelMacOS/A2MenuSnapshotRenderer.swift`)画出。像素尺寸由模型算出并显式定死
  (`NSBitmapImageRep` + `rep.size == 像素尺寸`,backing scale 恒为 1,与显示器缩放脱钩);
  色彩空间取设备无关的 `.calibratedRGB`(golden 是入库的,天然要跨机器比对)。
* `.txt` —— 同一个模型的**确定性文本快照**(`A2MenuModel.textSnapshot`)。
  存在的理由:图片 diff 说不出「**哪一行**变了」,文本能。门禁两者都比,文本对不上时会把差异行直接打出来。

### ⚠️ 证明力边界(**别把绿灯读成「菜单在屏幕上长这样」**)

这些图证明的是:

* 菜单**模型**没有回归(标题 / 顺序 / 勾选 / 置灰 / 每项绑的能力 id 与参数);
* 真菜单(渲染器 A,`A2MenuModel → NSMenu`)与这些图(渲染器 B)吃的是**同一个模型** ——
  模型错了两边一起错。

它们**不证明** AppKit 把真 `NSMenu` 画成什么样。行高、字体、分隔线粗细、子菜单弹出行为、
深色模式配色……全部由系统绘制决定,而渲染器 B 只是另一种呈现(例如它把子菜单**缩进展开**,
真菜单是**弹出**的)。「菜单在屏幕上真的长这样」只能由人眼确认,门禁给不了这条结论。

它们也**不证明**「菜单项绑的能力在真内核里存在」—— 装置里那份能力清单是**手写对照**的。
那条由旗舰 e2e 兜:`a2-panel-probe` 连上真内核后逐条核对(`PANEL_MANIFEST` / `PANEL_COVERAGE`)。

## 什么时候需要重新录制

菜单文案 / 项顺序 / 能力清单一变,golden 必然全红 —— 那是**正确的红**(它就是来抓这个的)。
确认变化符合预期后,显式重录:

```bash
AA_SNAPSHOT_RECORD=1 swift run a2-panel-snapshot
```

录制模式**刻意以非零退出码结束**(rc=3),而且门禁自己**永远不传** `AA_SNAPSHOT_RECORD` ——
否则「红了就录一遍」会让这条断言永远为真,等于没有断言。

重录后 `git diff` 里应当只看到你预期的那几行变化:**先看 `.txt` 的 diff**(可读),
`.png` 的字节变化只是它的必然结果。

## 历史:`menubar/`(14 票,已随旧壳退场)

14 票的 `menu-snapshot` 工具与 `Snapshots/menubar/` 属于旧宿主 `aahost` 的菜单栏轻壳。
10 票壳原子切换时,那套 golden 随 `AAUISystem` / `AAHostMacOS` 一并退场,由上面的 `a2-panel/` 接替
(「一个模型,两个渲染器」的结构与证明力边界**原封平移**,只换喂养源:
宿主进程内的注册表 → 内核事件流的投影)。
