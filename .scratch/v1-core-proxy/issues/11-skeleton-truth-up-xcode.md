# 11 — 骨架真值化(Xcode 就绪后)

**What to build:** 工具链两段式的结账时刻:完整 Xcode.app 安装并 `xcode-select` 切换后,`Package.swift` 首次真实解析,`swift build` + `swift test`(swift-testing)接管 `check.sh`;此前 vfsoverlay 直编与 assert 脚本产出的全部代码在真工具链下真值化;vfsoverlay 退役(overlay 与直编脚本归档不再入门禁)。

**Blocked by:** 01;环境前置 = 用户安装 Xcode.app(明日)

**Status:** ready-for-agent(环境就绪前请勿领取)

**验证环:** 需 Xcode。

- [ ] `swift build` 全 target 零错误零警告通过,清单解析无误
- [ ] 既有 assert 测试迁移/改写为 swift-testing,`swift test` 全绿
- [ ] check.sh 换引擎但接口不变(一条命令、非零即败),01–10 票期间的验证脚本全部在新引擎下重跑通过
- [ ] vfsoverlay 从门禁与文档中退役(留档注明历史用途)
