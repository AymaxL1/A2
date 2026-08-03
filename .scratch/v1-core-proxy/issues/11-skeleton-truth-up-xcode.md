# 11 — 骨架真值化(SPM 就绪后)

**What to build:** 工具链两段式的结账时刻:`Package.swift` 首次真实解析,`swift build` + `swift test`(swift-testing)接管 `check.sh`;此前 swiftc 直编与 assert 脚本产出的全部代码在真工具链下真值化。

**Blocked by:** 01 —— **环境前置已于 2026-08-04 全部解除,本票现在可以领取。**

**Status:** ready-for-agent

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
- **现状对照**:`Scripts/check.sh` 走 CLT 的 `/usr/bin/swiftc`(bug 1 修好后为 clean 模式),最近一次全量门禁 **PASS=403 FAIL=0 rc=0**。换引擎后须逐条复现这 403 条。
- **仓库当前无 `Tests/` 目录、无 swift-testing 用例**;既有测试是手写 `TestReport` 断言框架放在库 target 的 `Sources/` 下,由 check.sh 动态生成 runner 跑二进制、断言 stdout。迁移到 `#expect` 时须保持行为不变(见 `.scratch/agent-delegation/spec.md`「测试引擎的现实落差」段)。

## 范围提示

`Package.swift` **零第三方依赖**,全是内部 target。SPM 买到的是「自动编译编排 + `swift test` + 将来可引第三方包(如 14 票的快照测试库)」。12/13/15/16 票**不依赖本票**(造 `.app` 不需要 xcodebuild,已实测),故本票是清债与升级,不是它们的解锁前置。

- [ ] `swift build` 全 target 零错误零警告通过,清单解析无误(编译层已实测 0/0;**清单层尚余 `Package.swift:85` 一条弃用警告待收**)
- [ ] 既有 assert 测试迁移/改写为 swift-testing,`swift test` 全绿
- [ ] check.sh 换引擎但接口不变(一条命令、非零即败),01–10 票期间的验证脚本全部在新引擎下重跑通过
- [x] vfsoverlay 从门禁与文档中退役(留档注明历史用途)—— 2026-08-04 完成,commit `123f3b9`。`Scripts/check/bootstrap.sh` 改为**开跑时现场探测**工具链:裸编过走 `clean` 模式(无任何绕过旗标),裸编挂但带 overlay 过则回落 `overlay` 模式,两者皆挂如实报错退出;横幅打印所选模式。overlay 本体留在 `Spikes/S1PetOverlay/toolchain-workaround/` 归档(附 README 说明历史用途与撤销法)。CLT 修复后实跑门禁确认走 clean 模式且 PASS=403 FAIL=0,与修复前基线逐字一致。
