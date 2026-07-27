# 02 — mihomo 集成面与合规调研

Type: research
Status: resolved

## Question

代理插件要给 mihomo 内核做 UI 壳并把二进制打包进插件（V1 仅系统代理模式，不做 TUN）。逐项对照官方文档与源码核实集成面与合规约束，产出「技术栈决定」和「代理插件 V1 范围」两票所需的事实：

1. **external controller API 面**：REST + WebSocket 提供哪些能力——代理组/节点列举与切换、延迟测试、流量/连接/日志实时流、配置 reload、模式切换（rule/global/direct）。以 mihomo 官方文档/源码为准列出端点清单。
2. **进程管理**：启动参数与配置目录约定、优雅退出、崩溃后重启、多实例互斥、端口冲突处理。
3. **配置与订阅**：profile 的远程订阅格式与下载更新机制（proxy-provider / 完整配置两种路径）、与 Clash 生态订阅链接的兼容性。
4. **macOS 系统代理设置的真实权限要求**：`networksetup` / SystemConfiguration 是否需要管理员权限或特权助手；**ClashX Meta、Mihomo Party、Clash Verge Rev 各自怎么做（以源码为证）**——尤其关注「不做 TUN 时能否完全避开特权助手」。
5. **打包与分发**：mihomo 二进制体积、arm64/x86_64/universal 的处理、随应用签名/公证第三方二进制的注意点。
6. **合规**：确认 mihomo 实际 license（GPL-3.0 与否，以仓库 LICENSE 为准）；以子进程 + 公开接口方式捆绑分发时对宿主应用的开源义务如何解读（mere aggregation 论、FSF FAQ）；现有壳应用的 license 先例（哪些开源、以什么理由）。给出「宿主应用是否必须开源」的分析与建议，标注确定性。
7. **版本策略**：mihomo 发布节奏；内核版本随应用发布锁定 vs 应用内独立更新内核的取舍与先例。
8. **（范围外，仅记录门的形状）**：将来若加 TUN，需要什么——特权助手/守护进程、签名与授权要求。一段即可，不展开设计。

结论写入 `docs/research/mihomo-integration.md`（中文，每条结论附一手来源引用），并按 tracker 约定解决本票。

## Answer

- **不做 TUN 可完全避开特权助手**：`networksetup` 只要求调用者是管理员账户（man page 原文），Clash Verge Rev 即无助手直呼之；ClashX Meta/Clash Party 上助手是为标准账户、免密恢复与 TUN，非系统代理硬要求。需设计标准账户降级路径。
- **宿主不必开源（中高确定性，非法律定论）**：mihomo 为 GPL-3.0；子进程 + CLI + REST 属 FSF FAQ 的 "separate programs / arms length"。义务：附 GPL 文本 + 提供内核对应源码途径；红线：禁止任何进程内链接（ClashX Meta 因 c-archive 静态链接而 AGPL）。三壳均 copyleft，无闭源先例。
- **两栈集成难度无实质差异**：集成面 = spawn + HTTP/WS + networksetup，Electron/Swift 皆标配且各有先例；差异在签名公证管线（捆绑内核必须重签 + hardened runtime + timestamp）与将来 TUN 的特权组件工具链。
- 控制面 100% 官方 REST/WS 覆盖（切换/测延迟/流量日志流/reload/模式）；内核单架构 ~41.4 MiB（gz ~16 MB），官方无 darwin universal 资产、仅 ad-hoc 签名；稳定版约 1–3 周一发，建议 V1 内核随应用锁定发布。
- 全文（含 8 项逐条结论与来源）：`docs/research/mihomo-integration.md`
