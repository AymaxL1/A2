# Snapshots —— 入库的快照 golden

本目录放**入库的期望产物(golden)**,是门禁断言的比对基准。它是**刻意进仓库**的(不是构建产物);
每轮门禁生成的实际产物落在 `.build/check/snapshots/`(已被 `.gitignore` 忽略),二者比对不通过即红。

## `menubar/` —— 菜单栏轻壳的菜单快照(14 票)

| 文件 | 对应状态 |
| --- | --- |
| `01-kernel-down.{png,txt}` | 内核未运行 |
| `02-kernel-running.{png,txt}` | 内核运行中(rule 模式 · 节点 HK-01 · 端口 7890 · 两个代理组) |
| `03-active-subscription.{png,txt}` | 有激活订阅(global 模式 · 两条订阅,激活「机场 A」) |

三种状态的定义在 `Sources/AAHostTestKit/MenuFixtures.swift`。它们同时是**纯逻辑「状态如实反映」断言**
喂的那三种状态 —— 即「图片画的」与「断言验的」物理上是同一批装置,不可能各说各话。

### `.png` 与 `.txt` 各是什么

* `.png` —— 由**渲染器 B**(`AAMenuModel → 自绘 NSView → PNG`,见
  `Sources/AAHostMacOS/MenuSnapshotRenderer.swift`)画出。像素尺寸由模型算出并显式定死
  （`NSBitmapImageRep` + `rep.size == 像素尺寸`，backing scale 恒为 1，与显示器缩放脱钩）。
* `.txt` —— 同一个模型的**确定性文本快照**(`AAMenuModel.textSnapshot`)。
  存在的理由:图片 diff 说不出「**哪一行**变了」,文本能。门禁两者都比,文本对不上时会把差异行直接打出来。

### ⚠️ 证明力边界(**别把绿灯读成「菜单在屏幕上长这样」**)

这些图证明的是:

* 菜单**模型**没有回归(标题 / 顺序 / 勾选 / 置灰 / 每项绑的能力 id 与参数);
* 真菜单(渲染器 A,`AAMenuModel → NSMenu`)与这些图(渲染器 B)吃的是**同一个模型** ——
  模型错了两边一起错。

它们**不证明** AppKit 把真 `NSMenu` 画成什么样。行高、字体、分隔线粗细、子菜单弹出行为、
深色模式配色……全部由系统绘制决定,而渲染器 B 只是另一种呈现(例如它把子菜单**缩进展开**,
真菜单是**弹出**的)。「菜单在屏幕上真的长这样」只能由人眼确认,门禁给不了这条结论。

## 什么时候需要重新录制

菜单文案 / 项顺序 / 能力清单一变,golden 必然全红 —— 那是**正确的红**(它就是来抓这个的)。
确认变化符合预期后,显式重录:

```bash
AA_SNAPSHOT_RECORD=1 \
AA_SNAPSHOT_OUT_DIR="$PWD/.build/check/snapshots" \
AA_SNAPSHOT_GOLDEN_DIR="$PWD/Snapshots/menubar" \
  .build/check/spm-testing/arm64-apple-macosx/debug/menu-snapshot
```

（可执行的确切路径以 `swift build --show-bin-path` 为准;门禁把它写在 `.build/check/spm-bin-path.txt`。）

录制模式**刻意以非零退出码结束**(rc=3),而且门禁自己**永远不传** `AA_SNAPSHOT_RECORD` ——
否则「红了就录一遍」会让这条断言永远为真,等于没有断言。

重录后 `git diff` 里应当只看到你预期的那几行变化:**先看 `.txt` 的 diff**(可读),
`.png` 的字节变化只是它的必然结果。
