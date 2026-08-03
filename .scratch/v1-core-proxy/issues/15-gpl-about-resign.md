# 15 — GPL 关于页 + 内核重签入构建链

**What to build:** ADR 0007 义务落地:关于页(或菜单栏「关于」项)呈现 mihomo GPL-3.0 文本、内核版本号与源码获取指引;构建链统一重签内嵌二进制——mihomo 原始 ad-hoc 签名在打包时以本应用开发签名重签,`.app` 内所有可执行签名一致、随构建脚本自动完成。

**Blocked by:** 12

**Status:** done(门禁 PASS=418 FAIL=0 rc=0;GUI 窗口渲染未经人眼确认,见下)

**验证环:** 票面原文写「需 Xcode」——**已作废**。12 票把 `.app` 的产出从 XcodeGen/`xcodebuild` 改成
`Scripts/build-app.sh` 手工组 bundle + `codesign`,本票全程未触碰 Xcode(本机也没有装)。
签名一律 ad-hoc(`codesign -s -`),身份走 env seam `AA_CODESIGN_IDENTITY` —— 真证书是 13 票的事。

---

## 逐条验收状态

这条验收辞里既有**数据面**(内容对不对、版本号单一来源)又有**呈现面**(关于页真的显示出来)。
两者的验证强度天差地别 —— 前者门禁每轮真验,后者一次都没验过。**打一个勾会把后者也记成做完**,
故拆成两条分别记账(这是双轴 CR 抓到的:原先是「打勾 + 行内免责」,等于把没验过的东西算作已完成)。

- [x] **(数据面)GPL-3.0 全文、内核版本、源码指引的内容正确,且版本号单一来源** —— 门禁 APP7/APP9 每轮真验
  - 关于页 = 菜单栏「关于 AA」项 → `AboutWindowController`(`Sources/AAHostMacOS/AboutWindow.swift`)。
  - 全文入口 = 一个按钮,`NSWorkspace.shared.open` 打开随包的 `LICENSE-mihomo-GPL-3.0.txt`;
    文件不在盘上时按钮 disabled 并如实说明落点(不做「点了没反应」的假入口)。
  - **版本号单一来源 = `MihomoKernelResource`**:`version` / `license` / `sourceURL`(由 `version` 派生,
    不写死整条 URL)/ `licenseTextPath`(复用 `resourcePath`,与内核可执行同一条落点解析)。
    门禁侧的对应来源是 `bootstrap.sh` 从 `Resources/MIHOMO-VERSION.txt` 解析的 `$MIHOMO_VERSION`;
    APP9 每轮把两者对一次(见「实测记录」)。
  - **数据全部经能力面取,GUI 零私有逻辑**:关于页调 `registry.invoke("proxy.license")`,与
    `aa proxy license --json` 是同一条路径同一份数据 —— 故 headless 门禁验得到它,且 GUI 与 CLI
    物理上不可能显示出不同的版本号。

- [ ] **(呈现面)关于页在屏幕上真的显示出来、全文入口按钮真的能点** —— **未验,不打勾**
  - 「菜单点开 → 窗口画出来 → 按钮可点 → 打开 txt」这一整段**没有人肉点过,也没有任何自动化覆盖**。
    本机无 Xcode → 无 XCUITest;`osascript` 查窗口会触发 TCC 自动化授权弹窗并挂死(12 票实测过)。
  - 已有的证据只到:菜单项被构造出来并挂进 NSMenu(代码可读)、按钮的 action 指向存在的方法、
    数据源(`proxy.license`)返回正确内容(门禁验)。**这些都不等于「用户能看见」。**
  - 归属:GUI 可见性属 **14 票**的快照面(手搓 NSView → PNG,可 diff、可人眼抽查)与 **13 票**的授权面。
    本票不在此假装验过。

- [x] **构建产物内 mihomo 签名与应用一致,校验通过**
  - 断言 APP8:枚举 `.app` 内所有 Mach-O(当前 3 个:`aahost` / `aa` / `mihomo-darwin-arm64`),
    逐个 `codesign -dvvv`,要求**全部已签名**且**签名身份指纹一致**。
  - **诚实口径(不许含糊)**:当前是 ad-hoc 签名,`codesign -dv` 只给 `Signature=adhoc` /
    `TeamIdentifier=not set`,**没有 `Authority=` 证书链 —— ad-hoc 根本没有证书**。
    所以这条挡得住的是「`.app` 里混进一个**未签名**的、或**用别的身份签**的二进制」;
    它**挡不住**「是不是同一张证书」,因为那个问题在 ad-hoc 下不存在。
    **不要把这条的 PASS 读成「签名有证书背书」。** 13 票换真开发证书后,`Authority=` 叶子会进入指纹,
    同一条断言自动变强 —— 那时它才是真的在比证书。
  - 附带修好一处不体面:内核此前带着 Go 编译器给的默认 `Identifier=a.out`(官方产物就是这样),
    现在构建链显式 `--identifier`,值为 `<bundle id>.<文件名>` = `com.aa.host.mihomo-darwin-arm64`。
    **从文件名派生而不为内核特判**:签名那步是个遍历,写死 `.mihomo` 只会让将来加进来的第二个
    内嵌可执行重新掉回 `a.out`。

- [x] **重签步骤在构建脚本内自动执行,手工零步骤**
  - 就是 `Scripts/build-app.sh` 里那个遍历(12 票已建,本票只给它补 `--identifier`)。
    `bash Scripts/build-app.sh` 一条命令出 `.app`,签名与重签全在里面;门禁每轮跑两遍(production / e2e)。
  - 手工步骤数 = 0。

- [x] **子进程红线复述进关于页/文档:仅子进程 + REST,永不进程内链接**
  - 原文(ADR 0007 提炼句,单一来源 = `MihomoKernelResource.subprocessBoundary`):
    > mihomo 内核仅以独立子进程运行,控制面仅走其外部接口(REST API / 配置文件)通信,永不进程内链接(含 c-archive/cgo 静态链接)。
  - 三处同源:关于页(经 `proxy.license` 取)、`proxy.license` 的 `subprocessBoundary` 字段、本票面。
  - 断言 APP10 验它**真的经能力面暴露**(而不是只活在注释里):判两个要害词「独立子进程」「永不进程内链接」,
    不整句比 —— 这条守的是语义没被削弱,不是逐字不动。

---

## 改动清单

| 文件 | 改了什么 |
|---|---|
| `Sources/PluginProxy/MihomoKernelResource.swift` | 补 `license` / `sourceURL`(由 `version` 派生)/ `licenseTextPath`(复用 `resourcePath`)/ `subprocessBoundary`。版本与出处的单一来源。 |
| `Sources/PluginProxy/PluginProxy.swift` | 新增能力 `proxy.license`(safe,`cliAlias ["proxy","license"]`)。纯静态资源信息,**不需要内核在跑**。 |
| `Sources/AAHostMacOS/AboutWindow.swift`(新) | `AboutWindowController` —— 独立可单独调用;`makeMenuItem()` / `show()`。14 票重建菜单直接取那一项。 |
| `Sources/AAHostMacOS/HostApp.swift` | 菜单加「关于 AA」项;`AppDelegate` 持有 controller(菜单项 target 是弱引用,不持有就点了没反应)。 |
| `Sources/AAHostTestKit/ProxyConformanceTests.swift` | 能力条数 11 → 12。 |
| `Scripts/build-app.sh` | 签内嵌可执行时显式 `--identifier <bundle id>.<文件名>`。 |
| `Scripts/check/app-bundle.sh` | 断言组 APP 6 → 10 条(APP7–APP10),含 ad-hoc「一致」口径的告示。 |
| `Scripts/check/bootstrap.sh` | 15 票增量说明;断言组 APP 条数注释同步。 |

`Sources/PluginProxy/Resources/LICENSE-mihomo-GPL-3.0.txt`(35149 字节)由主会话放入,
跟着既有的 `.copy("Resources")` 自动进资源 bundle 与 `.app` —— `build-app.sh` 一个字没改。

---

## 实测记录

**环境**:本机无 Xcode;Swift 6.1.2 独立工具链(`~/Library/Developer/Toolchains/swift-latest.xctoolchain`);
`codesign` 走 CLT;签名身份 `-`(ad-hoc)。

1. **内核签名标识符,改前 vs 改后**(同一份 `.app`,只差 `--identifier`):
   - 改前:`Identifier=a.out`(mihomo 官方产物带的 Go 默认值)
   - 改后:`Identifier=com.aa.host.mihomo-darwin-arm64`
   - 踩到的一个真坑:标识符本想写成 `$BUNDLE_ID.$(basename "$exe" | tr -c 'A-Za-z0-9.-' '-')`,
     但 `tr -c` 的补集包含换行,`basename` 的尾随换行会被换成 `-`,而它此时不再是「尾随换行」,
     `$( )` 不会剥掉 → 标识符平白多一个尾巴。改成 `printf '%s' "$(basename …)" | tr …` 才对。

2. **`.app` 内 Mach-O 逐个 `codesign -dvvv`**(production 档,3 个全部):
   ```
   Contents/MacOS/aahost                → Identifier=com.aa.host                    Signature=adhoc  TeamIdentifier=not set
   Contents/MacOS/aa                    → Identifier=aa-5555494453364e78…           Signature=adhoc  TeamIdentifier=not set
   …/PROJECT_AA_PluginProxy.bundle/Resources/mihomo-darwin-arm64
                                        → Identifier=com.aa.host.mihomo-darwin-arm64 Signature=adhoc  TeamIdentifier=not set
   ```
   三份**都没有 `Authority=` 行** —— 这就是上面那条「ad-hoc 无证书链」的实物证据。
   `Identifier` 三者各不相同且**本就该不同**,故它刻意不进一致性指纹(拿它比一致 = 要求所有二进制同名,是错的)。
   `Contents/MacOS/aa` 的 `Identifier=aa-5555…` 是 codesign 从文件名派生的默认值(未在本票范围内改动,记为小债)。

3. **GPL 全文随包完整**:
   `Sources/PluginProxy/Resources/LICENSE-mihomo-GPL-3.0.txt` 与
   `.app/Contents/Resources/PROJECT_AA_PluginProxy.bundle/Resources/LICENSE-mihomo-GPL-3.0.txt`
   两边 SHA-256 均为 `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`,35149 字节。
   门禁**现算现比**、两边都真读文件(不硬编码期望哈希,也不只判 `-f` 存在 —— 后者会被 0 字节同名文件骗过)。

4. **`aa proxy license --json` 经 UDS 真跑一次**(e2e 档 `.app`,直接 exec `Contents/MacOS/aahost`):
   ```json
   {"kernelVersion":"v1.19.28","license":"GPL-3.0","licenseTextAvailable":true,
    "licenseTextPath":"…/AA.app/Contents/Resources/PROJECT_AA_PluginProxy.bundle/Resources/LICENSE-mihomo-GPL-3.0.txt",
    "sourceURL":"https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.28",
    "subprocessBoundary":"mihomo 内核仅以独立子进程运行,控制面仅走其外部接口(REST API / 配置文件)通信,永不进程内链接(含 c-archive/cgo 静态链接)。"}
   ```
   注意 `licenseTextPath` 落在 `.app` **内** —— 与 12 票那条「资源 bundle 只能住 `Contents/Resources/`」的
   实测结论对上了:许可证与内核走的是同一条落点解析,不会出现「内核找得到、许可证找不到」的分叉。

5. **版本号单一来源的运行时证明**:`bootstrap.sh` 从 `MIHOMO-VERSION.txt` 解析出 `1.19.28`(正则剥掉了 `v`),
   Swift 常量按上游 tag 原样写作 `v1.19.28`。APP9 断言的期望值是显式拼回 `v` 的
   `"kernelVersion":"v$MIHOMO_VERSION"` —— 比子串包含严(子串会把 `1.19.280` 之类也算过)。

6. **未触碰用户自己的 mihomo**:全程只按仓库树内绝对路径 `pkill/pgrep`,从不裸名字。
   门禁里那条守卫(`bootstrap.sh` 的 `foreign_mihomo_pids` + `finalize.sh` 比对)两轮都是 PASS:
   `PASS: 未触碰仓库外的 mihomo 进程(跑前后一致: [553 ])`。
   `/usr/local/bin/mihomo` pid 553(启动于 8/3 23:07)自始至终没动过。

---

## 未做 / 已知缺口(如实)

1. **关于窗口的渲染未经人眼确认**(上面已标)。headless 门禁验到的是能力面与资源完整性,
   不是「窗口画出来了」。归 13/14 票。
2. **`Contents/MacOS/aa` 的签名标识符仍是 codesign 派生的 `aa-<hash>`**。本票只按票面动了内嵌内核那一步;
   给 `aa` 也补 `--identifier` 是一行的事,但那属于 13 票的签名仪式范围,不在这里顺手改。
3. **「签名一致」在 ad-hoc 下的强度有限**(反复说明如上)。真强度要等 13 票的开发证书。
4. **`licenseTextPath` 在许可证文件缺失时会 `fatalError`**(沿用 `resourcePath` 既有的强解包语义)。
   刻意保留:对 GPL 义务而言,「悄悄没带许可证却照常分发」比崩溃危险得多。
   `licenseTextAvailable` 守的是另一种情形(路径算得出、文件被人事后删了)。
