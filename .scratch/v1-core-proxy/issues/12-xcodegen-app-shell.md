# 12 — `.app` 壳(shell 组 bundle + ad-hoc 签名)

> **文件名保持 `12-xcodegen-app-shell.md` 不变**(别处有引用,改名会断掉);标题与内容已按新范围重写。

**What to build:** 产品形态成型:一条命令(`Scripts/build-app.sh`)产出 LSUIElement 菜单栏 `.app` —— `.app` 内打包 GUI 宿主(`aahost`)、`aa` CLI 与 mihomo 内核资源,手工组 bundle + `codesign` 逐个签名(先内后外);双击 `.app` 即得完整宿主(状态栏项 + UDS server + 插件就位),`aa` 经 `install-cli` 对其全链可用。

**Blocked by:** 11(已 done)

**Status:** done —— 门禁 **PASS=414 FAIL=0 rc=0**(11 票基线 406 + 断言组 APP 6 条 + 反孤儿钩子守卫 1 条 + 「未触碰仓库外 mihomo」守卫 1 条),连跑两次稳定。

**验证环:** 独立 Swift 工具链(`~/Library/Developer/Toolchains/swift-latest.xctoolchain`)。**不需要 Xcode.app。**

---

## 范围变更:XcodeGen → shell 组 bundle(2026-08-04,用户裁决)

**票面原文**是「XcodeGen 工程定义入库(生成物不入库)→ `xcodegen generate` → `xcodebuild build`」,并要求「XCUITest target 建位(冒烟用例归 Phase 3,此处只立骨)」。**这条路被改写了**,原因如实记录如下:

1. **XcodeGen 的产物没有消费者。** `.xcodeproj` 只有 `xcodebuild` 能吃,而 `xcodebuild` 只随 Xcode.app 分发(CLT 里没有,Apple 官方文档明列;本机复测 `xcodebuild -version` 仍报 `requires Xcode`)。本机没有 Xcode。入库一份谁都跑不动的 `project.yml`,还要额外维护一套与 `Package.swift` 重复的依赖描述 —— **两处真值,必然漂移**,是纯死重。
2. **手工组 bundle 已实测可行。** `swift build` 出可执行 → 手工摆 `Contents/{Info.plist,MacOS,Resources}` → `codesign -s -` ad-hoc 签名 → `valid on disk` + `satisfies its Designated Requirement` → 可双击(`open` 走 LaunchServices)、可常驻菜单栏。整条链零 Xcode(先例见 `docs/research/electron-recon/toolchain.md` §1.3,本票再次端到端验证)。
3. **验收意图一条不减。** LSUIElement / `.app` 内三件套 / 一条命令出 `.app` / 双击即完整宿主 / 内核随 `.app` 内资源被拉起 / `install-cli` 全链可用 —— 全部保留,由门禁断言组 APP(6 条)把关。「构建链全脚本化」与「统一重签内嵌二进制」也保留(签名顺序先内后外;身份走 `AA_CODESIGN_IDENTITY` seam,13 票接着用)。

**代价(不粉饰):XCUITest 随 Xcode 一并推迟。** XCUITest 只能挂在 Xcode 工程下、由 `xcodebuild test` 驱动;没有 Xcode 就没有这个 target。**本票不立 XCUITest 骨架** —— 立一个跑不了的空壳只会制造「已经有 UI 自动化」的错觉,比什么都没有更危险。UI 层自动验证的缺口按 07 票架构映射的既定口径靠架构补偿(逻辑下沉 + 手搓快照),归 14 票。

`.scratch/v1-core-proxy/spec.md` 已就此追加**注明日期的勘误**(不改写原决策文字,只在文末「勘误(Errata)」段说明发生了什么、为什么、意图不变、代价是什么)。

---

## 验收 checkbox(逐条真实状态)

- [x] **构建脚本一条命令出 `.app`,进 check.sh 或独立构建脚本** —— `Scripts/build-app.sh`:
      `--variant production|e2e`(缺省 production)、`--output <dir>`(缺省 `.build/app`)、
      签名身份 env seam `AA_CODESIGN_IDENTITY`(缺省 `-` = ad-hoc)。每步失败即非零退出并打印原因;
      成功打印 `.app` 路径 / variant / 签名身份 / 版本 / bundle id / 体积。门禁断言组 APP 每轮真跑两档。
- [x] **`.app` 可启动:菜单栏可见、UDS 可连,`aa`(经 install-cli)对其全链可用**
      —— 门禁断言 APP4(直接 exec `.app` 内 aahost → UDS 就绪 → `aa capabilities list` 成功 → SIGUSR1 优雅退出 → 无残留)
      与 APP6(`install-cli --prefix <临时目录>` 的符号链接 canonical 化后确实指向 `.app` 内那个 `aa`,且经该链接调用能连上宿主)。
      「菜单栏可见」的**自动化**判据只到 `LSUIElement=true` + 宿主起得来(APP2/APP4);真·状态栏图标是人肉验的(见下「实测记录」)。
- [x] **mihomo 随 `.app` 内资源被 ProcessPort 正常拉起** —— 门禁断言 APP5:`aa proxy status --json` 报锁版内核版本号($MIHOMO_VERSION,唯一来源 `MIHOMO-VERSION.txt`),
      **且**内核进程的 argv 绝对路径落在 `.app` 内(两条一起验,单验版本号会被 SwiftPM 那条硬编码构建目录回退白送一个 PASS)。
- [x] **工程定义入库、可再生,生成物不入库** —— **换了载体**:入库的是 `Package.swift` + `Scripts/build-app.sh`(纯文本、可审、可再生),
      产物 `.app` 落 `.build/`(已被 `.gitignore` 忽略),不入库。**没有** `project.yml`、**没有** `.xcodeproj`。
- [ ] **XCUITest target 建位** —— **不做,如实记录**:没有 Xcode 就没有 XCUITest,该能力随 Xcode 一并推迟。
      本票不立空壳骨架。

---

## 实测记录(2026-08-04)

### 1. `Bundle.module` 在 `.app` 里的落点 —— 三个候选全跑过,结论反直觉

`Sources/PluginProxy/MihomoKernelResource.swift` 在 `#if SWIFT_PACKAGE` 下用 `Bundle.module...!` **强解包**取内核。
SwiftPM 生成的 `resource_bundle_accessor.swift` 只试**两个**路径:

```swift
let mainPath  = Bundle.main.bundleURL.appendingPathComponent("PROJECT_AA_PluginProxy.bundle").path
let buildPath = "<绝对路径>/.build/.../PROJECT_AA_PluginProxy.bundle"   // 构建时写死
```

**判据**(这一步很关键,否则测的是假的):先把构建目录里那份资源 bundle **临时移开**,断掉 `buildPath` 这条回退 —— 它在本机是存在的,不断掉的话三个落点都会「看起来能跑」。然后起真宿主看是活是崩,活着就再看内核进程的 argv 到底指向哪。

| 落点 | `Bundle.module` 能否找到 | `codesign` 能否接受 | 结论 |
|---|---|---|---|
| ① `Contents/Resources/PROJECT_AA_PluginProxy.bundle` | **否** —— 宿主启动即 `Fatal error: could not load resource bundle` | **是** | 单靠 `Bundle.module` 不行 |
| ② `Contents/MacOS/PROJECT_AA_PluginProxy.bundle`(复刻构建期布局) | **否** —— 同一条 fatalError | 未测(①已否决同类路径) | 不行 |
| ③ `AA.app/PROJECT_AA_PluginProxy.bundle`(bundle root,与 `Contents` 平级) | **是** —— 宿主起得来,内核 argv 确在 `.app` 内 | **否** —— 签 `.app` 报 `unsealed contents present in the bundle root`(rc=1),`--verify --strict` 随后报 `code has no resources but signature indicates they must be present` | 跑得起但签不了 |
| ③′ bundle root 只放**符号链接**指向 `Contents/Resources/…` | (未到这一步) | **否** —— 逐字同一条 `unsealed contents present in the bundle root` | 也不行 |

**核心发现:在 `.app` 形态下,「`Bundle.module` 找得到的落点」与「`codesign` 接受的落点」没有交集。**
票里原本的假设「先试 `Contents/Resources/`,理论上 `Bundle.main.resourceURL` 命中」是**错的** —— SwiftPM 的访问器压根不查 `resourceURL`,只查 `bundleURL`(即 `.app` 本身)。

**结账方式(本票唯一一处生产码改动):** `MihomoKernelResource.resourcePath` 在 `Bundle.module` **之前**先查
`Bundle.main.resourceURL/PROJECT_AA_PluginProxy.bundle/Resources/<name>`,命中就用。于是:

- `.app` 形态:资源 bundle 住 `Contents/Resources/`(可签、`--verify --strict` 通过),由这条新分支找到;
- 非 bundle 形态(`swift build` 出的裸可执行、门禁的 `registry-tests`):`Bundle.main.resourceURL` 就是可执行所在目录,
  SwiftPM 正把资源 bundle 产在那里 —— **命中同一份东西,既有行为不变**;
- `Bundle.module` 保留为最后回退,仍是强解包(真找不到就当场崩,**刻意不吞**:内核缺失时静默降级比崩更危险)。

门禁断言 APP5 是这条结论的**运行时证明**(核对内核 argv 绝对路径确实在 `.app` 内),15 票重签内核、13 票签名都以此为准。

### 2. 签名顺序与手法

- **先内后外**,不可颠倒:签 `.app` 本体会把 `Contents/` 下所有文件哈希封进 `CodeResources`;之后再动任何内嵌可执行(签名会改写 Mach-O)都会让外层封存失效,`--verify --strict` 当场报 `a sealed resource is missing or invalid`。
  实际顺序:① 资源 bundle 里所有带执行位的普通文件(当前只有 mihomo,写成遍历是为将来不漏签)→ ② `Contents/MacOS/aa` → ③ `.app` 本体。
- **主可执行 `aahost` 不单独签**:它是 `CFBundleExecutable`,签 `.app` 那一步会一并签掉,单独先签只会被覆盖、白花时间。
- **不用 `--deep`**:Apple 已弃用,且对嵌套代码的发现规则不可靠(会漏签非标准落点、也会用错身份/entitlements)。显式逐个签,签了哪些一目了然。
- 结果:`codesign --verify --strict --verbose=2` → `valid on disk` + `satisfies its Designated Requirement`;
  内嵌 mihomo `codesign -dv` → `Signature=adhoc`、`flags=0x2(adhoc)`。
- 13 票记号(已写进脚本注释):换真身份只改 `AA_CODESIGN_IDENTITY` 一个值;但真身份默认会去要安全时间戳(离线会失败,需 `--timestamp=none` 或联网),公证还要 `--options runtime`。

### 3. 双击启动(LaunchServices)人肉验证

`open --env AA_… AA.app`(全部 env seam 指向临时区)→ 宿主起来、`aa proxy status --json` 报
`{"apiReachable":true,"mixedPort":7890,"mode":"rule","node":"DIRECT","running":true,"version":"v1.19.28"}`,
`kill -USR1` 优雅退出。**ad-hoc 签名的 `.app` 走 LaunchServices 正常启动,无 Gatekeeper 弹窗。**

门禁里**不用 `open`**,用直接 exec `Contents/MacOS/aahost`:① 直接 exec 时 `Bundle.main` 仍是 `.app`(macOS 从 `Contents/MacOS/` 往上认 bundle),bundle 语义一个不少;② 拿得到 PID,能精确等待/收场,`open` 那条路进程与 shell 脱钩只能靠模式匹配猜。

> 顺带撞到的坑:想用 `osascript -e 'tell application "System Events" …'` 自动核验「无 Dock 图标 / background only」时,**AppleScript 触发 TCC 自动化授权、命令挂死**。已放弃自动化这一条 —— 它正是 13 票要处理的授权面。`LSUIElement=true` 由 `plutil -extract` 断言(APP2),真·状态栏图标留人肉。

### 4. 数字

| 项 | 值 |
|---|---|
| `.app` 体积 | **43 MB**(两档相同;几乎全是 43,418,754 字节的 mihomo 内核) |
| `build-app.sh` 冷跑(全新 scratch,含整包 `swift build`) | **约 18 s / 档** |
| `build-app.sh` 热跑(增量,只有组装 + 签名) | **约 0.9 s / 档** |
| 门禁总耗时(改前基线 PASS=406) | **约 105 s** |
| 门禁总耗时(本票之后 PASS=414) | **111 s / 112 s**(全部改动落地后连跑两次;此前几轮 112–114 s)→ **净增约 6–9 s** |

`.app` 的 SPM scratch 刻意放在 `$ROOT/.build/app-build-<档>`(**不在** `$BUILD=.build/check` 里)——
后者每轮门禁开头被 `rm -rf`,放进去就等于每轮冷构建(+36 s)。放外面则跨轮增量,稳态只花几秒。
`.app` 产物本身仍落 `$BUILD/app-{production,e2e}`,随每轮清掉,不留旧产物。

---

## 门禁增量

### 断言组 APP(`Scripts/check/app-bundle.sh`,6 条,排在 `architecture-and-cli.sh` 之后、`mihomo-real-e2e.sh` 之前)

1. production 档 `.app` 构建成功且结构完整(`Info.plist` + `Contents/MacOS/aahost` + `Contents/MacOS/aa` + 内核资源 bundle,执行位正确)。
2. `Info.plist` 的 `LSUIElement` 为 true 且 `CFBundleExecutable` 与实际可执行同名 —— 用 `plutil -extract`,**不 grep 猜 XML**(grep 证明不了它是哪个键的值、类型对不对)。
3. 签名可校验:`.app` 过 `codesign --verify --strict`,**且**内嵌 mihomo 自己有签名(`codesign -dv` 读得出)。
4. e2e 档 `.app` 全链可跑:直接 exec `Contents/MacOS/aahost` → 等 UDS → `aa capabilities list` 成功 → SIGUSR1 优雅退出 → 宿主与内核均无残留。
5. mihomo 从 `.app` 内资源被拉起:`aa proxy status --json` 报锁版版本号(`$MIHOMO_VERSION`,解析自 `MIHOMO-VERSION.txt`,门禁侧单一来源)**且** 内核 argv 落在 `.app` 内。
6. `aa install-cli` 的符号链接 canonical 化后指向 `.app` 内那个 `aa`,且经该链接调用能连上宿主(`--prefix` 指临时目录,**绝不碰真实 `/usr/local/bin`**,沿用 05 票口径)。

### 「未触碰仓库外 mihomo」守卫(`bootstrap.sh` 快照 + `finalize.sh` 比对,1 条)

**用户这台机器上正跑着他自己的 `/usr/local/bin/mihomo`,那很可能就是当下的上网通道 —— 掐掉它 = 断网。**
本仓库自带一份**同名但不同文件**的锁版内核,门禁起停的只有它。

光靠「代码里没写 `pkill mihomo`」来保证这件事是不够的:那是靠人读代码,读漏一次就出事。故按本仓库既有的
「跑前快照 / 跑后比对」口径钉死:记下所有**不在仓库树内**的 mihomo pid,跑完比对,少一个就红。
`pgrep` 自身出错时返回哨兵串并显式判 FAIL —— 否则「守卫坏了 → 前后都空 → 一致 → PASS」又是一次白送,
而这条恰恰是最不能白送的。已知误报:**用户自己在门禁运行期间重启 mihomo 会让它变红**,属预期(宁可误报不可漏报)。

**硬约束(写进了脚本注释):只有 e2e 档能起宿主,production 档只做静态断言、绝不启动。**
理由不是洁癖:把内核数据目录导向临时区的 `AA_MIHOMO_DATA_DIR` 是 `#if AA_E2E` 门控的,production 构建里**根本没有读它的那几行代码** —— 一起就会往真实 `~/Library/Application Support/AA/mihomo` 写。
起 e2e 宿主时照既有 E2E 口径带上 `AA_TAKEOVER_STATE_PATH` / `AA_SUBSCRIPTION_DIR` / `AA_MIHOMO_DATA_DIR`(外加纵深防御的 `AA_NETWORKSETUP_FAKE_STATE`)全部指向 `$BUILD` 临时区;控制端口用 39094,与 `mihomo-real-e2e.sh` 的 39090/39092 错开。

`bootstrap.sh` 的 `cleanup()` 与 `finalize.sh` 的残留核验都已覆盖 `.app` 里那个 aahost 的绝对路径(与 `$KILLPAT` / `$PROD_HOST_BIN` 是三条互不含子串的路径,一条 pgrep 覆盖不了)以及 `.app` 内的内核路径。
内核**只按 `.app` 内绝对路径**杀 —— 绝不 `pkill` 裸 `mihomo`:本票实测时就撞见用户机上跑着自己的 `/usr/local/bin/mihomo`。

### 断言组 3f(`architecture-and-cli.sh`,+1 条):反孤儿信号钩子未合流

`.scratch/agent-delegation/impl/07-aa-agent-cli-e2e.md` 声称「目前靠一条 grep 断言守着『全仓无可执行同时装两套』」——
**门禁里从来没有那条断言。** 声称有、实际没有的缓解措施比干脆没有更危险(读的人会以为雷已被守住,于是放心加依赖边)。本票把它真正补上。

现状(已核实):`AAHostMacOS.SystemProcessPort` 用**裸 `signal()`**、不保存前手不链式;`AAAgentSystem.SystemAgentPort` 是 save + chain 版。
`AAHostTestKit` 不依赖 `AAHostMacOS`,故 `registry-tests` 只拿到后者;`aahost` 只拿到前者。**债尚未到期。**

新断言:用 `swift package dump-package` 拿依赖图,`python3` 对**每个 executableTarget** 做传递闭包,
断言没有任何一个同时可达 `AAHostMacOS` 与 `AAAgentSystem`(用闭包而非直接依赖边:钩子是**传递**沾上的)。
解析失败 / 拿不到 target / 目标 target 改名一律判 FAIL(照 3a 口径:守卫自身出错时无法核验,绝不算过)。
当前实跑覆盖 `aa, aa-agent, aahost, registry-tests` 四个可执行,全绿。

**这条守的是「债未到期」这个前提本身,不是信号处理本身。** 本票刻意**不**改 `SystemProcessPort` 的信号链 ——
没有失败用例却动进程级信号处理,风险大于收益。**一旦这条红了**,就说明必须**先**给 `SystemProcessPort` 补对称的
save + chain(样板 = `SystemAgentPort`),才能继续往下走;红了不许靠加白名单绕过。

---

## 改动清单

| 文件 | 一句话 |
|---|---|
| `Scripts/build-app.sh`(新增) | 一条命令出 `.app`:两档构建 + 组 bundle + 写 Info.plist + 先内后外签名;顶部记录范围变更理由与三个落点的实测结论 |
| `Scripts/check/app-bundle.sh`(新增) | 断言组 APP 6 条(production 静态 3 条 + e2e 全链 3 条) |
| `Scripts/check.sh` | 把 `app-bundle.sh` 插进 source 列表(`architecture-and-cli.sh` 之后、`mihomo-real-e2e.sh` 之前) |
| `Scripts/check/architecture-and-cli.sh` | 新增 3f:反孤儿信号钩子合流守卫(依赖传递闭包) |
| `Scripts/check/bootstrap.sh` | 新增 `.app` 路径静态常量;`cleanup()` 覆盖 `.app` 内 aahost 与内核;更新 02 票那段过期陈述;加 12 票增量段 |
| `Scripts/check/finalize.sh` | 残留宿主核验并入 `.app` 内 aahost(e2e + production 两条路径),空值守卫同步扩展 |
| `Scripts/check/build.sh` | 更新「12 票打 .app」那条注释为实测结论 |
| `Sources/PluginProxy/MihomoKernelResource.swift` | 唯一生产码改动:`Bundle.module` 之前先查 `Bundle.main.resourceURL/<资源bundle>/Resources/<name>` |
| `Sources/aahost/AAHostMain.swift` | 注释:12 票已落地,且不走 XcodeGen |
| `Sources/AAHostMacOS/HostApp.swift` | 同上,文末债务口径那段的措辞 |
| `Package.swift` | 三处注释去掉「XcodeGen app 壳」的过期陈述 |
| `.scratch/v1-core-proxy/spec.md` | 文末追加注明日期的「勘误(Errata)」段(不改写原决策) |
| `.scratch/v1-core-proxy/issues/12-xcodegen-app-shell.md` | 本文件:按新范围重写(文件名不变) |

## 留给后续票的记号

- **13 票(签名仪式):** 身份 seam 已就位(`AA_CODESIGN_IDENTITY`,缺省 `-`);bundle id `com.aa.host` 是**品牌未定前的中性缺省**——
  `feature/brand` 上还躺着 8 张叫 Aymax 的 logo 概念稿,品牌定了大概率要改。**改 bundle id 的代价是 TCC / 通知授权重置**
  (系统按 bundle id 记授权,换 id 等于换了个新应用),所以要改就跟 13 票的授权仪式一次做完,别在别的时机顺手改。
  另:真身份签名的时间戳与 `--options runtime` 两项还没接。
- **15 票(GPL 关于页 + 内核重签):** 重签内核的落点已定死在 `Contents/Resources/PROJECT_AA_PluginProxy.bundle/Resources/`,
  且 `build-app.sh` 的签名步骤已经是「遍历资源 bundle 里所有可执行」——加内核/工具不会漏签。
  注意:`.app` 内那份内核被重签后 SHA 与清单里的锁版值不同(锁版 SHA 守的是 `Sources/PluginProxy/Resources/` 那份源件,由断言组 MK 把关)。
- **14 票(菜单栏轻壳 + 快照):** UI 自动验证仍无 XCUITest;`LSUIElement` 与宿主可启动已由 APP2/APP4 守住,状态栏图标本身仍需人肉或快照。
