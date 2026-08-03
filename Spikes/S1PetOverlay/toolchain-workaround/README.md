# toolchain-workaround —— 历史归档 + 回落分支

**现状(2026-08-04 起):本机已不再需要它。** 保留在此有两个理由:留档,以及给 CLT 仍坏的机器当自动回落。

## 它当年解决什么

本机 CLT 的 `/Library/Developer/CommandLineTools/usr/include/swift/` 下曾同时存在两个 modulemap:

```
module.modulemap      2023-08-18   ← 老 CLT 升级残留的僵尸文件
bridging.modulemap    2025-04-16   ← 当前 CLT 16.4 的
```

两者都定义 `module SwiftBridging`,内容仅差一行版权年份。结果是**任何** Swift 文件的编译都直接失败:

```
error: redefinition of module 'SwiftBridging'
```

连纯 Foundation、不 import AppKit 的源文件也一样 —— 这是 CLT 层面的坏 modulemap,与用不用 AppKit 无关。

`overlay.yaml` 用 clang/swift 的虚拟文件系统机制,把那个僵尸 `module.modulemap` 遮成 `empty.modulemap`(空文件),重复定义消失,编译恢复。不需要 sudo,不改系统任何文件。

## 为什么现在不需要了

2026-08-04,用户执行了根治版的同一件事(需 sudo,可逆):

```
sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap \
        /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap.disabled
```

修后裸 `swiftc` 零旗标编译并运行成功。

## 现在谁还会用到它

`Scripts/check/bootstrap.sh` 的**工具链探测**段。门禁每次开跑拿一个最小样例现场探:

- 裸编过 → `clean` 模式,**不传本目录的任何东西**
- 裸编挂、带 overlay 过 → `overlay` 模式,回落用本目录
- 两者都挂 → 如实报错退出

所以在本机它已是死代码;换一台 CLT 仍坏的机器,它会自动重新上岗。`Spikes/S1PetOverlay/run.sh` 与 `Spikes/S2CapabilitySlice/run.sh` 仍固定带该旗标(对已修好的机器无害),原因见各自文件头注释。

## 撤销

想恢复原状(例如验证探测器的 overlay 回落分支是否还工作):

```
sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap.disabled \
        /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
```
