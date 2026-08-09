# Runbook：签名与首次授权仪式（换机 / 重装照做）

> 归属：13 票（分发工件）。**2026-08-05 按内核 bin 化后的新拓扑整篇重写**——旧版写的是
> `AA.app`（`aahost` + `aa` + 随包 GPL mihomo 二进制 + 内核重签），那三样东西已在 10 票退场。
>
> **本文只写本机真跑过的结论**；跑不了的一律标 `【未验证】` 并说明「要什么条件才能确认」。
> 凡是没标未验证的段落，都能用文中给出的命令原样复现。
>
> 实测环境快照（2026-08-05，全部为只读查询的原始输出）：
>
> | 项 | 命令 | 输出 |
> |---|---|---|
> | 系统 | `sw_vers` | macOS 15.7.8（24G824） |
> | 工具链 | `xcode-select -p` | `/Library/Developer/CommandLineTools`（**无 Xcode.app**） |
> | 签名身份 | `security find-identity -v -p codesigning` | `0 valid identities found` |
> | Gatekeeper | `spctl --status` | `assessments enabled` |

---

## 0. 现在要签的是什么（新拓扑）

| 分发物 | 签名形态 | 说明 |
|---|---|---|
| **`A2 Panel.app`**（菜单栏壳 **+ 内嵌内核**） | `Scripts/build-app.sh` 出包 + **ad-hoc**，**先内后外** | bundle id `com.a2.panel`；包里**恰好两个 Mach-O**：`Contents/MacOS/a2-panel`（壳）与 `Contents/Resources/a2`（内嵌内核 bin，面板引导安装时的执行器——14 票，[ADR 0012](../adr/0012-panel-self-sufficient-bootstrap.md)）。脚本的 APP8 是结构红线断言：**可执行清单对不上就是红**（多一个、少一个、挪了位置都算） |
| **`a2`**（内核 bin，**单文件渠道那一份**） | **不吃 .app 签名链** | 它是单文件下载分发的（[分发 runbook](distribution.md)）。arm64 上 `ld` 会给每个可执行自动加一层 linker-signed 的 ad-hoc 签名，那不是我们签的。**包里那一份是另一回事**：它随 bundle 一起被我们签，见 §3.4 |
| mihomo | **不分发** | ADR 0007 修订版：不随任何分发物打包，「内核重签入构建链」整条废除 |

新拓扑里**没有**这些东西了（旧版本文写过，一并作废）：包内的 CLI `aa`（a2 系不往包里塞 CLI，
面板也不提供「装 CLI 到 PATH」——[ADR 0012](../adr/0012-panel-self-sufficient-bootstrap.md) 第 7 条）、
`Bundle.module` 资源 bundle 落点、逐个 `--identifier` 的签名编排、`aa install-cli`。

**「先内后外」这条回来了**（14 票）：当年它是为随包 GPL 二进制立的，随那件事一起废除；现在为内嵌内核而回来，
理由与当年同构——包里有第二段代码，它必须在壳之前签，否则壳的资源封印盖的是一份还没签的东西。

## 0.1 ad-hoc 是 Phase 1 的**终态**，不是临时凑合

```bash
CODESIGN_IDENTITY="${AA_CODESIGN_IDENTITY:--}"   # Scripts/build-app.sh:缺省 '-' = ad-hoc
```

Phase 1 的分发面是「本机自用 / 手动拷贝」，ad-hoc 够用；真证书带来的收益（Gatekeeper 放行、
TCC 授权跨版本保留）要到对外分发时才兑现，那时需要的也不是免费开发证书，而是付费
Developer ID + 公证。**所以不要为了「看起来更正式」提前上开发证书** —— 它换不来分发能力，
只换来一条要维护的证书过期链路。

例外只有一条：**如果日常开发被 TCC / 通知授权弹窗反复打断到影响效率**，那时再上开发证书（见 §3），
理由是「减少重新授权次数」，不是「为了签名而签名」。

---

## 1. ad-hoc 到底签了什么（本机实测，2026-08-05）

```
$ codesign -dvvv "/tmp/cdhash-a/A2 Panel.app"
Executable=…/A2 Panel.app/Contents/MacOS/a2-panel
Identifier=com.a2.panel
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20400 size=13317 flags=0x2(adhoc) hashes=410+3 location=embedded
Hash type=sha256 size=32
CDHash=fa3485571565ea96846299ea2fba53126d003db4
Signature=adhoc
```

关键点：**没有 `Authority=` 行**（ad-hoc 根本没有证书链），`TeamIdentifier=not set`，
**不带任何 entitlement**（`codesign -d --entitlements -` 无输出）。

**ad-hoc 下的「身份」就是 cdhash 本身** —— 这条是后面所有授权失效结论的根，可以直接看到：

```
$ codesign -d -r- "/tmp/cdhash-a/A2 Panel.app"
# designated => cdhash H"fa3485571565ea96846299ea2fba53126d003db4"
```

**【未验证】** 真证书签出来的 Designated Requirement 形如
`identifier "com.a2.panel" and anchor apple generic and certificate leaf[…] = …`，**与二进制内容无关**——
这就是「真证书下改代码不掉授权、ad-hoc 下改代码就掉」的机理。本机 `security find-identity` 是
`0 valid identities found`，拿不到真证书，所以**只有 ad-hoc 那一半是实测的**；上了证书当天用同一条命令确认。

---

## 2. cdhash 什么时候会变：新拓扑下的实测（2026-08-05 重测）

四次构建（同一 SPM scratch，`.app` 各出到独立 `--output`），比 `Contents/MacOS/a2-panel` 的字节
SHA-256 与 `.app` 的 CDHash：

| # | 动作 | a2-panel 字节 SHA-256（前 16） | CDHash |
|---|---|---|---|
| a | 基线构建 | `8ad1bff39308da15` | `fa3485571565ea96846299ea2fba53126d003db4` |
| b | **什么都不改**再构建 | `8ad1bff39308da15`（**同 a**） | **同 a** |
| c | 只改一行**注释**后构建 | `8ad1bff39308da15`（**同 a**） | **同 a** |
| e | 改一行**代码**（窗口标题字符串）后构建 | `d1a3417861cdfb27` | `63f598551d74b48a632d8250ff49b9ee5f42da59` |
| f | 把那行代码**改回来**再构建 | `cdef841b60062b2f`（**≠ a**） | `3dca52d24cbdd457d666c8d05ba48733a2a06da0`（**≠ a**） |

三条结论：

1. **没有任何改动的重复构建是确定性的**（b = a）。「每次构建 cdhash 都变」是错的。
2. **改注释不会换掉 cdhash**（c = a）——⚠️ 这条与旧版本文的记录**相反**，是本次重测改写的：
   构建日志显示 `A2AboutWindow.swift` 确实被重新编译了，但产出的 `.o` 内容一模一样，于是链接步骤
   被跳过、可执行文件根本没被重写。（旧记录测的是 `aahost`，那个文件在可执行 target 自己身上，
   链接必然发生。）
3. ⚠️ **真改了代码之后，即使改回来 cdhash 也回不去**（f ≠ a，源码字节完全相同）。机理本次一并复验：

   ```
   $ diff <(nm -pa a/…/a2-panel | grep ' OSO ') <(nm -pa f/…/a2-panel | grep ' OSO ')
   20c20
   < 000000006a728b00 - 00 0001   OSO …/A2PanelMacOS.build/A2AboutWindow.swift.o
   > 000000006a72bad2 - 00 0001   OSO …/A2PanelMacOS.build/A2AboutWindow.swift.o
   ```

   整条 diff 只有这**一个** OSO 条目不同（debug map 里记着 `.o` 文件的 mtime，而 mtime 必然变）；
   两个可执行文件大小相同，`cmp -l` 数出 **81 个字节**不同（OSO 时间戳本身 + 因页哈希改变而变的嵌入签名）。

   **实践含义**：ad-hoc 下不要指望「回滚代码就能拿回授权」。授权按 cdhash 认，而 cdhash 跟着
   「有没有真的重新链接过」走，不是跟着「源码是不是同一份」走。

### 2.1 ⚠️ 14 票起：**每次出包 cdhash 都会变**（内嵌内核把上面的结论盖掉了）

`.app` 里嵌了内核 bin 之后，上面「什么都不改的重复构建是确定性的」那条**对整个包不再成立**。
本票现场三组实测（2026-08-09）：

| 实验 | 结果 |
|---|---|
| 同一份源码连编两次内核 bin（`bun build --compile`） | **字节不同**（`fbccf5a9…` vs `abf2cf56…`）——bun 的单文件产物**不是确定性构建** |
| 拿**同一份**内核 bin 出两次包 | CDHash **相同**（`095aaaaacfc718e9…`）——出包这一步本身是确定性的 |
| 换成**另一次编译出来的**同源内核 bin 出包 | CDHash **不同**（`b14bda7de905fca3…`），壳的源码一个字没动 |

机理：bundle 的资源封印（`_CodeSignature/CodeResources`）盖着 `Contents/Resources/a2` 的哈希，
而封印的哈希又进主可执行的 CodeDirectory——**内嵌 bin 换一个字节，`.app` 的 CDHash 就换一个**。
门禁 ②b 每次都恒重建内核 bin，所以**每一次跑门禁出的包，cdhash 都是新的**。

**实践含义两条**：

1. ad-hoc 下，TCC / 通知授权现在**每次重新出包就作废**（不只是"改了壳的代码才作废"）。
   这让 §0.1 那条例外（被授权弹窗打断到影响效率就上开发证书）从"大概不会发生"变成"很可能发生"。
2. 想复现同一个 cdhash，必须**复用同一份内核 bin**（`AA_KERNEL_BIN=<那份> bash Scripts/build-app.sh`），
   重编一次是拿不回来的——与 §2 结论 3 是同一类事实。

---

## 3. 从 ad-hoc 切到真开发证书：改什么

### 3.1 改动面只有一个变量

```bash
AA_CODESIGN_IDENTITY="Apple Development: 你的名字 (TEAMID)" bash Scripts/build-app.sh
```

`build-app.sh` 其余部分一个字不动。可用身份名从这条查（**只读**）：

```bash
security find-identity -v -p codesigning
```

### 3.2 三处已知的坑

1. **安全时间戳【未验证】**：真身份签名默认会去连 Apple 的 TSA。离线会失败，需要 `--timestamp=none`
   （开发用）或保证联网。
   ⚠️ 实测提醒：ad-hoc 下 `codesign --force --timestamp --sign - <bin>` 返回 **rc=0 却不产生任何时间戳**
   （ad-hoc 没有 CMS 容器可放）。**所以你无法用 ad-hoc 预演这条路径** —— TSA 能不能连上，只有真上证书那天才知道。
2. **公证要硬化运行时**：`--options runtime`。这一项在 ad-hoc 下**可以预演**：
   `codesign --force --options runtime --sign - <bin>` → rc=0，`flags=0x10002(adhoc,runtime)`。
   即硬化运行时与签名身份正交，可以先加上验证程序还跑不跑得起来，再上证书。
3. **别指望「签不上就退回 ad-hoc」**——也别接受那种行为。见 §4。

### 3.3 切换后必须重跑的核验

```bash
bash Scripts/check.sh   # ⑤ 步就是 build-app.sh:出包 + 先内后外签名 + APP1–APP11 核验
codesign -dvvv ".build/check/app/A2 Panel.app" | grep -E 'Authority|TeamIdentifier'
codesign -dvvv ".build/check/app/A2 Panel.app/Contents/Resources/a2" | grep -E 'Authority|TeamIdentifier'
```

上了真证书后，`APP7`（签名标识符）那条才真的在比证书链；ad-hoc 下它只能证明
「签了、且标识符是 `com.a2.panel`」，**不证明**「签名可被 Gatekeeper 接受」。
第二条命令是 14 票新增的：**内嵌内核 bin 也该有 `Authority=` 行**——它是包里的第二段代码，
换真身份那天不该只有壳被真签了（见 §3.4）。

### 3.4 内嵌内核 bin **随链先签**（14 票）

`Scripts/build-app.sh` 的签名段现在是两条 `codesign`，**顺序是硬的**：

```bash
codesign --force --sign "$CODESIGN_IDENTITY" "$APP/Contents/Resources/a2"   # ① 先签内嵌的内核 bin
codesign --force --sign "$CODESIGN_IDENTITY" "$APP"                         # ② 再签壳(bundle)
```

三条口径：

- **同一个身份**：两条都读 `AA_CODESIGN_IDENTITY`（缺省 `-` = ad-hoc）。换真证书**仍然只改这一个 env**，
  §3.1 那句话不变——不是"改一处变成改两处"。
- **不用 `--deep`**：Apple 已弃用它，而且它会把"哪一层没签上"糊成一句话。两条显式命令各自 fail-closed
  （任一条非零退出即 `exit 1`，见 §4）。
- **顺序反了会怎样**：先签壳、再往包里塞或改文件，资源封印当场对不上。这条**本机实测**过：
  出包之后改内嵌 bin 一个字节，`codesign --verify --strict` 立刻报
  `a sealed resource is missing or invalid` + `file modified: …/Contents/Resources/a2`，还原后又通过。
  **门禁的 APP6 因此顺带在验「包里那份内核没被人动过」**。

公证那天记得：`--options runtime` 对**两条**都要加（内嵌 bin 也是要被执行的代码）。这一条属【未验证】——
本机没有真证书，硬化运行时只在 ad-hoc 下预演过（§3.2 第 2 点）。

---

## 4. 签名身份 seam 必须 fail-closed（换证书那天最容易出的事故）

事故不是「签不上」，而是**「以为签上了，其实没签」**。`build-app.sh` 的签名步骤对 `codesign` 的
非零退出**立即 exit 1**（`FAIL: 签名 .app 失败: …`），不会留下一个"看起来签了"的包。

⚠️ **排查时别被这一点骗到**：失败留下的残缺 `.app`，`codesign -dv` 照样会报 `Signature=adhoc`、
`flags=0x2(adhoc)` —— 那是**链接器**自动加的 ad-hoc 签名（arm64 上 `ld` 给每个可执行都签，
否则内核不给执行），不是我们签的。同一现象在裸可执行上是 `flags=0x20002(adhoc,linker-signed)`。
**判「有没有真签上」不能只看有没有签名**，要看两条：

- `codesign --verify --strict <app>` 是否通过（= 门禁的 APP6）；
- `Identifier` 是不是 `com.a2.panel`（= APP7）。派生出来的默认标识符长得像 `a2-panel-5555494453…`。

> **旧版此处引用的 `Scripts/check/app-bundle.sh` 的 APP11（喂一个不存在的身份必须明确失败）**
> 随旧门禁整棵退场，**新门禁没有等价断言**——如实记为一条缺口：换真证书那天请手工跑一次
> `AA_CODESIGN_IDENTITY="NONEXISTENT" bash Scripts/build-app.sh`，确认它 exit≠0 且说明了原因。

---

## 5. TCC / 通知授权：人要做什么【人工项】

**这一段无法自动化**（TCC 弹窗必须真人点），是 5 条人工项里的第 3 条。

仪式步骤：

1. `bash Scripts/build-app.sh --output .build/app` → `.build/app/A2 Panel.app`。
2. **双击**启动（不是 `exec Contents/MacOS/a2-panel` —— 走 LaunchServices 才有完整的 TCC 归属）。
   `LSUIElement=true`，所以没有 Dock 图标，只在菜单栏出现。
3. 出现的授权弹窗**逐个点允许**，并记下是哪几个（V1 预期会碰到通知；Touch ID 确认视功能而定）。
4. 冒烟：起一个 daemon（`a2 service install`），让壳连上，触发一次 dangerous 确认，确认弹窗真的出现、
   点批准后命令退出码 0。

**对着 `com.a2.panel` 做**——旧 id `com.aa.host` 从未上过真证书、也从未授过权，10 票换 id 的代价恰好是零；
换回去或再改一次 bundle id，代价是**所有授权清零**。

### 授权会在什么时候失效（ad-hoc 的真实代价）

| 变化 | ad-hoc 下 | 真证书下 |
|---|---|---|
| 改**代码**后重新构建 | **授权作废**，要重点（cdhash 变了，见 §2） | 不受影响 |
| 源码回滚后重新构建 | **同样作废**（§2 结论 3） | 不受影响 |
| 只改注释 / 什么都不改，**且复用同一份内核 bin** | 不失效（§2 结论 1、2：可执行没被重写；§2.1 第二组实验） | 不受影响 |
| **重新出一次包**（门禁每次都恒重建内核 bin） | **授权作废**——内嵌 bin 的字节变了，资源封印跟着变，cdhash 也跟着变（§2.1） | 不受影响 |
| 改 `BUNDLE_ID` | **作废**，且是「换了个新应用」 | **同样作废** |

**【未验证】** TCC 数据库里存的是否**逐字**就是 §1 那条 Designated Requirement：读
`~/Library/Application Support/com.apple.TCC/TCC.db` 需要完全磁盘访问权限，且属用户隐私数据，本票没有去读。
上表是从「ad-hoc 的 DR 只含 cdhash」（**本机实测**）与「真证书的 DR 不含二进制内容」（**【未验证】**）
两条推出来的，机制方向可靠，但「TCC 具体存了哪一列」未经本机核对。

---

## 6. 免费 Apple ID 证书的能力边界

### 6.1 本机实测（可原样复现，2026-08-05 对 `A2 Panel.app` 重跑）

| 问题 | 命令 | 实测结果 |
|---|---|---|
| 本机现在有没有可用签名身份 | `security find-identity -v -p codesigning` | `0 valid identities found` —— **一张都没有**，包括免费的 |
| ad-hoc 能不能签 `.app` 并通过严格校验 | `codesign --verify --strict` | **能**（门禁 APP6 每次都在跑） |
| ad-hoc 能不能过 Gatekeeper | `spctl -a -vvv --type execute "A2 Panel.app"` | **不能**：`rejected`；`spctl --status` = `assessments enabled` |
| 本地构建的 `.app` 带不带 quarantine | `xattr -l` | 只有 `com.apple.provenance`，**没有** `com.apple.quarantine` |
| 当前 `.app` 带不带 entitlements | `codesign -d --entitlements -` | **不带任何 entitlement** |

一句话：**在「本机自用」这个用途上，ad-hoc 与免费开发证书没有可观测差别** —— 两者都过不了
Gatekeeper（缺的是公证票，不是证书），都能通过 `codesign --verify --strict`。免费证书唯一的实际收益
是 §5 那张表里「改代码后授权是否作废」那一行。

### 6.2 【未验证】—— 需要装 Xcode 或登录 Apple 账号才能确认，**不要当成事实引用**

- 免费 Apple ID **能否**签发开发证书，以及是否**只能**从 Xcode 的 Accounts 界面签发。
- 免费证书 / 其配套 provisioning profile 的**有效期**（网上流传多个数字，一个都没验证过，故此处不写数字）。
- 哪些 entitlement 需要付费账号。本项目当前**一个 entitlement 都不用**，所以这条现在不影响我们。
- 公证是否必须付费 Developer ID —— 已明确挂 Phase 3。可以肯定的只有 6.1 那条实测：**当前产物缺公证票，
  Gatekeeper 判 reject**。
- 被 quarantine 标记的 ad-hoc `.app` **双击**时会不会被 Gatekeeper 拦（只验到 `spctl` 的判定，
  没有真的双击 —— 那属 §5 的人工项）。

---

## 7. 换机 / 重装 checklist

1. 装官方独立 Swift 工具链到 `~/Library/Developer/Toolchains/`（判据是 `swift package dump-package` rc=0；
   `Scripts/check.sh` 会自动探测）。**不需要 Xcode.app**。
2. 装 bun（`curl -fsSL https://bun.sh/install | bash`）——内核是 TS，没有它跑不了门禁的 ①③④ 步；
   14 票起 **`.app` 出包也要它**（包里嵌的那份内核 bin 是它编的）。
3. `bash Scripts/check.sh` → 期望 `步 FAIL=0`、rc=0。这一步会连带把 `.app` 构建 + 内嵌内核 + 先内后外
   ad-hoc 签名 + **APP1–APP11** 跑一遍（第 11 条是 16 票加的：内嵌 bin 以一次性 `A2_HOME` 实跑
   `service status --json`，只读、不碰真环境）。
4. `bash Scripts/build-app.sh --output .build/app` → 双击 `.build/app/A2 Panel.app`，按 §5 走一遍授权仪式。
5. 只有当 §0.1 那条例外成立时，才按 §3 上开发证书。上了之后重跑第 3 步。

不需要做的事（别浪费时间）：申请证书、装 Xcode、`notarytool store-credentials` —— 前两项在 Phase 1
没有收益，第三项是 Phase 3 的前置。
