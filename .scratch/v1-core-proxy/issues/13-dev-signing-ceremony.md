# 13 — 开发级签名仪式（需用户在场）

**What to build:** 一次性开发环境仪式：开发签名就位（免费 Apple ID 开发证书；若免费证书能力不足，如实记录缺口与影响面），`.app` 以开发签名构建；首次运行完成 TCC 与通知授权点头——此后 UserNotifications 等需签名 API 不崩、日常开发不再被授权弹窗打断。公证凭据与 Developer ID 明确不在本票（无付费账号，挂 Phase 3 前置，见 spec 签名仪式收敛条）。

**Blocked by:** 12

**Status:** partially-done（可自动部分已落地；证书签发与 TCC/通知授权点头仍是人工项，**未做**）

**验证环:** 门禁 APP11（签名身份 seam fail-closed）+ 一次性实测（cdhash 敏感性、免费证书边界）+ 人工仪式（未做）。

---

## 范围变更：ad-hoc 定为 Phase 1 终态（2026-08-04，据本轮任务交待的用户裁决）

原票面假设「上免费开发证书」是 Phase 1 的一部分。**改为：ad-hoc 就是 Phase 1 的终态**，不上开发证书。

理由（每条都有 §「实测记录」里的数据支撑）：

1. **免费开发证书在本用途上买不到任何可观测的东西。** Phase 1 的分发面是本机自用 / 手动拷贝。
   实测：ad-hoc 与真证书**都过不了 Gatekeeper** —— `spctl` 判 reject 的原因是**缺公证票**
   （`syspolicy_check distribution` 只报一条 Fatal：`Notary Ticket Missing`），不是缺证书。
   而公证要付费 Developer ID，已明确挂 Phase 3。
2. **它唯一能买到的是「改代码后 TCC 授权不作废」**，代价是一条要维护的证书过期链路 + 装 Xcode
   （本机无 Xcode，且【未验证】免费证书是否只能从 Xcode 账号界面签发）。当「授权弹窗打断开发」
   真的疼起来再上，不为「看起来更正式」提前上。
3. **门禁已经把 seam 守住了。** 换证书那天只改一个 env 变量（`AA_CODESIGN_IDENTITY`），
   而 APP11 保证「打错身份 / 证书没装」时构建**明确失败**而不是静默回落 —— 推迟不留隐患。

据此，本票今晚只做**可自动的四件事**，两条需要真人在场的 checkbox **不打勾**。

---

## 逐条 checkbox 真实状态

- [ ] `.app` 带**开发签名**构建通过，签名信息可校验
      —— **不打勾。** 本机 `security find-identity -v -p codesigning` = `0 valid identities found`，
      一张证书都没有；未申请、未安装（本票明确不碰钥匙串）。
      **已经成立的是 ad-hoc 那半**：`.app` 构建通过、`codesign --verify --strict` 过
      （`valid on disk` + `satisfies its Designated Requirement`），门禁 APP1/APP3/APP8 每轮都在验。
      把这条读成「差一步」是错的 —— 差的是整个证书链路。
- [ ] 首次 TCC/通知授权完成，通知 API 冒烟调用不崩
      —— **不打勾。** 弹窗必须真人点；且门禁硬约束禁止启动 production 宿主（它会写真实
      `~/Library/Application Support/AA/`）。步骤已写成 runbook §5，**一步没做**。
- [x] 免费证书的能力边界（能签什么、不能签什么、有效期）记录在案
      —— 见 runbook §6：**实测**与**【未验证】**分两张表，有效期一栏**故意不写数字**（见下）。
- [x] 仪式步骤沉淀为可重复文档（换机/重装时照做）
      —— `docs/runbooks/signing-and-authorization.md`。

**新增（不在原票面，13 票实际交付的第一位）：**

- [x] 签名身份 seam 的 **fail-closed 行为进门禁**（APP11）——「以为签上了其实没签」这条事故路径被堵死。

---

## 实测记录 1：cdhash 敏感性（本票的核心数据，不进门禁）

**先纠正一个常见的错误说法**：「ad-hoc 下每次构建 cdhash 都变」——**不准确**。

四次构建（同一 SPM scratch，`.app` 各出到独立 `--output`），对比 `Contents/MacOS/aahost`
的字节 SHA-256 与 `.app` 的 CDHash：

| # | 动作 | aahost 字节 SHA-256 | AA.app CDHash |
|---|---|---|---|
| a | 基线构建 | `de071ec2d104378140acafbc673364d68a124c2aedd7d1cc8f7e4e3ac14f5352` | `4c95066adfc8125cde97f20efec265709a19c55b` |
| b | **零改动**再构建 | `de071ec2…f5352`（**与 a 逐字节相同**） | `4c95066adfc8125cde97f20efec265709a19c55b`（**与 a 相同**） |
| c | 只改一行注释 | `f52d5dfe6a92968607c25684788290b5bf3025c24bd7dc5b94d3b8558b0089f9` | `e9beb267023a3fc6e2a86458d4f43dfb7ddab1cb` |
| d | 注释**改回来** | `a8fa775a1b76c77523a83c209568332781a06c926abf14d1ffd6710ea3a51b17`（**≠ a**） | `cb9df5972f5d8727e3d2352e22fd9324bb596324` |

配套证据（同一批产物上取的）：

```
$ codesign -d -r- <a>/AA.app
# designated => cdhash H"4c95066adfc8125cde97f20efec265709a19c55b"     ← ad-hoc 的「身份」就是 cdhash 本身
$ codesign -d -r- <c>/AA.app
# designated => cdhash H"e9beb267023a3fc6e2a86458d4f43dfb7ddab1cb"
```

### 结论（三条，第三条是设计里没预料到的）

1. **重复构建是确定性的。** 没有任何改动时 SPM 无事可做、二进制没被重写，cdhash 一模一样。
   「每次构建都变」这个说法可以停掉了。
2. **任何代码改动（哪怕只是一行注释）都会换掉 cdhash**，从而换掉 ad-hoc 下的「身份」、
   让已授的 TCC/通知权限作废。准确的命题是这一条，不是第 1 条被否定的那个。
3. ⚠️ **改回来也回不去：d ≠ a，尽管源码字节完全相同。** 机制已定位：只要某个 TU 被重新编译，
   链接进可执行的 debug map（`N_OSO` stabs 条目）里带着 `.o` 文件的 **mtime**，而 mtime 必然变。
   证据是整条 OSO diff 只有一个条目不同：

   ```
   $ diff <(nm -pa a/…/aahost | grep ' OSO ') <(nm -pa d/…/aahost | grep ' OSO ')
   < 000000006a70fa29 …/AAHostMacOS.build/HostApp.swift.o
   > 000000006a710acd …/AAHostMacOS.build/HostApp.swift.o
   ```

   两个可执行大小完全相同，`cmp -l` 数出 **83 个字节**不同（= OSO 时间戳 + 因页哈希改变而变的嵌入签名）。

   **实践含义**：ad-hoc 下别指望「回滚代码就能拿回授权」。授权跟着「有没有重新编译过」走，
   不跟着「源码是不是同一份」走。这也意味着**本项目的构建不是可复现构建（reproducible build）**——
   与签名无关的一个独立事实，将来若要做 reproducible build，`ZERO_AR_DATE` / 去 debug map 是入口。

---

## 实测记录 2：免费证书能力边界（完整版见 runbook §6）

### 实测（本机跑过，可原样复现）

| 问题 | 实测结果 |
|---|---|
| 本机有无可用签名身份 | `0 valid identities found`（含免费的，一张都没有） |
| ad-hoc 能否通过严格校验 | **能**：`valid on disk` + `satisfies its Designated Requirement` |
| ad-hoc 能否过 Gatekeeper | **不能**：`spctl -a --type execute` → `rejected`（rc=3），`spctl --status` = `assessments enabled` |
| 到底缺什么 | `syspolicy_check distribution` 只报一条 Fatal：`Notary Ticket Missing`（**缺公证票，不是缺证书**） |
| 本地产物带不带 quarantine | 只有 `com.apple.provenance`，无 `com.apple.quarantine` |
| 打上 quarantine 会怎样 | `spctl` 结果不变；`codesign --verify --strict` **仍通过**（隔离标与签名有效性是两件事） |
| ad-hoc 能否带硬化运行时 | **能**：`flags=0x10002(adhoc,runtime)`（公证要的 `--options runtime` **可以先预演**） |
| ad-hoc 能否带时间戳 | rc=0 但**产物里没有时间戳**（无 CMS 容器）——**TSA 这条路径无法用 ad-hoc 预演** |
| 当前 `.app` 的 entitlements | **一个都没有** |

### 【未验证】（本机确认不了，**不要当事实引用**）

- 免费 Apple ID **能否**签发开发证书，以及是否**只能**从 Xcode 的 Accounts 界面签发
  （`developer.apple.com` 门户对免费账号是否开放）。这是维护者的当前理解，**未核实**：本机无 Xcode、
  未登录任何 Apple 账号。
- 免费证书 / provisioning profile 的**有效期**。网上流传多个数字，本票一个都没验证，
  故**此处与 runbook 里都不写任何数字**。要确认：装 Xcode 登录后看 Keychain Access 的有效期字段。
- 哪些 entitlement 需要付费账号。本项目当前一个 entitlement 都不用，现在不影响我们。
- 公证是否必须付费 Developer ID（挂 Phase 3）。可以肯定的只有上表那条：**当前产物缺公证票、Gatekeeper reject**。
- 被 quarantine 的 ad-hoc `.app` **双击**时会不会被拦：只验到 `spctl` 判定，没真的双击
  （门禁硬约束：production 宿主绝不由自动化启动）。

---

## 门禁增量：APP11（签名身份 seam 必须 fail-closed）

位置：`Scripts/check/app-bundle.sh`（本组已经在跑 `build-app.sh`，production 档 SPM scratch 此刻是热的，
新增这次构建的 `swift build` 是 no-op）。独立 `--output`（`$BUILD/app-failclosed`），不碰门禁在用的那两个 `.app`。

被测行为：`AA_CODESIGN_IDENTITY="AA-NONEXISTENT-IDENTITY-FOR-GATE"` 时构建必须明确失败：

```
FAIL: 签名内嵌可执行失败: …/mihomo-darwin-arm64
    error: The specified item could not be found in the keychain.
rc=1
```

四个判据缺一不可：① rc≠0；② 失败发生在签名步骤（日志含 `FAIL: 签名`）；③ 日志里出现那个身份串
（证明真拿它去签了、没偷偷换成 `-`）；④ 残留 `.app` 过不了 `codesign --verify --strict`。

⚠️ **判据④ 不是凑数的 —— 排查时最容易被骗的正是这里。** 实测：失败留下的残缺 `.app`，
`codesign -dv` 照样报 `Signature=adhoc` / `flags=0x2(adhoc)`，那是**链接器**自动加的 ad-hoc 签名
（arm64 上 `ld` 给每个可执行都签，否则内核不给执行）；内核那份则是 `flags=0x20002(adhoc,linker-signed)`
+ `Identifier=a.out`（上游原样，证明我们的重签根本没发生）。**只看「有没有签名」会被整个骗过。**
真正的区分点是 `--verify --strict` 失败（原话：`code has no resources but signature indicates they must be present`）
与 `Identifier` 停在 codesign 派生值（`aahost-5555494453…`）。

**耗时增量：约 1 秒**。两处实测：
- 单独跑这一条(热 scratch)：**1.16 s** —— `swift build` 是 no-op，失败发生在**第一个 `codesign` 调用**上，
  壳都没签到，所以既不重编也不多签。
- 整轮门禁：加这条之后两次干净跑 **119.30 s / 117.95 s**（`PASS=429 FAIL=0 rc=0`），
  与本票之前记录的基线 ~118 s（`PASS=428`）在同一波动范围内。

**门禁总数 428 → 429**，差值 +1 恰为本条。

---

## 12 票留下的债：已还（`Contents/MacOS/aa` 的签名标识符）

12 票只给 `.app` 内的 `aa` 做了 `codesign --sign`，**没给 `-i`**，于是它的标识符是 codesign 自己派生的
`aa-5555494453364e7889e631f083dd9d33a665cd1a`（文件名 + 路径派生的十六进制，实测原文）——
与 15 票修掉的内核 `a.out` 是同一类问题的两个面。

**本票顺手补上了**，判断依据:全仓库 grep 确认**没有任何断言依赖 `aa` 的标识符**
（APP8 的注释里明写「Identifier 刻意不进指纹」），所以补它不牵动任何断言。
实现上把标识符派生规则收成 `build-app.sh` 里的 `exe_identifier()` 函数、内嵌可执行遍历与 `aa` 两处共用
（写两遍必然漂）。补后 `.app` 内三个 Mach-O 的标识符：

| 文件 | Identifier | 由谁定 |
|---|---|---|
| `Contents/MacOS/aahost` | `com.aa.host` | 签壳时取 `CFBundleIdentifier`（本来就没掉进坑） |
| `Contents/MacOS/aa` | `com.aa.host.aa` | **13 票补的** |
| `…/Resources/mihomo-darwin-arm64` | `com.aa.host.mihomo-darwin-arm64` | 15 票补的 |

---

## 人要做什么（本票剩余的全部人工项）

| # | 事项 | 前置 | 做完后打勾 |
|---|---|---|---|
| 1 | 装 Xcode.app（若确认免费证书只能从 Xcode 账号界面签发） | 磁盘空间 + 时间 | —— |
| 2 | 登录 Apple ID、签发 Apple Development 证书 | 1 | —— |
| 3 | `AA_CODESIGN_IDENTITY="Apple Development: …" bash Scripts/build-app.sh` + 重跑门禁 | 2 | checkbox 1 |
| 4 | **双击** `.app`（走 LaunchServices，不是 exec），逐个点允许授权弹窗并记下是哪几个 | 3 | —— |
| 5 | 触发一次通知路径，确认不崩、通知真出现 | 4 | checkbox 2 |
| 6 | 顺手核实 runbook §6.2 的【未验证】条目（尤其有效期），回填进文档 | 2 | —— |

**1–2 与 4–5 之间没有强依赖**：ad-hoc 下也可以先做 4–5 走一遍仪式（授权会在下次改代码后作废，
但能验证「通知 API 在 ad-hoc 签名下崩不崩」这个真问题）。若只想验通知，**不必先装 Xcode**。

---

## 运行纪律（本票踩到并复现的一个坑，与签名无关但会让门禁莫名变红）

13 票的第 2 次门禁跑出过 `PASS=428 FAIL=1`，红的正是**「未触碰仓库外的 mihomo」那条守卫**：

```
FAIL: 仓库外的 mihomo 进程集合发生变化 —— 门禁可能误伤了用户自己的内核(before=[553 ] after=[553 3901 ])
```

**用户的 mihomo（pid 553）自始至终活着**，前后两次快照都有它；红的原因是 after 里**多**了一个 pid 3901。
定位到 3901 是**跑门禁的人自己开的另一个 shell** —— 它的命令行里出现了 `mihomo` 这个词
（当时在 `grep "仓库外的 mihomo" <日志>`）。守卫的判据是
`pgrep -fl mihomo | grep -v "$ROOT"`，`pgrep -f` 匹配的是**整条命令行**，不是可执行路径，
于是任何 argv 里带 `mihomo` 字样、又不在仓库树内的进程都会被算成「用户的 mihomo」。已复现：

```
$ bash -c 'grep "仓库外的 mihomo" /tmp/x.log >/dev/null; sleep 6' &
$ pgrep -fl mihomo
    553  /usr/local/bin/mihomo -d /Users/heqianbin/.config/mihomo
    5205 bash -c grep "仓库外的 mihomo" /tmp/x.log >/dev/null; sleep 6   ← 这个也被算进去了
```

**纪律：门禁运行期间不要开任何命令行里含 `mihomo` 字样的进程**（包括 `grep mihomo 日志`、
`ps | grep mihomo`）。要看日志等门禁跑完再看。

### 守卫最终**被改了**(主会话在实施之后动的手,连同它的代价一并记在这里)

实施阶段的结论是「不改」——理由是「收紧判据 = 削弱安全守卫,不该由签名票顺手做」。
**主会话不同意并改了**:误报率高的守卫会被人学会无视,那比守卫窄一点更危险;而且这条守卫本就是
**兜底网**,第一道防线(「每个 pkill 只盯仓库树内绝对路径」)一个字没动。

改法:`pgrep -f` 宽召回不变,再逐个按 `ps -o comm=` 筛。随后**双轴 CR 又抓到这次改动的三处问题,均已修**:

1. 🔴 **我引入了一条白送路径**(Standards 轴抓到,是硬性违规):`ps` 拿不到 comm 时被静默当成
   「不是 mihomo」丢掉。推演:跑前 `ps` 对活着的 553 瞬时失败 → 它不进跑前快照 → 若门禁随后真误杀了它
   → 跑后同样查不到 → 前后相等 → **PASS**。这恰恰破了我自己写在那个函数头上的规矩
   (「守卫自身出错要出哨兵,不许装作一个都没有」)。已加 `PS_ERROR` 哨兵:`ps` 失败但 `kill -0` 显示
   进程仍活 → 出哨兵 → `finalize.sh` 显式判 FAIL。
2. 🔴 **「更精确、不是更松」这句话不成立**(Spec 轴抓到)。确有一类变松:把 mihomo 二进制**改了名**
   (可执行名不含 mihomo)再配 mihomo 配置目录跑,旧 argv 判据抓得到、新判据放过。已在代码注释里如实写明。
3. `"$ROOT"*` 缺 `/` 边界,`<ROOT>-something/mihomo` 会被误判成仓库内(旧版同病)。已改 `"$ROOT"/*`。

另更正一处措辞:macOS 的 `ps -o comm=` 严格说是 **argv[0]**,不是内核记录的可执行真实路径
(进程可改写它)。本机实测 `ps -p 553 -o comm=` 给的是 `/usr/local/bin/mihomo`,够用,但不是防伪凭证。

**仍留给用户定夺**:要不要换更硬的判据(如比对可执行 inode / 用 `lsof` 核对配置目录),
以覆盖上面第 2 条那类改名内核。

---

## 交付物

- `Scripts/check/app-bundle.sh` —— 新增 APP11（签名身份 seam fail-closed），本组 10 条 → 11 条。
- `Scripts/build-app.sh` —— 标识符派生收成 `exe_identifier()`；`Contents/MacOS/aa` 补 `--identifier`（还 12 票的债）。
- `docs/runbooks/signing-and-authorization.md` —— 可重复的签名/授权 runbook（实测与【未验证】分区）。
- 本票面 —— 范围变更理由、cdhash 实测数据、免费证书边界、人工项清单。
