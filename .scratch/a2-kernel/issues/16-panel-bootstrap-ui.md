# 16 — 面板自足·引导 UI:首启一键装内核 + 升级/卸载项 + 快照

**What to build:** 面板长出「引导执行器」与对应菜单区段:嵌入 bin 存在且内核未装时,首启弹一次说明框一键「安装并启动」;断连菜单出引导区段;连上后检测版本失配出「升级内核」项;「高级」出「停止并卸载内核服务」(带确认)。全部状态进菜单模型(一个模型两个渲染器 + 手搓快照),执行器只调嵌入 bin 白名单命令并解析机读 JSON。A2PanelAppDelegate 头部「壳不隐式拉起」注释按 ADR 0012 修订。

**Blocked by:** 14(嵌入 bin 落位 + ADR 0012)、15(`--copy-to-home` + kernelVersion/binPath + service --json)。

**Status:** done — 6fada97 + CR 尾款 fe94c0d — 引导执行器(四条白名单 + 可注入 runner,解析喂真金标)+ 首启说明框(触发判据纯函数,32 组合穷举)+ 菜单六条新分支与两渲染器快照 + APP11 包内冒烟

- [x] 执行器:定位 `Bundle.main.resourceURL/a2`(dev 无 bundle → 引导区段整体隐藏,现状「内核:未连接」文案保留);白名单仅 `service install --copy-to-home` / `service uninstall` / `service status` / `version`,全部走机读 JSON;子进程执行不占主线程,结果投回主线程
- [x] 首启:嵌入 bin 在 + `service status` = 未安装 + socket 不在 → 弹一次说明框(装什么:launchd 用户服务 `com.a2.kernel`、创建 `~/.a2`;怎么卸;「安装并启动」/「稍后」);「稍后」后不再纠缠,菜单项常驻可随时再装
- [x] 菜单模型新区段:断连时出「安装并启动内核」(已装未跑时标题相应变化,动作同为幂等 install);连上且失配时出「升级内核 vX→vY(重启服务,不断网)」;「高级」子菜单出「停止并卸载内核服务」(带确认弹窗);两个渲染器 + 手搓快照全部更新
- [x] 升级检测:hello kernelVersion vs 嵌入 bin `version`(启动时问一次并缓存,不轮询)
- [x] `applicationWillTerminate` 不变(退出仅断连);薄壳铁律不破:执行器无业务逻辑,只发起白名单命令并呈现结果
- [x] swift test(模型分支 + 执行器 JSON 解析用夹具注入,不真跑子进程)+ 快照全绿;.app 门禁步加冒烟:内嵌 bin 以临时 `A2_HOME` 跑 `service status`(机读)可用且不触碰真环境;门禁 8 步全绿;runbook 小白节收尾

## 实施记(与票面不同 / 值得记一笔的地方,均已在报告与 nightlog 里留账)

1. **票面第 4 条写「hello kernelVersion」,那个字段不存在** —— 15 票已查明线上内核版本本来就在
   `snapshot.status.version`(`KernelSnapshot.status` 就是 `StatusResult`,与 `a2 version` 同一真值源)。
   本票按事实实现:升级检测取 `state.kernelStatus?.version`,并有一条断言专门钉住
   「别把 `proxy.kernelVersion`(那是 mihomo 的)当成内核版本」。
2. **「已装未跑」态不显示版本差** —— 编排会话已裁定,白名单四条不扩(第五条命令要先改 ADR)。
   本票照办:那一态只把标题从「安装并启动内核」换成「启动内核」,命令仍是同一条幂等 install。
3. **`ServiceStatusResult` / `ServiceChangeResult` 的 Swift 镜像豁免:维持**(15 票遗留 3 的结账)。
   理由见提交说明与 `A2Bootstrap.swift` 头注 —— 面板只读四个字段,包封本身已镜像,
   而解析用例直接喂 `kernel/contract/golden/` 的真样本,契约漂了照样红。挪进镜像只多两个会漂的类型。
4. **顺带收拾了一处**:整段缺席时留下的**连续/首尾分隔线**(全新用户那份"什么能力都还不知道"的菜单
   第一次让它显形 —— 连着四条横线)。收口在构造器最后一步 `tidySeparators`,只动分隔线;
   既有四份 golden 逐字未变(有断言钉着)。
5. **`Sources/A2PanelFixtures/`、`Sources/a2-panel-snapshot/`、`Snapshots/a2-panel/` 三处动了**:
   前两处是"快照要新分支覆盖"的必然落点(装置住在 `Sources/` 是 SPM 的硬约束,不是偏好),
   第三处是六份新 golden。已在报告里逐条点名。
6. **白名单外没碰**,但留了三处口径待补(不影响门禁):`Scripts/check.sh` 两处步名与
   `docs/runbooks/signing-and-authorization.md:168` 仍写「APP1–APP10」,现已是 APP11。

## CR 尾款(`fe94c0d`,双轴 CR 之后一次收掉)

两轴一致判「有尾款,不阻塞方向」。七条必修/Spec + 五条顺手,全部落地;两条直接打在本票自己立的
「显式点击边界」上,记在最前面:

1. **回车不误装**:`NSAlert.addButton` 给第一个按钮**自动**塞 `\r`,只给第二个补绑不够。
   收进 `A2BootstrapPresenter.makeTwoButtonAlert` 一处(两个调用点都走它),新增 `A2BootstrapAlertTests`
   (含**反向证明**:不清那行时两个按钮确实都拿着回车)。
   **`A2ConfirmationPresenter` 裁定:Spec 轴对,不改** —— 手搭 `NSButton` 缺省 `keyEquivalent` 为空串,
   approve 一次都没被赋值,回车只落在「拒绝」上;裁定与依据写进该文件注释 + 一条断言钉住缺省值。
2. **首启说明框不许会话中途蹦出来**:加第五个输入 `hasUsedBootstrap`(`perform` 发起那一刻置位),
   穷举 32 → **64** 组;两条回归钉住"卸载收场不弹""安装失败不弹"。
3. NSAlert 正文四个 `**` 删掉 + 两条防回潮断言(不含 `**`、不含反引号)。
4. `refreshSocketPresence` **真接线**(并进 `refreshServiceStatus` 同一次投递),那个零调用的 public 方法删掉。
5. 退出码表测试改名改注释**如实**(是本表的变更探测器,不是双端对账;真对账要金标出机读码表,后续可选)。
6. 升级项补一条点击前披露 `.info`,重录 `09-bootstrap-upgrade` 两份 golden。
7. 断→连边沿补一次 `refreshServiceStatus`(纯函数判据 + 四条断言),修「面板外装服务 → 卸载项错误置灰死锁」。

顺手:runner 挂死恢复口径 + 双管道有界性说明;卸载确认的「先还原系统代理」留余地并补 `a2 proxy off`;
文案路径统一 `~/.a2/bin/a2`(有断言);`Package.swift` 注释四态 → 十种;`A2BootstrapOperation` 别名**删除**。
`distribution.md` §8 加人工项 #12(真按一次回车实测三个框)。

**记档不修**(CR 指明别动):「升级 vX→vY」在包内更旧时实为降级(动标题要挂 ADR 修订)、
running+断连 2 秒窗口的标题矛盾(自愈无害)、快照 460px 截断(渲染器 B 既有证明力边界)。

**上一轮报告里那三处「APP1–APP10」遗留已被 14 票尾款(`589d0f5`)收掉** —— check.sh 两处步名与签名 runbook
现均已是 APP11,本轮无需再动。
