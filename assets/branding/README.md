# 品牌资产(assets/branding/)

本目录是 a2 品牌资产的**唯一落点**。现状(19 票起):用户从 8 张概念稿里选定 **v3「A²」**,
据其**程序化重绘**的成品已落地并接线 —— `A2 Panel.app` 有 icon(`CFBundleIconFile = AppIcon`),
菜单栏是 template 图标(接管中另加一个「●」;取不到资源时回落文字「A2」)。

## 成品清单(19 票,全部由 `Scripts/gen-app-icon.swift` 生成)

| 文件 | 是什么 | 谁在用 |
|---|---|---|
| `a2-icon-master-terracotta-1024.png` | **主选**母版:陶土橙底 + 米白 A² | 人眼抽查;iconset 的 1024 档与它逐字节相同 |
| `a2-icon-master-black-1024.png` | 备选母版:近黑底 + 米白 A² | **只存不接线**(留给深色场景/周边物料) |
| `AppIcon.iconset/`(十档) | 16/32/128/256/512 各 @1x@2x,**每档原生重画**(不是缩图) | `iconutil` 的输入;入库以便看见漂移 |
| `AppIcon.icns` | 由上面十档打出来 | `build-app.sh` → `Contents/Resources/`(APP12) |
| `a2-menubar-template.png` / `@2x.png` | 菜单栏 template,18×18pt,**纯黑 + alpha、透明底** | 壳的 `A2MenuBarIcon`(APP13) |

**重跑与复核**:`swift Scripts/gen-app-icon.swift` 重新生成;`--verify` 重跑到临时目录并与入库
产物**逐字节**比对(本机实测 15 个产物全同,含 `.icns`)。**逐字节只在同机同系统下承诺** ——
换机器 / 系统升级后 SF Pro 可能变字形,那时 `--verify` 会红,正确动作是重跑 + 看图 + 重录产物,
**不是**放宽判据(完整口径见脚本头「可复现判据」一节)。设计常量、色值出处、字体选型的对账过程
全写在那个脚本的文件头。门禁里另有一层便宜的守卫:`Tests/A2PanelSnapshotTests/A2BrandAssetTests.swift`
直接量入库产物的网格 / 圆角 / 色值 / 字形比例 / 十档 / template 纯黑 —— 改了常量忘了重跑,它当场红。

### 设计参数(改这些 = 改设计)

* **网格**:1024 画布,824×824 圆角方居中(Big Sur),四周 100px 是**留给系统投影的余量**——
  素材里**不画投影**(Dock / Finder / 打开面板的投影各不相同,画死了到处对不上)。
* **圆角半径 184**(= 824 × 0.2233,HIG 模板比例 ≈0.2237 取整)。
* **色值**(取自 v3 小样):陶土橙 `#C36446`、米白 `#FDF9F1`、近黑 `#242424`。
* **字形**:`.SFNS-Black`(SF Pro 的 Black 字重,经 CoreText 取轮廓路径填充)。
* **比例**(量自 v3 右下角那两个圆角方小样):A 的 cap 高 = 方边 × 0.470;上标 2 高 = A 高 × 0.315;
  2 的**顶与 A 的顶齐平**;2 的左边缘内嵌进 A 右边缘 0.180 × A 宽;记号在方内上下左右居中。
* **菜单栏 template 的记号高 = 画布边长 × 0.72**(`templateCapRatio`)——**唯一一条不照小样的比例**:
  小样里 A 只占方的 47%,那是因为它外面有一个实心圆角方托着;菜单栏图标没有底,再留那么多空白
  就只剩一个看不清的小记号。理由与取值写在 `Scripts/gen-app-icon.swift` 的 `Design.templateCapRatio` 注释里。

## 品牌沿革(为什么这些文件叫 Aymax)

三代命名,后一代作废前一代:

1. **Aymax 期**(概念期):产品设想名「Aymax / Aymax Assistant / Aymax Tool」,本目录的
   8 张概念稿全部产于此期(原在 `feature/brand` 分支,提交语明写「刻意不进 main」)。
2. **AA 期**:仓名 PROJECT_AA、bundle id `com.aa.host` 等(已全面退场,见 build-app.sh 头注)。
3. **a2 命名系**(现行,spec 命名节钉死):bin `a2`、`~/.a2`、unit `com.a2.*`、
   壳「A2 Panel」(`com.a2.panel`)。2026-08-11 用户裁定把概念稿收回 main,作废「刻意不进」旧口径。

## 概念稿清单(concepts/,均为 AI 生成的选型草图,非矢量)

| 稿 | 内容 | 与现名的关系 |
|---|---|---|
| v1 | 双 A 组字,三角硬朗,负形星芒;落款「Aymax 助手 / PROJECT_AA」 | AA 期遗产 |
| v2 | 双 A 组字圆润版(anthropic 风),负形星芒;「Aymax Assistant」 | AA 期遗产 |
| **v3** | **A²(A 加上标 2)**,黑/陶土橙两版圆角方图标小样;「A² AYMAX」 | **与现名 a2 逐字吻合,天然候选** |
| v4 | A + 上标锤形(hammer-at);「Aymax Tool」 | 工具系 |
| v5 | A + 上标锤(superscript-hammer 变体) | 工具系 |
| v6 | A + 上标 T 形抽象锤;「Aymax Tool」 | 工具系 |
| v7 | A + 羊角锤(claw) | 工具系 |
| v8 | A + 前倾写实羊角锤;「Aymax Tool」 | 工具系 |

## 图标落地待办(19 票收口)

1. ~~**选稿**(人裁)~~ —— 用户选定 **v3「A²」**;落款「AYMAX」不进成品(成品里只有记号,没有字标)。
2. ~~**出母版**~~ —— 程序化重绘(CoreGraphics/CoreText),陶土橙主选 + 近黑备选,外加菜单栏 template 版。
   ⚠️ **口径纠正**:此处原文写「macOS 圆角方,系统自己裁圆角,素材给直角」——**这是错的**。
   **macOS 不代裁圆角:圆角方必须画进素材里**(所以本目录的母版四角是透明的,圆角是画出来的)。
   「系统按 mask 裁圆角、素材给直角」那是 **iOS**(以及 iPadOS / watchOS)的规矩,两个平台别搞混。
3. ~~**生成 iconset**~~ —— 十档齐 + `iconutil -c icns`,产物入库。
4. ~~**接线**~~ —— `build-app.sh` 拷入 `Contents/Resources/` + `CFBundleIconFile`(新增 APP12/APP13);
   `A2MenuBarController` 换 template 图标。**菜单快照零漂移**(实测):状态栏那一格不进 `A2MenuModel`,
   `Snapshots/a2-panel/` 一张都不用重录 —— 原文预判的「快照全部重录」没有发生。
5. 提醒(仍然有效):换图标不改 bundle id,TCC 无代价;但 ad-hoc 下每次重出包 cdhash 都变(既有记账,
   见 `docs/runbooks/signing-and-authorization.md` §2.1),与图标无关但常被混为一谈。

## 人工项(门禁给不了这条结论)

* **在 Finder 里实看这张图标**:`bash Scripts/build-app.sh` 出包 → 在 `.build/app/` 里对着
  `A2 Panel.app` 看图标、Cmd-I 看「显示简介」、切浅色/深色外观各看一次。
  ⚠️ **LSUIElement 的壳没有 Dock 图标**,所以实看的场合是 Finder / 「打开」面板 / 「强制退出」列表,
  **不是** Dock。另:macOS 的图标缓存会骗人 —— 换了图标却没变,先把包挪个位置或改个名再看。
* **菜单栏实看**:跑起来看那一格在浅色/深色菜单栏下是不是自动变色(`isTemplate` 的意义),
  以及接管代理时「图标 + ●」并排的样子。@1x(非 Retina 外接屏)下上标 2 只有 4px,会糊成一个点 ——
  已知,记号在那个尺寸下靠「A」认。

改名代价三层(只改显示名便宜 / 改 bundle id 重置授权 / 改 a2 命名系是迁移票)另见
`docs/runbooks/distribution.md` 与 ADR 0012——图标选型不阻塞、也不被阻塞于改名裁定。
