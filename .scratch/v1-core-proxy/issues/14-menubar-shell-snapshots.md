# 14 — 菜单栏轻壳 + 快照测试

**What to build:** ClashX Meta 式菜单栏轻壳成品:开关系统代理、模式切换、按组选节点、订阅管理入口、延迟测速、基础状态展示——全部动作走注册表能力(GUI 与 CLI 同源,薄壳无私有逻辑)。视图层接入快照测试:菜单各状态渲染为可 diff 图片,产物图片供用户抽查(不读 Swift 也能行使监督)。

**Blocked by:** 09, 12(快照测试依赖 SPM 生态,须 11 之后)

**Status:** done(门禁 PASS=423 FAIL=0 rc=0,连跑三轮全绿;**菜单在屏幕上长什么样未经人眼确认**,见下)

**验证环:** 票面原文写「需 Xcode」——**已作废**。本票全程没碰 Xcode(本机也没装)。
快照不用 XCUITest、不引第三方 snapshot 包,而是手搓:纯模型 → 自绘 NSView → `NSBitmapImageRep` → PNG。
理由与代价见下面「设计」与「证明力边界」两节。

---

## 设计:一个模型,两个渲染器

`NSMenu` 本身几乎无法离屏截图 —— 它由系统在自己的绘制路径里画,没有可靠的截图入口。
「菜单快照」若直接对着 NSMenu 做,就只能做成「起 GUI、人肉点开、手工截屏」,永远进不了 headless 门禁。

所以本票先把菜单拆成一份**纯数据**,再由两个渲染器分别消费:

| 层 | 落点 | 说明 |
|---|---|---|
| 模型(纯数据) | `Sources/AAUISystem/AAMenuModel.swift` | `AAMenuModel` / `AAMenuItemModel` / `AAMenuUserAction` / `AAMenuPrompt`。零 AppKit。 |
| 构造器(纯函数) | `Sources/AAUISystem/AAMenuModelBuilder.swift` | 输入 = **能力清单 + 状态**,输出 = 模型。不碰 AppKit、不发 UDS、不做 I/O。 |
| 渲染器 A | `Sources/AAHostMacOS/MenuBarController.swift` | `AAMenuModel → NSMenu`。真正挂到状态栏上那份 + 动作路由 + `menuWillOpen` 刷新。 |
| 渲染器 B | `Sources/AAHostMacOS/MenuSnapshotRenderer.swift` | `AAMenuModel → PNG`。门禁里可 diff 的那份(自绘 NSView)。 |

**两个渲染器吃同一个模型** —— 模型错了两边一起错,快照因此抓得住模型层的回归。

`AAUISystem` 必须零 AppKit:`PluginProxy` 依赖它,一旦这里 import AppKit,AppKit 就被拖进插件域,
破坏「插件是纯逻辑」的边界。所以两个渲染器都住在 `AAHostMacOS`。

### 薄壳铁律怎么落地的

每个可点菜单项的 action 都是**同一个方法** `AAMenuBarController.menuItemActivated(_:)`,它只做三步:
① 从 `sender.representedObject` 取回该项的 `AAMenuItemModel`(里面写着 capabilityID + params);
② 若该项声明了 `prompts`(参数只能当场问用户,如换源的 name/source),弹输入框收齐;
③ 调 `registry.invoke(capabilityID:input:)`。

**没有第四步。** 菜单项里没有任何「这个要不要确认」的判断 —— 风险分级与确认路由是 `Registry.invoke` 的职责。
`proxy.subscription.add`(dangerous)从菜单点下去,与 `aa proxy subscription add` 物理上走同一条路由。

### 实时反映靠 delegate,不靠定时器

`NSMenuDelegate.menuWillOpen` → 重取状态(经三条 safe 能力 `proxy.status` / `proxy.groups.list` /
`proxy.subscription.list`)→ 重建模型 → 重建菜单项。菜单没打开时一次调用都不发。

---

## 逐条验收状态

原票面四条照原文记账,并把**验到了什么强度**逐条写清;另外单列一条原票面没写、但必须记账的:
「菜单在屏幕上真的长这样」—— 那条**没做到,不打勾**。

- [x] **菜单覆盖 04 票 in 清单的全部用户操作,每个动作可追溯到对应能力调用** —— 门禁 MB1 每轮真验
  - 04 票 In 清单六项(`.scratch/v1-mac-recharter/issues/04-proxy-plugin-v1-scope.md`)转写成机读枚举
    `AAMenuUserAction`:系统代理开关 / 模式切换 / 按代理组选节点 / 订阅管理 / 延迟测速 / 基础状态。
    菜单模型每一项都要**认领**其中一项,门禁断言六项**逐项**有菜单项(实测 `actions=6/6`)。
  - **可追溯性不是自证**:判据是拿**真注册表**(`Registry.demoCapabilities + ProxyPlugin.capabilities()`,
    Port 换假件,与宿主 `applicationDidFinishLaunching` 同样装配)的 `describe()` 去核对每个绑定项。
    实测 43 个绑定项全部命中。
  - **反向核对**(防「能力加了、菜单忘了露出来」):注册表里每一条 `proxy.*` 的 normal/dangerous 能力
    都必须出现在菜单里。名单不是抄的,是从真注册表现算的。实测 7 条全部露出:
    `system.enable` / `system.disable` / `mode.set` / `node.select` / `subscription.activate` /
    `subscription.update` / `subscription.add`。
  - **参数也验**:27 个可点项的入参被真的送进 `Registry.invoke` 走一遍集中校验,不得报
    `missing_parameter` / `type_mismatch` / `invalid_params`。这条抓的是「菜单造了个参数形状不对的调用」。
  - ⚠️ **诚实口径**:`AAMenuUserAction` 这六个分类是**人工转写**自 04 票那段散文(那票里它就是一行中文句子,
    没有机读形态)。门禁能验「六个分类各有菜单项、且都落到真实能力」,**验不了**「这六个分类忠实等于
    04 票作者心里那六件事」—— 那一步是人读票面确认的。

- [x] **状态变化(内核死活/模式/节点/激活订阅)在菜单实时反映** —— 门禁 MB2 每轮真验(**模型层**)
  - 判据是纯逻辑:同一个构造器喂三种状态,断言吐出三种不同模型(且三态两两不同,排除「模型恒定」的假绿)。
    - 内核死:显示「内核:未运行」;模式项全部置灰;「开启系统代理」置灰(接管会指向死端口),
      而「关闭系统代理」**仍可点**(内核死了才更需要还原 —— 08 票守的那条线);代理组区块如实说明不可用。
    - 内核活 + rule + 节点 HK-01:显示「内核:运行中 v1.19.28」与「模式:规则 · 节点:HK-01 · 端口:7890」;
      「模式:规则」被勾选、其余未勾选;PROXY 组里 HK-01 被勾选、JP-02 未勾选;每组带一个可点的「测速本组」。
    - 有激活订阅:「机场 A」勾选、「机场 B」未勾选;「更新订阅」分组下每条订阅各有一项、参数指向各自 id;模式勾选跟着状态走。
  - ⚠️ **「实时」这个词只验到了一半**:纯逻辑证明的是「**状态一变,模型就变**」。
    「宿主真的会在菜单打开时去重取状态」这一步由 `menuWillOpen → rebuild()` 承担(不用轮询定时器),
    门禁只经 MB5 那条 E2E **间接**触达它(探针调的 `simulateMenuClick` 先跑一次同一条 `rebuild()` 路径)。
    **没有**「打开菜单 → 看见内容变了」的端到端证据 —— 那需要人眼。

- [x] **快照覆盖主要菜单状态,产物图片路径固定、进 check.sh 门禁** —— 门禁 MB3/MB4 每轮真验
  - 三种状态(定义在 `Sources/AAHostTestKit/MenuFixtures.swift`,与 MB2 喂的是**同一批装置** ——
    即「图片画的」与「断言验的」物理上同源,不可能各说各话):
    `01-kernel-down`(460×404)/ `02-kernel-running`(460×576)/ `03-active-subscription`(460×501)。
  - 产物落 `.build/check/snapshots/<name>.png`(gitignored),门禁**打印绝对路径**供人眼抽查;
    golden 入库 `Snapshots/menubar/`(含 `Snapshots/README.md`:说明、重录流程、证明力边界)。
  - 图上每一行右侧带**能力 id 角标** —— 不读 Swift 的人也能一眼核对「这一项到底调哪个能力」。
    这是本票「产物图片供用户抽查」的核心用途,不是装饰。
  - MB3 的尺寸期望**不在 shell 里写死**:工具按模型算出并打成 `SNAPSHOT_EXPECT` 行,shell **独立地**
    去解 PNG 文件自己的 IHDR 头来比 —— 一边是模型算的、一边是文件里真写着的,才叫核验。
    另有下限守卫:枚举到的图少于 3 张直接 FAIL(枚举坏了时「没发现不一致」毫无意义)。

- [x] **dangerous 操作(换源)从菜单发起同样弹宿主确认(与 CLI 同一路由)** —— 门禁 MB5 每轮真验
  - headless 下怎么「点菜单」:test-only seam `AA_MENU_CLICK_PROBE=<能力id>` 让宿主启动后经
    `NSApp.sendAction` 激活**真 NSMenuItem** 的 action —— 不是直接调 `registry.invoke`(那证明不了菜单接对了线)。
    `AA_MENU_PROMPT_AUTO` 替掉「换源要填 name/source」的模态输入框。二者都受 `#if AA_TESTING` 门控。
  - 判据五条并列:激活到菜单项 → capabilityID 是 `proxy.subscription.add` → 触发确认层(`[confirm] …`)
    → 走 deny 分支 → 菜单侧收到 `code=denied`;**外加**订阅目录零产物(deny 真的挡住了 handler,没留痕)。

- [ ] **(未验,不打勾)菜单在屏幕上真的长这样 / 点得动**
  - 「点开状态栏图标 → 菜单画出来 → 项可点 → 子菜单弹出 → 勾选看得见 → 输入框弹出 → 确认框弹出」
    这一整段**没有人肉点过**,也没有任何自动化覆盖。
  - 现有证据只到:菜单项被构造并挂进 NSMenu(代码可读)、`NSApp.sendAction` 能派发到 action 并跑通全链
    (MB5 真验)、模型内容正确(MB1/MB2 真验)、渲染器 B 的图与 golden 一致(MB3/MB4 真验)。
    **这些都不等于「用户看得见、点得动」。**
  - 本机无 Xcode → 无 XCUITest;`osascript` 查窗口会触发 TCC 自动化授权弹窗并挂死(12 票实测过)。
    这条与 15 票的关于窗口是同一个缺口,归 13 票的授权面 / 人肉点验。

---

## 快照方案的证明力边界(**最重要的一节,别跳过**)

**证明:**

1. 菜单**模型**本身没有回归 —— 标题、顺序、勾选、置灰、每一项绑的能力 id 与参数,逐像素/逐字节钉死。
2. 真菜单(渲染器 A)与这些图(渲染器 B)吃的是**同一个 `AAMenuModel`** —— 模型错了两边一起错。
3. 三种主要状态确实产出三份不同的模型(状态→模型这条函数是活的,不是恒定输出)。

**不证明:**

1. **AppKit 把真 `NSMenu` 画成什么样。** 行高、字体、分隔线粗细、子菜单箭头、高亮态、深浅色配色……
   全部由系统绘制决定;渲染器 B 只是**另一种**呈现,与真菜单像素上毫无关系。
   最一眼可见的形态差异:真菜单的子菜单是**弹出**的,渲染器 B 把它画成**缩进展开**。
2. **「用户看得见」。** 见上面那条没打勾的验收。
3. **鼠标点击真的会到达 action。** MB5 覆盖的是 `NSApp.sendAction`(AppKit 的真派发),
   但「鼠标事件 → AppKit 派发」这一段仍未覆盖。

这段口径同时写在三处、措辞一致:`Sources/AAUISystem/AAMenuModel.swift` 头、
`Sources/AAHostMacOS/MenuSnapshotRenderer.swift` 头、`Snapshots/README.md`。

---

## 改动清单

| 文件 | 改了什么 |
|---|---|
| `Sources/AAUISystem/AAMenuModel.swift`(新) | 纯数据模型:`AAMenuModel` / `AAMenuItemModel` / `AAMenuUserAction`(04 票 In 清单的机读表示)/ `AAMenuPrompt`;`rows`(深度优先展平)与 `textSnapshot`(确定性文本快照)。 |
| `Sources/AAUISystem/AAMenuModelBuilder.swift`(新) | `AAProxyUIState`(状态快照 + 从三条 safe 能力输出解码的纯函数)与 `AAMenuModelBuilder.build(capabilities:state:)`。只为**清单里真实存在**的能力造项;模式取值域读 `mode` 参数的 `allowedValues`,不另抄一份。 |
| `Sources/AAHostMacOS/MenuBarController.swift`(新) | 渲染器 A(`AAMenuRenderer`)+ `AAMenuBarController`:`menuWillOpen` 刷新、动作唯一出口、输入框、`simulateMenuClick` 探针。 |
| `Sources/AAHostMacOS/MenuSnapshotRenderer.swift`(新) | 渲染器 B:定死像素尺寸的 `AAMenuModel → PNG`,自绘 NSView,配色写死 sRGB。 |
| `Sources/AAHostMacOS/HostApp.swift` | `setupStatusItem()` 从「只读能力清单」换成轻壳菜单(关于页那一项原样复用 15 票的);新增两个 `#if AA_TESTING` seam(`AA_MENU_PROMPT_AUTO` / `AA_MENU_CLICK_PROBE`);`AppDelegate` 持有 `menuBarController`。 |
| `Sources/AAHostTestKit/MenuFixtures.swift`(新) | 三种状态的固定装置 + `realRegistry()`(与宿主同样装配的真注册表,Port 换假件)。快照与纯逻辑断言共用。 |
| `Sources/AAHostTestKit/MenuModelConformanceTests.swift`(新) | 33 条纯逻辑 check,汇成 `MENUBAR_ASSERT1/2` 两行机读结论(门禁 MB1/MB2 只 grep 这两行)。 |
| `Sources/AAHostTestKit/AAHostTestKit.swift` | `TestReport` 加 `note(_:)`:追加**非断言**输出行(结论行),不计入 passed/failed。 |
| `Sources/menu-snapshot/MenuSnapshotMain.swift`(新) | 快照工具:渲染 → 落产物 → 比 golden(像素 + 文本)。`AA_SNAPSHOT_RECORD=1` 显式重录(且以 rc=3 结束)。刻意不叫 `main.swift`(顶层代码是 nonisolated,碰不了 `@MainActor` 的渲染器)。 |
| `Sources/registry-tests/main.swift` | 挂上 `MenuModelConformanceTests`,加 `MENUMODEL_TESTS` 汇总行并计入 `ALL_UNIT`。 |
| `Package.swift` | `AAHostMacOS` / `AAHostTestKit` 显式补 `AAUISystem` 依赖;新增 `menu-snapshot` executableTarget(**刻意不进 products**,与 `registry-tests` 同性质)。 |
| `Scripts/check/menubar.sh`(新) | 断言组 MB,恰好 5 条,任何失败路径下条数不变。 |
| `Scripts/check.sh` | 在 `app-bundle.sh` 之后、`mihomo-real-e2e.sh` 之前 source 它。 |
| `Scripts/check/unit-and-domain.sh` | 加 `UNIT_OUT="$OUT"` 别名(`$OUT` 后面会被各 E2E 组覆盖,而 MB 组还要读那份纯逻辑输出;不为它重跑 runner)。 |
| `Scripts/check/bootstrap.sh` | 补 14 票增量说明。 |
| `Scripts/check/build.sh` | 补一句:14 票的两个新 seam 也收在 HostApp.swift 里,故「整包带 `-DAA_TESTING` 是空操作」这条等价性继续成立。 |
| `Snapshots/menubar/*.{png,txt}`(新,**刻意入库**) | golden(3 张 PNG + 3 份文本)。 |
| `Snapshots/README.md`(新) | golden 说明、重录流程、证明力边界。 |

---

## 实测记录

**环境**:本机无 Xcode;Swift 6.1.2 独立工具链(`~/Library/Developer/Toolchains/swift-latest.xctoolchain`);
门禁 `bash Scripts/check.sh`。

### 1. 快照稳定性(**硬要求,连跑三轮**)

**结论:完全稳定,没有降级。** 三轮门禁的 `SNAPSHOT_DIFF` 逐张都是 `diffPixels=0`
(不是「在容差内」,是**一个差异像素都没有**),`textEqual=yes`。
另在写门禁之前先做过一次专项验证:连续两次渲染到不同目录,三张 PNG 的 SHA-256 **两两逐字节相同**。

因此**不降级**,像素 diff 保留为 MB4 的主判据。

**为什么它稳**(不是运气):

- 像素尺寸**显式定死**,不用 `bitmapImageRepForCachingDisplay`。后者给的是 backing store 像素:
  请求 240×80 在 Retina 上实际出 480×160,换显示器/换缩放档就又是另一个数 —— 像素断言当场红。
  正确做法:显式 `NSBitmapImageRep(bitmapDataPlanes:pixelsWide:pixelsHigh:…)` →
  `rep.size = NSSize(width: w, height: h)`(**1 point = 1 pixel**,backing scale 钉死为 1)→
  `NSGraphicsContext(bitmapImageRep:)` → `view.displayIgnoringOpacity(_:in:)` → `representation(using: .png)`。
- 配色**一律写死 sRGB**,不用 `.labelColor` 之类语义色 —— 语义色跟随系统深浅外观,
  门禁跑在什么外观下不由我们决定,用了它快照会随用户切深色模式而抖(最典型的偶发红来源)。
- 版面常量全是整数像素,避免半像素落在不同行上导致的抗锯齿抖动。

**阈值与理由**(`Sources/menu-snapshot/MenuSnapshotMain.swift`):单通道容差 **2/255**,
超容差像素**允许 0 个**。为什么是 2 而不是 0:0 会把任何一次 CoreGraphics 内部舍入变化都判成回归,
而那不是本断言要抓的东西;为什么不能更大:菜单渲染是纯文字 + 直线,任何真实回归(文案变了、勾选没了、
少一项、置灰了)都表现为整块像素在背景色(255)与前景色(≈33)之间跳,单通道差值上百 —— 与 2 差两个数量级。
也就是说 **2 吸收不了任何真回归,也不给「调大阈值蒙混过去」留空间**。
实测差异恒为 0,这个容差目前一次都没被用上。

**如果将来它开始抖**:正确做法是降级成「产物存在性 + 尺寸 + 模型文本 golden」并在票面写明,
**不是**把容差调大。文本 golden(`.txt`)已经入库、门禁已经在比,降级落点是现成的。

### 2. 三轮门禁数字

| 轮次 | PASS | FAIL | rc | 耗时 | 外部 mihomo 守卫那一行(原文) |
|---|---|---|---|---|---|
| 1 | 423 | 0 | 0 | 120s | `PASS: 未触碰仓库外的 mihomo 进程(跑前后一致: [553 ])` |
| 2 | 423 | 0 | 0 | 114s | `PASS: 未触碰仓库外的 mihomo 进程(跑前后一致: [553 ])` |
| 3 | 423 | 0 | 0 | 115s | `PASS: 未触碰仓库外的 mihomo 进程(跑前后一致: [553 ])` |

418(14 票之前的基线)+ 5(断言组 MB)= **423**,与预期完全一致,没有偏差需要解释。

用户自己的 `/usr/local/bin/mihomo`(pid 553)**自始至终没动过**:本票全程只按仓库树内绝对路径
`pkill/pgrep`,一次都没用过裸名字 `mihomo`;MB 组**不起任何内核**(不配 `AA_MIHOMO_KERNEL_PATH`),
也从不调真 `networksetup`(`AA_NETWORKSETUP_FAKE_STATE` 指向 `$BUILD` 下的文件后端假件)。

### 3. dangerous 菜单路径的真实宿主日志(MB5 的被测面)

```
[AAHost] 菜单输入模式: AA_MENU_PROMPT_AUTO(test-only 自动填入,不弹输入框)name=… source=…
[AAHost] dangerous 确认模式: AA_CONFIRM_AUTO=deny(test-only 自动拒绝,不弹窗)
[AAHost] 菜单点击探针: AA_MENU_CLICK_PROBE=proxy.subscription.add(test-only)
[AAHost] [menu-probe] 激活菜单项「添加 / 替换订阅源…」→ capabilityID=proxy.subscription.add
[AAHost] [menu] 发起能力调用 [proxy.subscription.add] name=… source=…
[AAHost] [confirm] proxy.subscription.add name=… source=…
[AAHost] AA_CONFIRM_AUTO=deny → 自动拒绝(test-only,不弹窗)[proxy.subscription.add]
[AAHost] [menu] 能力调用结果 [proxy.subscription.add]: failed code=denied detail=dangerous 能力被拒:宿主确认未通过 proxy.subscription.add
```

订阅目录(`$BUILD/menubar-e2e/subs`)跑完**根本不存在** —— deny 分支连 handler 都没进,零痕迹。

### 4. 模型文本快照长什么样(`Snapshots/menubar/01-kernel-down.txt`,节选)

```
[header disabled] AA · 代理
[separator]
[info disabled] 内核:未运行  → proxy.status  @basicStatus
[separator]
[action disabled] 开启系统代理  → proxy.system.enable  @systemProxyToggle  (内核未运行,接管后会指向死端口)
[action enabled] 关闭系统代理(还原)  → proxy.system.disable  @systemProxyToggle
[separator]
[action disabled] 模式:规则  → proxy.mode.set {mode=rule}  @modeSwitch  (内核未运行)
…
[action enabled] 添加 / 替换订阅源…  → proxy.subscription.add prompts[name,source]  @subscriptionManage
```

图片 diff 说不出「哪一行变了」,文本能 —— 这就是同时留一份文本 golden 的理由(门禁两者都比,
文本对不上时把差异行直接打出来)。

### 5. 设计里没预料到的两处

1. **`menu-snapshot` 不能用 `main.swift`。** 顶层代码是 nonisolated 上下文,而渲染器 B 是 `@MainActor`
   (它要碰 NSView),直接调用编译报错;`MainActor.assumeIsolated` 的可用性又高于本包的 macOS 13 底线。
   最后按 `Sources/aahost/AAHostMain.swift` 的既有先例改成 `@main @MainActor struct` + 非 `main.swift` 文件名。
2. **`$OUT` 在门禁里是被反复覆盖的临时变量。** MB1/MB2 要读断言组 1 的 runner 输出,而那时 `$OUT`
   早被后面的 E2E 组换掉了。加了一个 `UNIT_OUT` 别名(一行),避免为两条 grep 重跑一遍十几秒的 runner。

---

## 双轴 CR 后所改(记在这里,因为其中两条是「本机看不出来」的那类)

1. **快照位图的色彩空间从 `.deviceRGB` 改成设备无关的 `.calibratedRGB`。**
   `.deviceRGB` 跟着机器/显示器的色彩描述文件走。同机上「连渲两次字节一致」照样成立 ——
   所以本机怎么测都测不出问题;但 golden 是**入库**的,天生要跨机器比对。换台机器或换份显示
   描述文件,同样的颜色值会落成不同像素,像素 diff 可能直接越过 2/255 容差。那种红最坏:
   看起来像回归,查半天发现是显示器。golden 已按新色彩空间重录。

2. **渲染器 A 的 `.group` 分支不再硬编码 `isEnabled = true`,改为尊重模型的 `enabled`/`checked`。**
   今天 builder 从不产 disabled 分组,所以写死也「碰巧对」—— 但那是在「两个渲染器同吃一个模型」
   这条不变式上留了道分叉,而**快照恰恰抓不到它**(快照比的是渲染器 B 的输出,A 的偏差它看不见)。
   不变式要靠两边都老实,不能靠碰巧。

3. **订阅「手动更新」此前被悄悄收窄了,已补回。** V1 In 清单(`v1-mac-recharter/issues/04-proxy-plugin-v1-scope.md`)
   写的是「订阅管理(可存多个、同一时刻激活一个 profile、**手动更新**)」,没有限定只能更新激活项,
   而 `proxy.subscription.update` 本身就按 id 收参。原先只给了「更新当前订阅」一项 = 把 In 清单收窄,
   且票面没记这次收窄。现改为「更新订阅」分组,每条订阅一个子项;一条都没有时整组禁用并说明原因。

4. **输入框标签用能力描述里的中文,不再用参数名。** 原先弹给用户的标签是 `name` / `source` 这种
   内部标识符,等于把机器用的命名泄给人看。

## 未做 / 已知缺口(如实)

1. **「菜单在屏幕上长这样」没人眼确认过**(上面已单列一条不打勾的验收)。这是本票最大的缺口。
2. **系统代理的勾选态做不出来 —— 因为没有只读能力面。**
   「系统代理当前是否已被本应用接管」在 V1 **没有任何 safe 能力暴露**(`proxy.status` 不报它,
   接管态只活在宿主私有的持久化文件里)。菜单因此**不显示勾选态**,只并列给出「开启 / 关闭」两项。
   **绝不让 GUI 私自去读那个持久化文件来猜** —— 那正是薄壳铁律禁止的私有逻辑。
   要做勾选态就得新增一条 safe 能力,那是能力面变更,不在 14 票范围内。
3. **`menuWillOpen` 里取状态是同步的**,内核 REST 卡住会拖慢菜单弹出。V1 接受(本机 127.0.0.1,
   `SocketHTTPPort` 有超时)。改异步得先解决「菜单已弹出后再更新内容」的闪烁问题,不在本票范围 —— 记为债务。
4. **两个新的 test-only env seam**(`AA_MENU_PROMPT_AUTO` / `AA_MENU_CLICK_PROBE`)与
   `AA_CONFIRM_AUTO` / `AA_AUTO_DENY_SECONDS` 同级:受 `#if AA_TESTING` 门控,生产二进制里没有那几行代码,
   但**13 票真机分发前须一并处置**。
5. **`simulateMenuClick` 是不带条件编译的生产代码。** 它只做「找到绑该能力的 NSMenuItem 并让 AppKit 派发」,
   不读环境变量、不改变任何行为,故不加 `#if`(加了就会把条件编译符号扩散到第二个文件,
   破坏 `build.sh` 里那条「整包带 `-DAA_TESTING` 是空操作」的等价性论证)。是否调用它由 HostApp.swift 决定。
   代价:生产二进制里存在一个「程序化点菜单」的入口 —— 它要先拿到 `AAMenuBarController` 实例才可达,
   在进程内没有额外攻击面,但这是一个**有意的取舍**,写在这里备查。
6. **子菜单在快照里是缩进展开的,真菜单是弹出的。** 见「证明力边界」。
7. **`AAMenuUserAction` 是 04 票散文的人工转写。** 见 MB1 那条的诚实口径。
8. **能力清单变更会让快照全红。** 那是**正确的红**(反向核对就是来抓这个的),重录流程见 `Snapshots/README.md`;
   门禁自己**永不**传 `AA_SNAPSHOT_RECORD`,且录制模式以 rc=3 结束 —— 否则「红了就录一遍」会让断言永远为真。
9. **菜单里没有「测速全部组」这类聚合动作**,测速只按组给(04 票 In 清单原文就是「按组」)。
   也没有 `proxy.license` 的独立项 —— 它由 15 票的「关于 AA」承担,那一项原样复用,本票一个字没改。
