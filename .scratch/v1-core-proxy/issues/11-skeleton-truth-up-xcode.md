# 11 — 骨架真值化(SPM 就绪后)

**What to build:** 工具链两段式的结账时刻:`Package.swift` 首次真实解析,`swift build` + `swift test`(swift-testing)接管 `check.sh`;此前 swiftc 直编与 assert 脚本产出的全部代码在真工具链下真值化。

**Blocked by:** 01 —— **环境前置已于 2026-08-04 全部解除,本票现在可以领取。**

**Status:** done(今晚范围)—— 换引擎与骨架真值化已完成;**swift-testing 只做了试点**,余量拆到 17 票(见下)。

**验证环:** 独立 Swift 工具链(已装,见下)。**不需要 Xcode.app。**

## 环境前置已解除(2026-08-04 实测,附命令)

这张票原先写着「完整 Xcode.app 安装并 `xcode-select` 切换后」。**该前置是错的,且已被两步绕开:全程没装 Xcode,第二步连 sudo 都没用。**

**第一步 · CLT 重复 modulemap(bug 1)已根治。** `usr/include/swift/` 下 `module.modulemap`(2023 僵尸文件)与 `bridging.modulemap` 重复定义 `SwiftBridging`,曾导致裸 swiftc 必挂。用户执行 `sudo mv module.modulemap module.modulemap.disabled` 后,裸 swiftc 零旗标编译通过,vfsoverlay 退役(commit `123f3b9`,门禁已改自动探测)。

**第二步 · SPM(bug 2)已可用。** CLT 自带的 `libPackageDescription.dylib` 与其 `.swiftmodule` 接口错配(880 个符号但**零个** `Package.__allocating_init`),`swift build` 完全不可用。解法是装官方独立工具链到家目录,**无需 sudo**:

```
curl -O https://download.swift.org/swift-6.1.2-release/xcode/swift-6.1.2-RELEASE/swift-6.1.2-RELEASE-osx.pkg
installer -pkg ~/Downloads/swift-6.1.2-RELEASE-osx.pkg -target CurrentUserHomeDirectory
```

已装于 **`~/Library/Developer/Toolchains/swift-6.1.2-RELEASE.xctoolchain`**(另有 `swift-latest.xctoolchain`)。包校验:字节数 1530375397 精确一致、签名 `Developer ID Installer: Swift Open Source (V9AUD2URP3)`、经 Apple 公证。该工具链自带干净的 `usr/include/swift/`(只有 `bridging.modulemap`,无僵尸文件),其 `libPackageDescription.dylib` 有 18 个 `Package.__allocating_init`。

**调用方式**(门禁已留 env seam `AA_SWIFTC`):

```
TC=~/Library/Developer/Toolchains/swift-6.1.2-RELEASE.xctoolchain
"$TC/usr/bin/swift" build
AA_SWIFTC="$TC/usr/bin/swiftc" bash Scripts/check.sh
```

## 已实测到的起点(接手时不必重跑)

- **`swift build` 全 target 通过**:全新 scratch 目录冷构建,112 步 `Build complete!`(约 17s),**0 error、0 warning**,含 AppKit 的 `AAHostMacOS` 与 `aa` / `aa-agent` 两个可执行。清单解析无误(`swift package describe` 输出正常,零第三方依赖)。
- **唯一已知警告在清单层**:`Package.swift:85` 的 `swiftLanguageVersions: [.v5]` 已弃用,建议改 `swiftLanguageModes:`。该警告出现在 `swift package describe` 阶段,`swift build` 的编译输出里不显示。**本票的「零警告」验收需要把它一并收掉**(未代劳,留给实施)。
- **现状对照**:`Scripts/check.sh` 走 CLT 的 `/usr/bin/swiftc`(bug 1 修好后为 clean 模式),全量门禁 **PASS=403 FAIL=0 rc=0**。换引擎后须逐条复现这 403 条。
- **`AA_SWIFTC` seam 已端到端验通**:`AA_SWIFTC=$TC/usr/bin/swiftc bash Scripts/check.sh` → 工具链栏显示 `swift-6.1.2-RELEASE`、clean 模式、**PASS=403 FAIL=0 rc=0**。注意此路需要 `SDKROOT`:装在家目录的独立工具链**不会自动定位 SDK**(裸跑报 `no such module 'Foundation'`),bootstrap.sh 已统一用 `xcrun --show-sdk-path` 显式定死并打印在横幅上;调用方预设了 `SDKROOT` 则尊重不覆盖。同一改动对 CLT swiftc 是恒等操作(已跑回归确认 PASS=403 不变)。
- **仓库当前无 `Tests/` 目录、无 swift-testing 用例**;既有测试是手写 `TestReport` 断言框架放在库 target 的 `Sources/` 下,由 check.sh 动态生成 runner 跑二进制、断言 stdout。迁移到 `#expect` 时须保持行为不变(见 `.scratch/agent-delegation/spec.md`「测试引擎的现实落差」段)。

## 范围提示

`Package.swift` **零第三方依赖**,全是内部 target。SPM 买到的是「自动编译编排 + `swift test` + 将来可引第三方包(如 14 票的快照测试库)」。12/13/15/16 票**不依赖本票**(造 `.app` 不需要 xcodebuild,已实测),故本票是清债与升级,不是它们的解锁前置。

- [x] `swift build` 全 target 零错误零警告通过,清单解析无误 —— 清单层那条 `swiftLanguageVersions` 弃用警告已改成 `swiftLanguageModes: [.v5]` 收掉。
- [ ] 既有 assert 测试迁移/改写为 swift-testing,`swift test` 全绿 —— **只做了试点,未完成**。
      试点完成:`Tests/AAContractsTests/` 一个 target(退出码锁定表,6 个 `@Test` / 18 个参数化用例)已迁到 `#expect`,
      并由 `Scripts/check/swift-test.sh` 在门禁内跑绿(门禁记 1 条断言:整体绿/红,不按用例数展开)。
      **其余 8 套、约 5500 行手写 `TestReport` 断言(`Sources/AAHostTestKit/` + `Sources/AAAgentTestKit/`)未迁移**,
      仍由 `registry-tests` 可执行驱动。整体搬迁拆到 **17 票**(`17-swift-testing-migration.md`)。
- [x] check.sh 换引擎但接口不变(一条命令、非零即败),01–10 票期间的验证脚本全部在新引擎下重跑通过 —— 实测 **PASS=404 FAIL=0 rc=0**(403 条旧断言逐条复现 + swift test 新增 1 条)。
- [x] vfsoverlay 从门禁与文档中退役(留档注明历史用途)—— 2026-08-04 完成,commit `123f3b9`。`Scripts/check/bootstrap.sh` 改为**开跑时现场探测**工具链:裸编过走 `clean` 模式(无任何绕过旗标),裸编挂但带 overlay 过则回落 `overlay` 模式,两者皆挂如实报错退出;横幅打印所选模式。overlay 本体留在 `Spikes/S1PetOverlay/toolchain-workaround/` 归档(附 README 说明历史用途与撤销法)。CLT 修复后实跑门禁确认走 clean 模式且 PASS=403 FAIL=0,与修复前基线逐字一致。

## 实测记录(11 票落地当晚,2026-08-04)

- **门禁引擎已换成 `swift build` + `swift test`。** `Scripts/check/bootstrap.sh` 的工具链探测从「裸 swiftc / vfsoverlay 二选一」
  改成 **SPM 可用性探测**:对候选依次跑 `swift package dump-package`,第一个 rc=0 的胜出。
  候选顺序:`$AA_SWIFT`(env seam) → `~/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift` → PATH 上的 `swift`。
  一个都不行就如实报错退出并打印装独立工具链的两条命令,**不假装能跑**。
- **`swift test --disable-xctest --enable-swift-testing` 可用**,实测 `Test run with 6 tests passed`。
  `--disable-xctest` 是必需的:该独立工具链**不带 XCTest**(那是 Xcode.app 才有的),不禁掉 SPM 会去构建它找不到的 XCTest 宿主。
- **`Bundle.module` 的落点与「不能拷可执行」的坑(必须记住)**:PluginProxy 的资源被 SPM 打成
  `PROJECT_AA_PluginProxy.bundle`,产在 bin 目录里、与可执行文件**并排**;`Sources/PluginProxy/MihomoKernelResource.swift`
  在 `#if SWIFT_PACKAGE` 下用 `Bundle.module...!` **强解包**取它。所以门禁**绝不把可执行拷到别处运行** ——
  一拷就找不到 bundle,强解包当场崩。`build.sh` 里已把这条写成注释,免得将来有人「顺手整理一下」。
  (12 票打 `.app` 时,这个 bundle 必须跟着进 `Contents/`。)
- **暴露出一条既有竞态**(不是本票改坏的,是换引擎后才够冷才暴露):`mihomo-real-e2e.sh` 的生产宿主全链 E2E
  原本以 `"running":true` 当就绪判据 —— 那只说明「内核进程还活着」,拉起那一刻就为真。
  此前生产宿主经 `#filePath` 直接跑 `Sources/PluginProxy/Resources/` 里那份内核,而同一脚本上一段刚跑过它(热),
  REST 几乎瞬时可达,竞态被掩盖;现在跑的是 SPM 打进 bundle 的**新拷贝**(43MB,每轮门禁重建),
  实测冷启动约 0.4s 才 REST 可达,于是三条断言读到 `{"apiReachable":false,"running":true}` 而误判。
  已把就绪判据改成 `"apiReachable":true`、窗口 30s。**只改等待,不新增/删减断言。**
- **vfsoverlay 回落彻底退役的取舍(如实记录)**:回落分支与 `OVERLAY` 变量已从 `bootstrap.sh` 删除,
  连同 `SWIFTC_BIN` / `AA_SWIFTC` / `SWIFTC_COMMON` / `build_lib()` / `SDKROOT` 那段(`swift build` 自己做 SDK 解析,已无调用方)。
  代价写明:**门禁自此只能在 SPM 可用的机器上跑**——换成 `swift build` 之后,「坏 CLT 也能跑门禁」这条路径本就不复存在
  (坏 CLT 的 SPM 构建不了任何东西),回落已无意义。overlay 本体保留在 `Spikes/S1PetOverlay/toolchain-workaround/` 做历史留档。
- **`@main` 提前搬家**:`AAHostMacOS` 必须保持是「库」(07 票裁决),而 SPM 要产可执行必须有真 executable target,
  故新建 `Sources/aahost/AAHostMain.swift` 承接 `@main`,`AppDelegate` 转 `public`
  (连带 `applicationDidFinishLaunching` / `applicationWillTerminate` 也必须 public —— 编译器对 public 协议实现的硬要求)。
  这一步原计划归 12 票,现已提前结清;12 票只剩「把 `aahost` 打进 `.app` bundle」。
- **门禁 runner 固化**:`Scripts/check/build.sh` 里 heredoc 动态生成的 runner 改成真 target `Sources/registry-tests/main.swift`
  (SPM 只认真源文件),print 文本逐字保留 —— 下游 `unit-and-domain.sh` 在 grep 它们。**不加 product**(门禁内部工具)。
- **一个真雷已排除**:路径变量($KILLPAT / $PROD_HOST_BIN …)从静态改成「build.sh 里才赋值」之后,
  若门禁在 build.sh 之前失败退出,`pkill -f ""` 的空模式会匹配并杀掉**一切进程**。
  `cleanup()` 与 `finalize.sh` 里每一个变量型 `pkill` / `pgrep` 都加了非空守卫。
- **耗时**:全量门禁约 100s(与换引擎前的 ~102s 基线持平 —— 多出的两次 `swift build` + 一次 `swift test`
  被 SPM 的并行编译抵消掉了)。

### 双轴 CR 抓到的两处,已修(记在这里,因为都是「差点就蒙混过去」的那种)

- 🔴 **「SPM 的依赖边是编译期强制的」这个说法是错的,而我一度靠它替换掉了 01 票的铁律证明。**
  换引擎时,编 PluginProxy 用的「受限 `-I`(只放 SDK/Contracts/UISystem)」那段被删掉了,
  取而代之的是「清单里 PluginProxy 不依赖 Host* + `swift build` 成功」,注释还自称**比受限 -I 更硬**。
  事实相反:**同一个包里所有 target 的 `.swiftmodule` 都落在同一个构建目录**,SwiftPM 默认
  (非 explicit-module-build)把该目录整个塞进 `-I`;于是 import 一个未在 `dependencies` 里声明的
  同包 target,只要它恰好先构建完就照样编过 —— 这是 SwiftPM 长期已知的缺口。
  所以那次替换是**把一条真证明换成了一条更弱的声明面检查**,还贴了张更硬的标签。
  **已恢复受限 `-I` 编译证明**(从 SPM 的 `Modules/` 里只挑三个 `.swiftmodule` 到干净目录,
  以它为唯一 `-I` 对 PluginProxy 做 `-typecheck`),并**做了反证**:往源码里加一行 `import AAHostRuntime`,
  该 typecheck 立刻 `error: no such module 'AAHostRuntime'` —— 守卫真能抓到,不是摆设。
  清单面检查作为 **3b2** 保留,但它守的是另一件事:挡住「有人在 `Package.swift` 里给 PluginProxy
  开依赖 Host* 的口子」(声明即许可,哪怕暂时没人 import)。两条都要,+1 条断言。
- 🔴 **「零警告」这条验收辞此前没有门禁化。** `build.sh` 只判 rc,而警告不影响 rc ——
  那个勾靠的是一次性人工观察,哪天有人引入警告门禁照样全绿。已加**断言组 T2**:
  grep 两档构建日志里的 `warning:`,日志缺失也判 FAIL。+1 条断言。
- 另修两处 Standards 轴发现:`finalize.sh` 的残留断言在守卫不可用时会静默打 PASS(改成显式 FAIL,
  与 3a「守卫自身出错绝不算过」同口径);`agent-smoke.sh` / `manual-verify-04.sh` 各自用
  `ls -d …/*/debug | head -1` **猜** bin 目录(多三元组时会静默选错),改成读 `build.sh` 落档的
  `--show-bin-path` 权威答案。

## 剩余部分

**唯一未完成项是 swift-testing 全量迁移**,已拆成独立票:`.scratch/v1-core-proxy/issues/17-swift-testing-migration.md`
(Blocked by 11,Status: ready-for-agent)。本票的其余交付均已完成并在门禁内验证。
