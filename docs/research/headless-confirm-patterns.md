# 无 GUI 前提下 dangerous 能力的确认模式调研

> 决策落点：[ADR 0005：agent-first 交互与 dangerous 仲裁](../adr/0005-agent-first-interaction.md)。
> 调研日：2026-08-04。
> 标注约定：**【文档】** = Apple/各厂商官方文档、Apple Developer Forums 上 Apple 工程师（DTS）本人回复、项目官方仓库/源码——视为一手依据；**【推断】** = 由多条文档事实综合推出的判断或设计建议；**【建议】** = 面向裁决的行动建议。本次为纯文档调研，**没有本地 spike，不含「实测」档**——文档核不动、必须跑代码才能确认的点，统一标「需 spike」列入 §2.4，不假装已验证。

## 0. 结论摘要

1. **同类 daemon+CLI+可选 GUI 工具的确认面可归为六类**（详见 §1）：TTY 交互式提示、设备码/浏览器跳转（OAuth device flow）、预授权 token/TTL、系统通知（含动作按钮，需人在 GUI 会话）、biometric/Touch ID（弱=纯布尔判定，强=绑定 Secure Enclave 密钥）、一次性特权提升（privileged helper，只在安装时问一次）。**预授权 token/TTL 这一类对「agent 自批」零防御**——这正是 ADR 0005 已经拒绝的 `--yes` 模式在业界的同构物（Tailscale auth key、gh 存储 token、1Password service account token 都是同一反模式），调研没有找到反例。
2. **macOS 平台约束比预想更硬，且与「UI 可选」直接冲突**：无 app bundle 的裸 bin **无法**使用 `UNUserNotificationCenter`（含动作按钮）——Apple 工程师在官方论坛明确给出机制解释：弹通知需要 user-level TCC 授权，要求发起进程「running in a user context」，**LaunchAgent（不只是 LaunchDaemon）在没有 app bundle 身份的情况下同样不满足**，官方给出的唯一路径是拆出一个「user level component（如菜单栏 app）」代为弹通知。LocalAuthentication/Touch ID 同理：Apple DTS 原话「We only support Touch ID from a standard app context」，且锁屏态下 LaunchAgent 弹 Touch ID UI 直接报错「Can't show UI while not in a console session」。→ 详见 §2。
3. **推论**：「UI 降为可选壳」不能读成「宿主 GUI 进程可以完全消失」——只要还要在本机做「有真人在场证明」的确认（通知动作按钮或 Touch ID），**macOS 平台层面就要求至少存在一个常驻的、带 app bundle 身份的用户态进程来出面**，无头内核 bin 自己做不到。本仓库已有的 `aahost` 菜单栏壳（12/14 票，`com.aa.host`、`LSUIElement=true`、ad-hoc 签名）**结构上正好满足这个先决条件**——它可以从「主逻辑宿主」降格为「纯确认/通知代理」，但不能降到零。这是 macOS API 约束，不是本项目自选的架构偏好。→ §2.3、§5。
4. **防御力分层清晰**：物理确认（Touch ID 绑定 Secure Enclave 密钥、安全密钥触碰）> 系统通知动作按钮（对纯文本 agent 而言是真正的 out-of-band 人工点击，前提是 agent 无屏幕/鼠标控制能力）> 设备码浏览器跳转（一次性登录场景强，逐次动作确认场景弱）> TTY 密码提示（防御力取决于密码是否对 agent 不可见）> 预授权 token/TTL（零防御，agent 可携带 token 自批一切）。→ §3。
5. **与「CLI 永不交互阻塞」红线的兼容性**：凡是「阻塞读 stdin 等真人在同一 TTY 打字」的模式（sudo 密码提示、polkit 内建文本 agent 的 tty 兜底）与红线**结构性冲突**——无 TTY 时要么立即报错要么行为未定义，两者都不是我们要的。真正兼容红线的模式是**异步 out-of-band**：CLI 调用立即返回（或在有限超时内轮询/等待一个非 stdin 的确认通道），确认动作发生在另一个进程（GUI 弹窗、Touch ID 提示）里，CLI 端用结构化 `confirmation_pending` / `confirmation_denied` / `confirmation_timeout` 收尾——这正是 ADR 0005 第 4 条已经定的形状，本次调研没有找到需要推翻它的证据，只找到了「谁来出面弹这个 UI」这一层需要新落点。→ §4、§5。

---

## 1. 同类工具的确认模式盘点与归类

| 模式 | 代表工具 | 机制摘要 | 依据 |
|---|---|---|---|
| **TTY 交互式提示** | `sudo`（密码/Touch ID）、`ssh`/`ssh-add`（passphrase） | 阻塞读取受控终端；无 TTY 时行为依赖具体实现（`ssh-askpass` 系在有 `DISPLAY` 时弹 GUI，否则退回 TTY 提示） | 【文档】`ssh-askpass` manpage：“allows ssh-add(1) to obtain a passphrase from a user, even if not connected to a terminal (assuming that an X display is available)”；无 `DISPLAY` 时退回 TTY。https://manpages.debian.org/unstable/ssh-askpass-gnome/gnome-ssh-askpass.1.en.html |
| **设备码 / 浏览器跳转（OAuth device flow）** | `gh auth login`、`tailscale up`（交互式）、Codex/ChatGPT CLI 登录 | CLI 打印一次性 code + URL，人在另一台/同一台设备的浏览器里完成确认，CLI 轮询直到完成；**不占用 CLI 的 stdin** | 【文档】gh：“First copy your one-time code… Press Enter to open https://github.com/login/device in your browser.” https://cli.github.com/manual/gh_auth_login |
| **预授权 token / TTL** | Tailscale auth key（可设 ephemeral/TTL）、gh 存储 token、1Password service account token、Docker `--unattended` 安装 | 一次性人工操作换取一个可长期携带的凭证，此后所有调用凭凭证自动放行，**不再逐次确认** | 【文档】Tailscale：“generate a reusable or ephemeral auth key… pass it with `tailscale up --authkey=…`. No browser interaction is needed.” https://tailscale.com/docs/how-to/run-unattended ；ephemeral/TTL：https://tailscale.com/docs/features/ephemeral-nodes |
| **系统通知（含动作按钮）** | macOS 原生应用的 dangerous 操作确认（本项目 ADR 0005 现行方案）、`terminal-notifier` 类工具 | 系统级 UI，要求发起方是有 app bundle 身份的用户态进程；人在 GUI 会话里点按钮，进程外发起方无法直接伪造点击事件 | 【文档】见 §2.1 |
| **biometric / Touch ID** | macOS `sudo` + `pam_tid`、1Password CLI 桌面 app 集成、Teleport `tsh` | 弱形态＝纯 `LAContext.evaluatePolicy` 布尔判定；强形态＝绑定 Secure Enclave 密钥操作（`SecAccessControl` + `kSecAccessControlBiometryAny`），后者才是可防重放/防伪造的确认 | 【文档】见 §2.2、Teleport RFD 0054 |
| **一次性特权提升（privileged helper）** | Docker Desktop（`com.docker.vmnetd`） | 安装期弹一次 macOS 管理员密码授权对话框安装特权 helper，此后同类特权操作**不再逐次确认**（4.15–4.17 起） | 【文档】“Whenever elevated privileges are needed for a configuration, Docker Desktop prompts you… Most configurations are applied once, subsequent runs don't prompt.” https://docs.docker.com/desktop/setup/install/mac-permission-requirements/ |
| **（对照组）polkit `pkexec`：GUI agent 优先，内建文本 agent 兜底** | Linux `pkexec` | 有 GUI polkit agent 时走图形确认；没有时 `pkexec` 自己注册一个文本 agent（可用 `--disable-internal-agent` 关掉），从当前受控终端读密码；已知问题：无 agent 且无可用 TTY 时报 `No session for cookie` 而非优雅降级 | 【文档】“pkexec will use the authentication agent registered for the calling process… if no authentication agent is available, then pkexec will register its own textual authentication agent.” https://docs.oracle.com/cd/E75431_01/html/E71065/pkexec-1.html ；失败先例：https://github.com/NixOS/nixpkgs/issues/18012 |
| **（对照组）Tailscale 设备审批 vs Tailnet Lock** | `tailscale lock` | 两种不同确认面：Device approval 是「管理员在 admin console 审新设备」（人工、带外）；Tailnet Lock 是「用已信任的签名密钥对新节点签名」（`tailscale lock sign`，属于「预授权密钥」范畴而非逐次人工确认），二者互斥不可同开 | 【文档】https://tailscale.com/docs/features/tailnet-lock 、https://tailscale.com/docs/features/access-control/device-management/device-approval |

**归类小结【推断】**：六类模式可以按「是否要求真人当场在场」切两半——TTY 提示、通知动作按钮、biometric（强）、设备码浏览器跳转（首次登录场景）都要求真人当场参与；预授权 token/TTL、特权提升后的免确认窗口，本质是「把一次人工确认摊销到未来所有调用上」，对单次 dangerous 动作而言等价于无确认。ADR 0005 第 4 条否决的 `--yes` flag 与「预授权 token/TTL」是同一类东西的两种实现——业界没有反例说明这类模式能同时防 agent 自批。

---

## 2. macOS 平台约束口径

### 2.1 `UNUserNotificationCenter`（含动作按钮的通知）

**【文档，高置信】结论：无 app bundle 身份的进程不能用 `UNUserNotificationCenter`；这个限制不区分 LaunchAgent 与 LaunchDaemon，只看有没有 app bundle 身份。**

- 裸命令行工具（Foundation tool，非 bundle）调用会直接抛异常：`bundleProxyForCurrentProcess is nil: mainBundle.bundleURL`。Apple 工程师就此在论坛回复建议改用更底层的 `CFUserNotificationDisplayNotice`。https://developer.apple.com/forums/thread/724249
- 一个已编译为**裸 LaunchAgent**（无 bundle）的二进制同样立即抛出该异常；开发者提交了 Feedback（FB9963670）请求让 `UNUserNotificationCenter` 支持 LaunchAgent 托管的 XPC Service，截至调研未见官方承诺支持。可行方案是把 LaunchAgent 改造为 XPC 客户端，另建一个菜单栏 app 作为 XPC 服务端来弹通知。https://developer.apple.com/forums/thread/679326
- **最权威的一条**：Apple 工程师在另一贴明确给出机制层面的解释——「Posting notifications requires a user level TCC (Transparency, Consent, and Control) prompt, which requires the requesting app to be running in a user context. Therefore is not possible to use notifications (or anything else that requires user authorization) from a system level daemon or launch agent.」并给出推荐方案：「Your best bet would be to separate the notification functionality into a user level component, perhaps a user agent, and communicate between your launch agent and the user level process.」——**这里的措辞明确把 launch agent 和 system daemon 归为同一类「非用户上下文」**，可行方案不是「把 launch agent 换成别的进程类型」，而是「必须有一个具备 app bundle/用户上下文身份的进程来弹」。https://developer.apple.com/forums/thread/804854
- 侧证：`terminal-notifier`（业界标准的 CLI 通知工具）之所以打包成一个 `.app` bundle 分发，官方 README 层面的原因就是「NSUserNotification 不能从 Foundation tool 用」；即便是走已废弃的 `NSUserNotification` API 也要求 bundle 身份（虽然比 `UNUserNotificationCenter` 松，但同样不是纯裸二进制可用）。https://github.com/julienxx/terminal-notifier
- 签名要求【推断，需 spike】：多处二手资料提到 `UNUserNotificationCenter` 只对「已签名的可执行文件/bundle」放行；本仓库现有 `aahost.app` 已是 ad-hoc 签名（`Signature=adhoc`，见 `Scripts/check/app-bundle.sh`），**ad-hoc 签名是否足够满足 `UNUserNotificationCenter` 的签名前提，文档没有给出明确阈值，需要在本机对现有 `aahost` 壳跑一次 `requestAuthorization` + `add(request:)` 实测确认**（这是本票唯一强烈建议的 spike）。
- 动作按钮本身【推断，低风险】：一旦通知能弹出，`UNNotificationAction`/`UNNotificationCategory` 是标准 API，没有额外的 bundle/签名门槛记录在案；风险都集中在「能不能弹」而不是「弹出来的按钮能不能加」。

### 2.2 `LocalAuthentication`（Touch ID）

**【文档，高置信】结论：Touch ID 的官方支持面被 Apple DTS 明确限定为「standard app context」，不含 LaunchAgent/LaunchDaemon/Network Extension；锁屏态下从 LaunchAgent 触发直接报错。**

- 报错与场景：在 LaunchAgent 里于锁屏态触发 Touch ID UI，报 `Error Domain=com.apple.LocalAuthentication Code=-1004 "Can't show UI while not in a console session"`；帖子指出这是 macOS Big Sur 起的行为变化（Catalina 及更早时 LaunchAgent 在锁屏也能弹，只是不是原生 Touch ID UI）。https://developer.apple.com/forums/thread/672162
- **官方立场原话（Apple DTS 工程师）**：「We only support Touch ID from a standard app context.」——同贴明确 LaunchAgent、daemon、Network Extension provider 都不在支持范围内，也没有官方 workaround；系统自带的 LoginWindow 之所以能做到，是因为用了第三方开发者拿不到的私有 `evaluatePolicy` 变体（带 `uiDelegate` 参数）。https://developer.apple.com/forums/thread/672162
- **弱确认 vs 强确认的关键区分【推断，来自 Teleport 一手工程实践】**：Teleport 的 `tsh`（一个典型的「daemon/CLI + 可选 GUI」产品的 CLI 客户端）在设计无密码 macOS 登录时，**明确放弃了纯 `LAContext.evaluatePolicy` 布尔判定**，理由是它只返回一个布尔值，容易被绕过／伪造，RFD 原文称之为 "security theater"。他们改为在 Secure Enclave 里生成密钥并用 `SecAccessControl`（`kSecAccessControlBiometryAny`）把 Touch ID 校验直接绑定到密钥的签名操作上——但要拿到 Keychain Sharing / Secure Enclave 相关 entitlement，**`tsh` 必须打包成 macOS `.app`、代码签名、内嵌 provisioning profile、并公证（notarize）**。https://github.com/gravitational/teleport/blob/master/rfd/0054-passwordless-macos.md
- 对照：像 `kctouch`（一个小型开源 CLI，用 `go-touchid` 库触发 Touch ID 保护 Keychain 条目）文档里**没有**提及需要 app bundle 或签名要求，看起来是以裸二进制形式分发；但它面向的是「解锁本地存储的密码」这种弱确认场景，不是「证明某次危险操作发生时人在场」的强确认场景，且没有说明其在 LaunchAgent/后台场景下是否可用（README 未提及，README 隐含的使用方式是从 Terminal 前台交互调用）。https://github.com/rgeraskin/kctouch【推断：未验证其在非交互/后台上下文下的行为，需 spike 才能确认弱确认路径对我们是否可用，以及可用边界在哪】
- macOS 系统自带的 `sudo` + Touch ID（`pam_tid.so`，经 `/etc/pam.d/sudo_local`）能在 Terminal 里工作，**但这不是一个第三方 CLI 可以直接复用的通用机制**：它依赖 Apple 系统组件（`sudo`/PAM/SecurityAgent）持有的私有权限，且要求用户已手动开启该 PAM 配置、且调用发生在一个真实的交互式 Terminal 会话（console session）里——不是「任何 CLI 都能像 sudo 一样弹 Touch ID」的证据，只说明 Apple 自己的特权路径可以。https://derflounder.wordpress.com/2023/10/14/enabling-touch-id-authentication-for-sudo-on-macos-sonoma/

### 2.3 与本仓库现状的交叉引用【推断，仓库内事实，非本次 web 调研】

- 本仓库已有 `Scripts/check/app-bundle.sh`（12/14 票产出）：产物 `AA.app`（`aahost` 可执行），`Info.plist` 含 `LSUIElement=true`（菜单栏 accessory，无 Dock 图标）、`CFBundleIdentifier` 存在且一致；当前签名为 ad-hoc（`Signature=adhoc`，`TeamIdentifier=not set`，无证书链）。
- 仓库内检索未发现任何 `.swift` 文件引用 `UNUserNotificationCenter` 或 `LocalAuthentication`/`LAContext`——即**本项目当前对这两个 API 都是零实测**，§2.1/§2.2 全部结论来自外部文档调研，不是本仓库经验。
- 结合 §2.1/§2.2：**`aahost` 这个已有的、带 app bundle 身份的 `LSUIElement` 菜单栏进程，天然满足「弹通知/弹 Touch ID 需要 app 上下文」这条 macOS 硬约束**——UI 降为可选后，它可以从「持有全部主逻辑的宿主」收缩为「只负责在需要时出面确认」的最小常驻壳，但**不能收缩到零**，除非接受放弃通知动作按钮和 Touch ID 这两类确认手段、退回纯 TTY 或纯预授权 token（后者已被 ADR 0005 否决）。

### 2.4 待 spike 清单（文档核不动的点）

1. **ad-hoc 签名的 `aahost.app` 能否成功 `requestAuthorization` + 弹带动作按钮的通知**——§2.1 签名门槛文档没给出明确阈值，本仓库已有现成 ad-hoc 签名的 bundle，成本最低、优先级最高的一个 spike。
2. **`aahost`（LSUIElement=true、以 LaunchAgent 或直接可执行方式启动）在用户已登录、屏幕未锁定的常规场景下能否成功弹 Touch ID（弱确认）**——官方立场是「不支持」，但没说「一定失败」；需要实测确认失败模式是「总是拒绝」还是「不稳定、时好时坏」（后者比前者更危险，不能作为安全边界）。
3. **强 Touch ID 确认（绑定 Secure Enclave 密钥）在 ad-hoc 签名下是否可行**——Teleport 案例要求完整 provisioning profile + notarize，本项目 Phase 1 定性为 ad-hoc 终态（见项目记忆），若强确认硬依赖真证书，这是一个需要提前预判的成本/时间线问题，归 05 票裁决输入。
4. **无 TTY 场景下 `pkexec` 内建文本 agent 的确切失败模式（挂死 vs 快速报错）**——决定「out-of-band 确认+超时」设计是否需要额外防「调用方误用阻塞式确认路径导致挂死」的兜底；已有同类未决问题在 `agent-first-interface.md` §7 第 4 条（`codex exec` 非交互 escalation 行为），可合并同一次 spike 处理。

---

## 3. 各模式对「agent 自批」的防御力评估

| 模式 | agent 能否替人点 | 防御档位 | 理由 |
|---|---|---|---|
| 预授权 token / TTL | **能**（agent 只要携带 token 即可自批一切） | **零防御** | token 一旦签发，后续调用无需人工介入；这正是 ADR 0005 已否决的 `--yes` 反模式的同构物 |
| TTY 密码提示 | **视密码是否对 agent 可见而定**——若密码存在 agent 可读的 keychain/env/文件里则**能**；若只有人知道则**不能** | **弱\~中** | 防御力不在「有没有提示」，而在「秘密本身对 agent 是否不可及」；agent-first 场景下这个前提通常不成立（agent 常被授权访问同一台机器的凭证存储） |
| 设备码 / 浏览器跳转 | **一次性登录场景下不能**（需要人在浏览器里点确认，除非 agent 本身有已登录的浏览器会话/computer-use 能力）；**逐次动作确认场景不适用**（这类模式天然是「登录一次换会话」，不是「每个危险动作都走一遍」 | **中\~高（仅限首次授权），不适合复用为逐次确认** | 强项是首次信任建立；不是为「这一次具体的 dangerous 调用」把关的机制,若被误用为逐次确认会退化成预授权 token 的等价物 |
| 系统通知（动作按钮） | 纯文本/工具调用型 agent（如 Codex CLI）**不能**——它没有 WindowServer/Accessibility 访问权限，无法模拟点击系统通知；**computer-use 型 agent（有屏幕控制能力）理论上能**，是本模式的已知残余风险 | **高（对文本型 agent）/ 中（对 computer-use 型 agent）** | 与 ADR 0005 现行方案同构；防御边界明确系于「agent 有没有屏幕控制权」，需要在弹窗设计里加防社工话术（展示真实参数）以缓解 computer-use 场景 |
| Touch ID（弱，纯布尔判定） | **不能替人点手指**，但**能被绕过/伪造判定结果本身**（Teleport RFD 原话 "security theater"——布尔返回值这一层可被攻击面覆盖，不等于「人一定在场」） | **中** | 证明「有人碰了传感器」但不证明「这个人认可这个具体动作的参数」，也不天然防重放 |
| Touch ID（强，绑定 Secure Enclave 密钥签名） | **不能**——每次授权都是对当次请求内容的密钥级签名，无法脱离物理生物识别重放 | **高** | Teleport 采用这个形态正是为了拿到密码学级别的「人在场」证明，而非 UI 层面的布尔值 |
| 物理确认（安全密钥触碰等，业界通用先例，未在本项目工具栈内实测） | **不能** | **高** | 需要物理动作，无法被纯软件 agent 模拟 |
| 一次性特权提升（Docker helper 模式） | 首次安装**不能**（要真人输密码）；**安装完成后的后续操作能**（不再逐次确认） | **首次高，后续零** | 只适合「装一次拿到系统级能力」的场景，不适合「每次 dangerous 动作都要把关」的场景，与 §1 的预授权 token 属同一类风险 |

---

## 4. 与「CLI 永不交互阻塞」红线的兼容性

（红线原文：ADR 0005 第 3 条——无 TTY 时不等待 stdin；确认语义只能是显式 flag 或宿主 GUI 的 out-of-band 确认）

| 模式 | 无 TTY / 非交互场景下的行为 | 兼容判定 | 理由 |
|---|---|---|---|
| TTY 密码提示（`sudo`、polkit 内建文本 agent） | 阻塞读受控终端；无终端时或挂死（等一个永远不会来的 stdin）或读到 EOF 快速失败——**取决于调用方怎么接 stdin，行为未在文档中保证**（§2.4 spike 项 4） | **不兼容** | 这类模式假设「总有个人在同一个 TTY 上」，与「调用方是沙箱内非交互 agent」的前提直接矛盾；polkit 已有的失败先例（`No session for cookie`）说明这条路在真实无 GUI agent 环境里连「优雅报错」都不一定保证 |
| 设备码 / 浏览器跳转 | CLI 可以设计成**立即返回**（打印 code+URL 或结构化 pending 状态），不占用 stdin，人工确认发生在浏览器里，CLI/agent 侧改为轮询或等待 webhook | **可兼容（需按异步方式设计）** | 关键是不能让 CLI 主线程阻塞等 stdin；gh CLI 的实现本身也是「打印+轮询」而非「读 stdin」，天然贴近红线 |
| 预授权 token / TTL | 不涉及运行时确认，直接放行或直接拒绝，零阻塞 | **技术上兼容，但防御力为零**（见 §3） | 兼容红线不等于满足 ADR 0005 的安全目标；这是「兼容红线」和「守住第 4 条」两个约束互相拉扯的地方 |
| 系统通知（动作按钮，out-of-band） | CLI 调用把「请求确认」这件事变成一次 IPC（发给宿主确认进程），自己**不阻塞 stdin**，改为等待该 IPC 通道的响应（带超时），超时/拒绝走结构化错误码 | **兼容**（ADR 0005 第 4 条已经是这个形状） | 阻塞点从「stdin」换成了「一个有超时、有明确失败语义的进程间通道」，满足红线字面要求（不等 stdin），也满足「agent 调用方不会被挂死到天荒地老」的精神（有超时兜底） |
| Touch ID（弱或强） | 同上，只要触发方是宿主确认进程（§2.1/§2.2 已证明裸内核 bin 自己做不到），CLI 侧同样是「等一个带超时的 IPC 响应」而不是等 stdin | **兼容**（前提：由带 app 身份的宿主进程出面，见 §2.3） | 阻塞语义与通知模式相同；额外约束是这个宿主进程必须存在且在运行，否则确认请求本身要有「宿主未运行」的结构化降级路径（沿用 `agent-first-interface.md` 已定义的 `host_unavailable`） |
| 一次性特权提升（Docker helper 模式） | 安装期是一次显式的、独立于任意具体命令调用的阻塞式人工授权；日常调用不阻塞 | **兼容**（因为它不是「逐次确认」机制，不落在红线适用范围内） | 与 dangerous 能力的逐次确认是两个不同问题，不能互相替代 |

---

## 5. 对 05 票裁决的输入摘要

1. **ADR 0005 第 4 条的「落宿主 GUI」不能改成「不需要任何常驻进程」**：macOS 平台层面，`UNUserNotificationCenter`（含动作按钮）和 `LocalAuthentication`（Touch ID）都要求发起方具备 app bundle / 用户上下文身份，裸头内核 bin 和裸 LaunchAgent 都做不到（Apple 工程师原话见 §2.1、§2.2）。05 票的可选项应该是「宿主 GUI 的形态可以多小」，而不是「要不要宿主进程」。
2. **本仓库已有的 `aahost` 菜单栏壳（`LSUIElement=true`、ad-hoc 签名）结构上已经满足这个先决条件**，可以作为「dangerous 确认代理」的落点而不必新造一个进程；05 票可以把它的职责从「持有主逻辑」重新定义为「只负责：接内核 IPC 请求 → 弹通知/Touch ID → 把结果回传」，与 06 票（菜单栏壳保留范围）直接相关，建议两票对齐。
3. **确认机制建议按防御力分层而非单一选型**：normal 级可继续沿用 Codex 层审批/幂等键（既有结论不变）；dangerous 级里，「系统通知动作按钮」对纯文本 agent 是有效 out-of-band 关卡，但对未来可能出现的 computer-use 型 agent 是已知薄弱点——**如果 05 票要为这个残余风险定级，Touch ID（尤其是强确认、绑定 Secure Enclave 密钥）是唯一在本调研中找到的、能防「软件层面模拟点击」的手段**，代价是可能要求真证书签名（§2.4 spike 项 3，与 13 票 ad-hoc 终态可能冲突，需要提前排期判断）。
4. **「预授权 token/TTL」「一次性特权提升后免确认」两类模式禁止用于逐次 dangerous 确认**——业界没有反例，调研支持 ADR 0005 现有立场不变。
5. **红线兼容性上不需要推翻 ADR 0005 第 3/4 条的既有设计形状**（out-of-band + 超时 + 结构化 `confirmation_denied`/`confirmation_timeout`）；需要补的是「宿主确认进程的最小职责边界」与「宿主未运行时的降级路径」，后者应复用 `agent-first-interface.md` 已有的 `host_unavailable` 语义，不必另起一套。
6. **遗留给 05 票或后续 spike 票的三个未决问题**：(a) ad-hoc 签名下通知能否正常工作（低成本，建议先做）；(b) ad-hoc 签名下弱 Touch ID 能否用、失败模式是否稳定；(c) 强 Touch ID 是否硬依赖真证书——这三条任何一条的结果都可能改变 05 票的可行选项集合，建议 05 票裁决前至少跑掉 (a)。
