# 06 — 「通用性」两种解读的事实盘点(不裁决 Mac-only)

Type: research
Status: resolved

## Question

用户动机里的「不够通用」有两种可能所指,各自把事实备齐(裁决与 ADR 0001 重开都不在本票):

1. **开发环境通用性**:Electron 路线的开发/测试/CI 有多少能在「任意有 Node 的机器」(含 Linux CI、另一台没有 Xcode 的 Mac)上跑:纯域层测试/构建/lint 全平台;E2E 与打包哪些必须 mac(mac 目标的 electron-builder 打包、签名公证);对照 Swift 路线(一切需 mac + Xcode,GitHub Actions macOS runner 税)。给出「贡献者/换机上手成本」对照表:git clone 之后各要装什么、多久能跑起来。
2. **产品跨平台**:若将来做 Windows,V1 设计的可携带度盘点:栈无关层(capability contract、manifest、注册表、CLI 语义、mihomo 子进程+REST)本就可携带;mac 专有面在 Electron 下的 Windows 等价与坑——系统代理设置(networksetup → Windows 注册表/WinHTTP)、UDS(Windows named pipe,Node net 同 API 支持)、Tray、悬浮窗点透(`setIgnoreMouseEvents` 在 Win 的行为)、登录项、通知、签名(Authenticode)。结论:切 Electron 后「将来 Windows」从『含核心全重写』(ADR 0001 的表述)降到大约什么工作量级;留在 Swift 则维持全重写。
3. 明确写出:哪怕切 Electron,V1 仍按 Mac-only 交付(ADR 0001 不动)也完全成立——通用性收益可以只兑现第 1 种。两种解读对应的裁决问题留给 08 票。

## Context

- ADR 0001(Mac-only)原文与旧图前提 1(「将来跨端接受重写含核心」);原调研文档 §3(框架对比)当年吹 Electron 跨平台的部分,检验哪些仍成立。

## Output

`docs/research/electron-recon/portability.md`(中文;两种解读分节,结尾各给一行「如果用户要的是这个,那么事实支持/不支持什么」)。

## Answer

解读(a)开发环境通用性:**支持**——域层测试/lint/构建可在任意 Node 机器(Linux CI/无 Xcode 的 Mac)上跑,零 Xcode;唯 mac 目标打包/签名/公证仍锁定真机 mac(Apple 限制,非语言限制),但门槛远低于 Swift 路线「处处要 Xcode.app」。解读(b)产品跨 Windows:**部分支持**——栈无关层(契约/manifest/注册表/CLI/mihomo)不受影响;UDS→named pipe 靠 Node `net` 几乎免费打通(最大利好);Tray/通知/点击穿透需 Windows 真机适配;Authenticode 签名需硬件 token/云 HSM,采购与流程与 mac Developer ID 完全不同形态(最大坑)。量级从 ADR 0001「含核心全重写」降到「栈无关层复用 + host-windows 适配包 + 独立签名流程」。「切 Electron 但 V1 仍 Mac-only(ADR 0001 不动)」自洽,解读(a)收益不依赖是否做 Windows。详见 [docs/research/electron-recon/portability.md](../../../docs/research/electron-recon/portability.md)。

Status: resolved
