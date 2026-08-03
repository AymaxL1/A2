# 01 — SPM 骨架 + check.sh 暂行形态

**What to build:** 正式工程骨架立起来:按 07 票的 target 清单(Contracts/PluginSDK/HostRuntime/HostMacOS/HostTestKit/UISystem/PluginProxy/aa)建目录与 `Package.swift`(依赖边按裁决声明;本机暂不可解析,写而不验);`Scripts/check.sh` 一条命令用 vfsoverlay 直编按依赖序编译全部 target 并跑 assert 式测试脚本,非零退出即失败。从此每张票的红绿循环都挂在这条命令上。

**Blocked by:** None — can start immediately

**Status:** done(`ff8990b`,门禁 10/10;后经 `23da16a` 将 check.sh 拆成 `Scripts/check/` 模块,一条命令的接口不变)

**验证环:** vfsoverlay(今天可验);`Package.swift` 的解析验证归 11 票。

- [ ] 目录布局与 target 清单和 07 票裁决一致,插件 target 不依赖任何 Host* target
- [ ] `Package.swift` 写就,依赖边与目录布局一一对应(解析留给 11 票真值化)
- [ ] `Scripts/check.sh` 全绿:vfsoverlay 直编所有 target(含各占位源文件)+ 至少一条 assert 测试
- [ ] check.sh 接口契约固定:一条命令、非零退出即失败(11 票换引擎时接口不变)
