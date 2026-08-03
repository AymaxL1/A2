# 11 — 骨架真值化(SPM 就绪后)

**What to build:** 工具链两段式的结账时刻:`Package.swift` 首次真实解析,`swift build` + `swift test`(swift-testing)接管 `check.sh`;此前 swiftc 直编与 assert 脚本产出的全部代码在真工具链下真值化。

**Blocked by:** 01;环境前置 = **一个可用的 SPM**(见下「前置的真面目」)

**Status:** blocked-on-env(SPM 不可用;**注意前置已不是「装 Xcode」**,见下)

**验证环:** 需可用 SPM(不需要 Xcode.app)。

## 前置的真面目(2026-08-04 实测修正)

这张票原先写着「完整 Xcode.app 安装并 `xcode-select` 切换后」。实测后该表述有两处不准:

1. **vfsoverlay 退役已经完成,且与 Xcode 无关。** 本机 CLT 曾有两个 bug,其一是 `usr/include/swift/` 下 `module.modulemap`(2023 僵尸文件)与 `bridging.modulemap` 重复定义 `SwiftBridging`,导致裸 swiftc 必挂 —— 这是 vfsoverlay 存在的唯一理由。用户于 2026-08-04 执行 `sudo mv module.modulemap module.modulemap.disabled` 后,裸 swiftc 零旗标编译通过,overlay 就此不再被使用。

2. **真正卡住本票的是另一个独立 bug:SPM 坏。** `libPackageDescription.dylib` 有 880 个 PackageDescription 符号却**零个 `Package.__allocating_init`**,与 `PackageDescription.swiftmodule` 接口错配;tools-version 6.0/6.1/5.9 全部 `Invalid manifest` + `Undefined symbols`。挪 modulemap 修不了它。

**解法候选(均不需要 Xcode.app)**:
- 装官方独立 Swift 工具链到家目录(**无需 sudo**):`swift-6.1.2-RELEASE-osx.pkg`(1530375397 字节)+ `installer -pkg ... -target CurrentUserHomeDirectory`。自带干净 `usr/include/swift/` 与配套 SPM。装好后用 env seam `AA_SWIFTC` 指向其 `swiftc` 即可接入门禁。**尚未验证。**
- 覆盖重装 CLT(从 developer.apple.com 下 dmg 装到现有安装上;`xcode-select --install` 在已装时不管用)。

**另注**:`Package.swift` 目前**零第三方依赖**,全是内部 target。SPM 唯一能买到的是「自动编译编排 + `swift test`」,而这两样 `Scripts/check/` 已手写实现且门禁全绿(PASS=403)。故本票是**清债与升级**,不是解锁 —— 12/13/15/16 票不依赖它,详见各票。

- [ ] `swift build` 全 target 零错误零警告通过,清单解析无误
- [ ] 既有 assert 测试迁移/改写为 swift-testing,`swift test` 全绿
- [ ] check.sh 换引擎但接口不变(一条命令、非零即败),01–10 票期间的验证脚本全部在新引擎下重跑通过
- [x] vfsoverlay 从门禁与文档中退役(留档注明历史用途)—— 2026-08-04 完成。`Scripts/check/bootstrap.sh` 改为**开跑时现场探测**工具链:裸编过走 `clean` 模式(无任何绕过旗标),裸编挂但带 overlay 过则回落 `overlay` 模式,两者皆挂如实报错退出;横幅打印所选模式。overlay 文件本体留在 `Spikes/S1PetOverlay/toolchain-workaround/` 归档,注明历史用途。CLT 修复后实跑门禁确认走 clean 模式且 PASS=403 FAIL=0,与修复前基线逐字一致。
