# Runbook：签名与首次授权仪式（换机 / 重装照做）

> 归属：13 票（开发级签名仪式）。**本文只写本机真跑过的结论**；跑不了的一律标 `【未验证】` 并说明
> 「要什么条件才能确认」。凡是没标未验证的段落，都能用文中给出的命令原样复现。
>
> 实测环境快照（2026-08-04，全部为只读查询的原始输出）：
>
> | 项 | 命令 | 输出 |
> |---|---|---|
> | 系统 | `sw_vers` | macOS 15.7.8（24G824） |
> | 工具链 | `xcode-select -p` | `/Library/Developer/CommandLineTools`（**无 Xcode.app**） |
> | 签名身份 | `security find-identity -v -p codesigning` | `0 valid identities found` |
> | Gatekeeper | `spctl --status` | `assessments enabled` |

---

## 0. 当前状态：ad-hoc 是 Phase 1 的**终态**，不是临时凑合

`Scripts/build-app.sh` 的签名身份走 env seam：

```bash
CODESIGN_IDENTITY="${AA_CODESIGN_IDENTITY:--}"   # 缺省 '-' = ad-hoc
```

Phase 1 的分发面是「本机自用 / 手动拷贝」，ad-hoc 够用；真证书带来的收益（Gatekeeper 放行、
TCC 授权跨版本保留）在 Phase 3 对外分发时才兑现，那时需要的也不是免费开发证书，而是付费
Developer ID + 公证。**所以不要为了「看起来更正式」提前上开发证书** —— 它换不来分发能力，
只换来一条要维护的证书过期链路。

例外只有一条：**如果日常开发被 TCC / 通知授权弹窗反复打断到影响效率**，那时再上开发证书
（见 §3），理由是「减少重新授权次数」，不是「为了签名而签名」。

---

## 1. ad-hoc 到底签了什么（实测）

对 `bash Scripts/build-app.sh --variant production` 的产物（下面这份是 13 票做 cdhash 实测时那一批构建里的
第 a 次，**CDHash 那一行只是样本** —— 它每次重新编译都会变，那正是 §2 要讲的事；其余各行是稳定的）：

```
$ codesign -dvvv <某次构建>/AA.app
Identifier=com.aa.host
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20400 size=11972 flags=0x2(adhoc) hashes=368+3 location=embedded
CDHash=4c95066adfc8125cde97f20efec265709a19c55b
Signature=adhoc
TeamIdentifier=not set
Sealed Resources version=2 rules=13 files=5
```

关键点：**没有 `Authority=` 行**（ad-hoc 根本没有证书链），`TeamIdentifier=not set`。
`.app` 里三个 Mach-O 的标识符（13 票补齐 `aa` 之后）：

| 文件 | Identifier | 由谁定 |
|---|---|---|
| `Contents/MacOS/aahost` | `com.aa.host` | 签壳时取 `CFBundleIdentifier` |
| `Contents/MacOS/aa` | `com.aa.host.aa` | `build-app.sh` 显式 `--identifier` |
| `…/Resources/mihomo-darwin-arm64` | `com.aa.host.mihomo-darwin-arm64` | 同上（替掉 Go 默认的 `a.out`） |

**ad-hoc 下的「身份」就是 cdhash 本身** —— 这条是后面所有授权失效结论的根，可以直接看到
（换个构建再跑一次，`H"…"` 里的值会跟着 cdhash 一起变，DR 的**形状**不变）：

```
$ codesign -d -r- <某次构建>/AA.app
# designated => cdhash H"4c95066adfc8125cde97f20efec265709a19c55b"
```

对比（**【未验证】** —— 本机 `security find-identity` 是 `0 valid identities found`，
拿不到真证书,下面这段是按 codesign 文档与通行做法写的**预期形状**,不是本机实测):真证书签出来的 Designated Requirement 形如
`identifier "com.aa.host" and anchor apple generic and certificate leaf[…] = …`，
**与二进制内容无关** —— 这就是「真证书下改代码不掉授权、ad-hoc 下改代码就掉」的机理。
**注意其中只有 ad-hoc 那一半是本机实测的**(`codesign -d -r-` 逐字给出 `cdhash H"…"`);
真证书那一半属【未验证】,上了证书当天用同一条命令确认。

---

## 2. cdhash 会不会变：实测数据（先破一个常见错误说法）

常听到的「ad-hoc 下每次构建 cdhash 都变」**不准确**。实测四次构建（同一 SPM scratch，
`.app` 各出到独立 `--output`），对比 `Contents/MacOS/aahost` 的字节 SHA-256 与 `.app` 的 CDHash：

| # | 动作 | aahost 字节 SHA-256（前 16） | AA.app CDHash |
|---|---|---|---|
| a | 基线构建 | `de071ec2d1043781…` | `4c95066adfc8125cde97f20efec265709a19c55b` |
| b | **什么都不改**再构建 | `de071ec2d1043781…`（**同 a**） | `4c95066adfc8125cde97f20efec265709a19c55b`（**同 a**） |
| c | 只改一行注释后构建 | `f52d5dfe6a929686…` | `e9beb267023a3fc6e2a86458d4f43dfb7ddab1cb` |
| d | 把注释**改回来**再构建 | `a8fa775a1b76c775…`（**≠ a**） | `cb9df5972f5d8727e3d2352e22fd9324bb596324` |

三条结论：

1. **没有任何改动的重复构建是确定性的** —— SPM 判定无事可做，二进制没被重写，cdhash 一模一样。
   「每次构建都变」是错的。
2. **只改一行注释也会换掉 cdhash**（因此换掉 ad-hoc 下的「身份」）。
3. ⚠️ **改回来之后 cdhash 也回不去**（d ≠ a，源码字节完全相同）。原因已定位到具体机制：
   只要某个 TU 被重新编译，链接进可执行的 **debug map（`N_OSO` stabs 条目）里带着 `.o` 文件的 mtime**，
   而 mtime 必然变。实测证据：

   ```
   $ diff <(nm -pa a/…/aahost | grep ' OSO ') <(nm -pa d/…/aahost | grep ' OSO ')
   < 000000006a70fa29 - 00 0001   OSO …/AAHostMacOS.build/HostApp.swift.o
   > 000000006a710acd - 00 0001   OSO …/AAHostMacOS.build/HostApp.swift.o
   ```

   整条 diff 只有这**一个** OSO 条目不同（两个文件大小相同，`cmp -l` 数出 83 个字节不同 ——
   OSO 时间戳本身 + 因页哈希改变而变的嵌入签名）。

   **实践含义**：ad-hoc 下不要指望「回滚代码就能拿回授权」。授权是按 cdhash 认的，而 cdhash
   跟着「有没有重新编译过」走，不是跟着「源码是不是同一份」走。

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

### 3.2 三处已知的坑（前两处记在 `build-app.sh` 顶部，第三处是 13 票新测的）

1. **安全时间戳【未验证】**：真身份签名默认会去连 Apple 的 TSA。离线会失败，需要 `--timestamp=none`（开发用）
   或保证联网。
   ⚠️ 实测提醒：ad-hoc 下 `codesign --force --timestamp --sign - <bin>` 返回 **rc=0 却不产生任何时间戳**
   （ad-hoc 没有 CMS 容器可放）。**所以你无法用 ad-hoc 预演这条路径** —— TSA 能不能连上，只有真上证书那天才知道。
2. **公证要硬化运行时**：`--options runtime`。实测这一项在 ad-hoc 下**是可以预演的**：
   `codesign --force --options runtime --sign - <bin>` → rc=0，`flags=0x10002(adhoc,runtime)`。
   即硬化运行时与签名身份正交，可以先加上验证程序还跑不跑得起来，再上证书。
3. **别指望「签不上就退回 ad-hoc」** —— 也别接受那种行为。见 §4。

### 3.3 切换后必须重跑的核验

```bash
bash Scripts/check.sh          # APP3 / APP8 会自动切到「真证书」判据(它们同时认两种输出形态)
codesign -dvvv .build/check/app-production/AA.app | grep -E 'Authority|TeamIdentifier'
```

上了真证书后，`APP8` 那条断言才真的在比证书叶子（ad-hoc 下它只能证明「没有未签名的、没有用别的身份签的」）。

---

## 4. 签名身份 seam 是 fail-closed 的（门禁 APP11 守着）

换证书那天最容易出的事故不是「签不上」，而是「以为签上了，其实没签」。所以门禁里有一条
（`Scripts/check/app-bundle.sh` 的 APP11）：喂一个不存在的身份，构建必须**明确失败并说明原因**。

实测行为：

```
$ AA_CODESIGN_IDENTITY="AA-NONEXISTENT-IDENTITY-FOR-GATE" bash Scripts/build-app.sh
   sign: …/mihomo-darwin-arm64  (identifier=com.aa.host.mihomo-darwin-arm64)
FAIL: 签名内嵌可执行失败: …/mihomo-darwin-arm64
    error: The specified item could not be found in the keychain.
$ echo $?
1
```

⚠️ **排查时别被这一点骗到**：那次失败留下的残缺 `.app`，`codesign -dv` 照样报 `Signature=adhoc`、
`flags=0x2(adhoc)` —— 那是**链接器**自动加的 ad-hoc 签名（arm64 上 `ld` 给每个可执行都签，否则内核不给执行），
不是我们签的。同一现象在内核上是 `flags=0x20002(adhoc,linker-signed)` + `Identifier=a.out`。
**判「有没有真签上」不能只看有没有签名**，要看：

- `codesign --verify --strict <app>` 是否通过（残缺产物实测报
  `code has no resources but signature indicates they must be present`，rc=1）；
- `Identifier` 是不是我们指定的那个（残缺产物是 codesign 派生的 `aahost-5555494453…`，不是 `com.aa.host`）。

---

## 5. TCC / 通知授权：人要做什么

**这一段是纯人工项，无法自动化**（TCC 弹窗必须真人点，且门禁禁止启动 production 宿主 ——
它会往真实 `~/Library/Application Support/AA/` 写东西）。

仪式步骤：

1. `bash Scripts/build-app.sh` → `.build/app/AA.app`。
2. **双击**启动（不是 `exec Contents/MacOS/aahost` —— 走 LaunchServices 才有完整的 TCC 归属）。
   `LSUIElement=true`，所以没有 Dock 图标，只在菜单栏出现。
3. 出现的授权弹窗**逐个点允许**，并记下是哪几个（V1 预期会碰到通知；网络/自动化视功能而定）。
4. 通知冒烟：触发一次会发通知的路径，确认不崩、通知真的出现。

### 授权会在什么时候失效（这是 ad-hoc 的真实代价）

| 变化 | ad-hoc 下 | 真证书下 |
|---|---|---|
| 改代码后重新构建 | **授权作废**，要重点（cdhash 变了，见 §2） | 不受影响 |
| 源码回滚后重新构建 | **同样作废**（§2 结论 3） | 不受影响 |
| 什么都不改、重复构建 | 不失效（cdhash 不变） | 不受影响 |
| 改 `BUNDLE_ID` | **作废**，且是「换了个新应用」 | **同样作废** |

【未验证】TCC 数据库里存的是否**逐字**就是 §1 那条 Designated Requirement（`cdhash H"…"`）：
读 `~/Library/Application Support/com.apple.TCC/TCC.db` 需要完全磁盘访问权限，且属于用户隐私数据，
本票没有去读。上表是从「ad-hoc 的 DR 只含 cdhash」(**本机实测**)与「真证书的 DR 不含二进制内容」
(**【未验证】**,见 §5 的更正)两条推出来的，
机制方向可靠，但「TCC 具体存了哪一列」未经本机核对。

> ⚠️ `BUNDLE_ID` 现在是 `com.aa.host`（品牌未定前的中性缺省）。品牌一旦定下大概率要改一次，
> **那次改动会把所有授权清零** —— 要和这份仪式一起重做，别在别的时机顺手改。

---

## 6. 免费 Apple ID 证书的能力边界

### 6.1 本机实测（可原样复现）

| 问题 | 命令 | 实测结果 |
|---|---|---|
| 本机现在有没有可用签名身份 | `security find-identity -v -p codesigning` | `0 valid identities found` —— **一张都没有**，包括免费的 |
| ad-hoc 能不能签 `.app` 并通过严格校验 | `codesign --verify --strict` | **能**：`valid on disk` + `satisfies its Designated Requirement` |
| ad-hoc 能不能过 Gatekeeper | `spctl -a -vvv --type execute AA.app` | **不能**：`rejected`（rc=3），`spctl --status` = `assessments enabled` |
| 缺什么才过不了 | `syspolicy_check distribution AA.app` | 只报一条 Fatal：`Notary Ticket Missing —— A Notarization ticket is not stapled to this application` |
| 本地构建的 `.app` 带不带 quarantine | `xattr -l AA.app` | 只有 `com.apple.provenance`，**没有** `com.apple.quarantine`（本地产物不打隔离标） |
| 打上 quarantine 会怎样 | 复制一份 → `xattr -w com.apple.quarantine …` | `spctl` 结果不变（仍 `rejected`）；`codesign --verify --strict` **仍然通过** —— 隔离标与签名有效性是两件事 |
| ad-hoc 能不能带硬化运行时 | `codesign --options runtime --sign -` | **能**，`flags=0x10002(adhoc,runtime)` |
| ad-hoc 能不能带时间戳 | `codesign --timestamp --sign -` | rc=0 但**产物里没有时间戳**（无 CMS 容器） |
| 当前 `.app` 带不带 entitlements | `codesign -d --entitlements -` | **不带任何 entitlement** |

一句话：**在「本机自用」这个用途上，ad-hoc 与免费开发证书没有可观测差别** ——
两者都过不了 Gatekeeper（缺的是公证票，不是证书），都能通过 `codesign --verify --strict`。
免费证书唯一的实际收益是 §5 那张表里「改代码后授权是否作废」那一行。

### 6.2 【未验证】—— 需要装 Xcode 或登录 Apple 账号才能确认，**不要当成事实引用**

- 【未验证】免费 Apple ID **能否**签发开发证书，以及是否**只能**从 Xcode 的 Accounts 界面签发
  （`developer.apple.com` 门户是否对免费账号开放证书签发）。本机无 Xcode、未登录任何 Apple 账号，
  无法确认。这是维护者的当前理解，**不是核实过的结论**。
- 【未验证】免费证书 / 其配套 provisioning profile 的**有效期**。网上流传多个数字，本票一个都没验证过，
  故此处不写任何数字。要确认：装 Xcode 登录后看 Keychain Access 里证书的有效期字段。
- 【未验证】哪些 entitlement 需要付费账号（如 iCloud / Push / App Groups）。本项目当前**一个 entitlement 都不用**
  （见 6.1 实测），所以这条现在不影响我们；将来真要加 entitlement 时再验。
- 【未验证】公证（notarization）是否必须付费 Developer ID —— 已明确挂 Phase 3，本票不碰。
  可以肯定的只有 6.1 里那条实测：**当前产物缺公证票，Gatekeeper 判 reject**。
- 【未验证】被 quarantine 标记的 ad-hoc `.app` **双击**时会不会被 Gatekeeper 拦。本票只验到 `spctl` 的判定，
  没有真的双击启动（门禁硬约束：production 宿主绝不由自动化启动，它会写真实用户目录）。

---

## 7. 换机 / 重装 checklist

1. 装官方独立 Swift 工具链到 `~/Library/Developer/Toolchains/`（`Scripts/check/bootstrap.sh` 会自动认到；
   判据是 `swift package dump-package` rc=0）。**不需要 Xcode.app**。
2. `bash Scripts/check.sh` → 期望 `FAIL=0`、rc=0。这一步会连带把 `.app` 构建 + ad-hoc 签名 + APP11
   的 fail-closed 断言全跑一遍。
3. `bash Scripts/build-app.sh` → 双击 `.build/app/AA.app`，按 §5 走一遍授权仪式。
4. 只有当 §0 那条例外成立时，才按 §3 上开发证书。上了之后重跑第 2 步。

不需要做的事（别浪费时间）：申请证书、装 Xcode、`notarytool store-credentials` —— 前两项在 Phase 1 没有收益，
第三项是 Phase 3 的前置。
