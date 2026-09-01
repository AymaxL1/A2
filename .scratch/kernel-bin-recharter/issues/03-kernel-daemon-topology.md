# 03 — 调研:macOS 无头内核 bin 的进程拓扑与分发先例

Type: research
Status: resolved

## Question

内核从 GUI app 常驻改为无头 bin 后,常驻形态、拉起链与分发/签名的现实约束——产出 04 票裁决所需事实:

1. **常驻形态选项**:launchd LaunchAgent(socket activation、KeepAlive、按需唤起)、CLI 首次调用时自拉起、GUI 壳拉起、纯前台进程——各自官方口径与坑(登录会话/Aqua session 依赖、日志去向、崩溃自愈)。`SMAppService` 注册 LaunchAgent 是否要求调用方是 .app?裸 bin 有没有别的注册路径(`launchctl bootstrap`、plist 手装)?
2. **先例拆解**:tailscaled、colima/lima、OrbStack、Ollama、syncthing、mihomo 自身等「daemon + CLI + 可选 GUI」工具在 macOS 的实际拓扑:谁装 daemon、谁拉起谁、GUI 缺席时功能面、IPC 选型(UDS/localhost/XPC)。
3. **裸 bin 的签名/公证/quarantine 现实**:独立分发的可执行与 .app bundle 在 Gatekeeper/公证/TCC(通知、网络权限)上的差异;Homebrew 分发的签名姿态;对本仓库现状(手工组 .app + ad-hoc 签名,见 `docs/runbooks/`)意味着什么。
4. **GPL 子进程打包位置**:mihomo 内核在 headless 拓扑下随谁分发(bin 旁挂?独立下载?)对 [ADR 0007](../../../docs/adr/0007-mihomo-subprocess-gpl-compliance.md) 义务(附 GPL 文本 + 源码途径 + 重签)的影响。

结论落 `docs/research/kernel-daemon-topology.md`(中文,来源带 URL,区分实测/文档/推断)。

## Answer

调研文档:[docs/research/kernel-daemon-topology.md](../../../docs/research/kernel-daemon-topology.md)。

1. **裸 bin 不需要 `SMAppService`/`.app`**:本机 `man 5 launchd.plist` 实测确认 `Program`/`ProgramArguments`(绝对路径)与 `BundleProgram`(仅 `SMAppService` 专属)是两条独立键;裸 bin 走「手装 plist + `launchctl bootstrap <domain> <plist>`」是官方未废弃的一等公民路径,tailscaled `install-system-daemon` 是真实先例。`SMAppService` 反而要求至少一次 GUI 授权交互,与「CLI 首次调用零 GUI 自拉起」目标冲突,不建议采用。
2. **常驻域按登录依赖分层**:`system` 域(LaunchDaemon,root,不依赖登录)/ `user` 域(Agent,不强制 GUI)/ `gui`+`login` 域(传统 Aqua session)。建议默认 `user` 域 LaunchAgent。崩溃自愈可直接用 launchd 原生的 `KeepAlive.Crashed` + `ThrottleInterval`,不必在应用层重新发明看门狗。
3. **先例拓扑归纳**(tailscaled/colima/Ollama/syncthing/OrbStack/mihomo 自身):GUI 缺席时功能面通常 100% 完整(唯一常见缺口是自动更新,OrbStack 明文);IPC 清一色 UDS/loopback REST,与本仓库现有方案一致,且 UDS 天然吃 launchd socket activation。daemon 装法两大流派——CLI 子命令自装 plist(tailscaled)或 GUI 首次引导(OrbStack)——前者与 agent-first 目标更自洽。
4. **签名/分发现状不因裸 bin 化变差**:现状 ad-hoc `.app` 本就过不了线上 Gatekeeper,裸 bin 同样过不了;但裸 bin 走 Homebrew **Formula**(非 Cask)分发目前合规压力明显更低,且终端直接执行可能压根不触发 Gatekeeper 首次评估链路(社区共识,非 Apple 一手确认,建议后续 spike 实测)。TCC 层面裸 bin 比 `.app` 更脆弱(路径+内容双重记账),但仅在内核触碰 TCC 敏感能力时才相关——当前 REST/CLI 控制面不触碰。
5. **打包位置不改变 ADR 0007 的 GPL 分类结论**(独立子进程+外部通信与磁盘位置无关,沿用 `mihomo-integration.md` 已有中高确定性判断),但**动摇了义务的呈现位置**:「关于页」是 UI 概念,UI 降为可选后必须有不依赖 UI 的落点。建议 04 票/ADR 0007 修订钉死「CLI 子命令(如 `aa about`)+ 随包静态 GPL 文本文件」为至少一条必须始终存在的义务呈现路径。
