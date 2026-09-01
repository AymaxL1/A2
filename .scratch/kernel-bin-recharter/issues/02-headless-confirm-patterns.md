# 02 — 调研:无 GUI 前提下的 dangerous 确认模式

Type: research
Status: resolved

## Question

[ADR 0005](../../../docs/adr/0005-agent-first-interaction.md) 第 4 条把 dangerous 能力的最终确认钉死在宿主 GUI(理由:agent 层审批可被用户整体关闭、`--yes` 类 flag 会被 agent 自己传上,等于不设防)。UI 降为可选后,这道防线需要新落点。调研一手资料,产出 05 票裁决所需事实:

1. **同类工具的确认面盘点**:daemon + CLI + 可选 GUI 形态的工具(Tailscale、Docker/colima/OrbStack、gh CLI、1Password CLI、sudo/polkit、ssh-askpass 系等)在无 GUI 时如何做危险操作/授权确认?模式归类:TTY 交互、设备码/浏览器跳转、系统通知动作按钮、预授权 token/TTL、Touch ID/biometric、物理确认等。
2. **macOS 平台约束口径**:无 app bundle 的裸 bin / launchd agent 能否用 UNUserNotificationCenter(含动作按钮的通知)?LocalAuthentication(Touch ID)对 CLI/daemon 进程的可用性?这些能力对签名/bundle 的要求?(文档级即可,标注置信度与需要 spike 实测的点。)
3. **每种模式对「agent 自批」的防御力评估**:哪些模式 agent 能替人点(等于不设防),哪些有真人在场证明(out-of-band、biometric、物理设备)。
4. **与 CLI 永不交互阻塞红线(ADR 0005 第 3 条)的兼容性**:各模式在「调用方是沙箱内非交互 agent」时的行为。

结论落 `docs/research/headless-confirm-patterns.md`(中文,来源带 URL,区分实测/文档/推断)。

## Answer

调研文档:[headless-confirm-patterns.md](../../../docs/research/headless-confirm-patterns.md)。

1. 同类工具的确认面可归六类:TTY 交互、设备码/浏览器跳转、预授权 token/TTL、系统通知动作按钮、biometric(弱=布尔判定/强=绑定 Secure Enclave 密钥)、一次性特权提升。预授权 token/TTL 对「agent 自批」零防御,业界无反例——与 ADR 0005 已否决的 `--yes` 反模式同构。
2. macOS 平台约束比预想更硬:Apple 工程师官方原话确认,无 app bundle/用户上下文身份的进程(裸 bin、LaunchAgent、LaunchDaemon 一视同仁)**不能**用 `UNUserNotificationCenter`,官方给出的唯一路径是拆一个用户态 app 代为弹通知;Touch ID 同理,DTS 原话「We only support Touch ID from a standard app context」。即「UI 可选」不等于「宿主进程可以完全消失」——本仓库已有的 `aahost` 菜单栏壳(12/14 票,`LSUIElement=true`、ad-hoc 签名)结构上正好满足这个先决条件,可从「主逻辑宿主」降格为「确认代理」,但不能降到零。
3. 防御力分层:强 Touch ID(绑定 Secure Enclave 密钥签名)与物理确认最高,agent 无法模拟;系统通知动作按钮对纯文本 agent 有效、对未来 computer-use 型 agent 是已知残余风险;预授权 token/TTL 零防御。
4. 红线兼容性上不需要推翻 ADR 0005 第 3/4 条既有形状(out-of-band + 超时 + 结构化 `confirmation_denied`/`confirmation_timeout`);TTY 密码提示类模式与红线结构性冲突,不可采用。
5. 三处「文档核不动」的点留给 spike(优先级最高:ad-hoc 签名的 `aahost.app` 能否成功弹带动作按钮的通知),已列入调研文档 §2.4,建议 05 票裁决前至少跑掉这一条。
