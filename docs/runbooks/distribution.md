# Runbook：分发、安装与卸载（V1）

> 归属：13 票（分发工件）。依据：[ADR 0007](../adr/0007-mihomo-subprocess-gpl-compliance.md)（修订版：
> mihomo 外部安装 + GPL 义务落 `a2 about`）、[ADR 0008](../adr/0008-kernel-bin-ui-optional.md)（内核 bin 化、
> 显式安装、永不隐式拉起）、[ADR 0009](../adr/0009-kernel-platform-scope.md)（macOS + Linux 当下承诺）。
>
> **本文只写本仓库里真跑过的东西**；跑不了的一律标 `【人工项】` 并说明缺什么条件。
> 最大的一条：**发布渠道尚未确定**——仓库无 remote、无对象存储、无 Releases 页。安装脚本对此
> 的处置不是留一个假地址，而是当场失败并给出两条明路（见 §3.1）。

---

## 0. V1 的分发形态（一句话）

| 分发物 | 形态 | 谁需要它 |
|---|---|---|
| 内核 bin `a2` | **单文件**，各平台一个（macOS/Linux × arm64/x64） | 所有人（它是唯一必需件） |
| `install.sh` | curl 一条命令：探测平台 → 下载 → 校验 → 落 PATH | 想省事的人（不用它也能装） |
| `A2 Panel.app` | **自带内核的完整包**（zip，约 24.5MiB）：菜单栏壳 + 内嵌的内核 bin | mac 用户——尤其是**不想开终端**的人；dangerous 确认弹窗也在这里 |
| `NOTICE-external-programs.txt` | 外部程序声明（`a2 about` 的输出原样落盘） | **法律义务，必带** |
| `LICENSE-mihomo-GPL-3.0.txt` | GPL-3.0 全文离线副本 | **法律义务，必带** |
| `a2-release.json` | 发布元数据：版本、各工件 SHA-256、**mihomo 锁定版** | 安装脚本、以及想手动核对摘要的人 |

**不在分发物里的东西**：mihomo 二进制（ADR 0007 修订版：不随任何分发物打包，由 `a2 mihomo install`
从官方渠道取）、launchd/systemd 单元（内核自己写，见 §5）、任何 shell 配置修改。

**两条渠道各走各的**（[ADR 0012](../adr/0012-panel-self-sufficient-bootstrap.md)）：`.app` 里那份内核 bin
是**面板引导安装用的执行器**，不是 CLI 分发——面板不会把任何东西放进 PATH。要在终端里敲 `a2` 的人走单文件
渠道（§2.1–§2.3），两条都要的人机器上会有两份 bin（PATH 一份、`~/.a2/bin` 一份），各自显式升级。

---

## 1. 组装一个发布包

```bash
# 默认平台（darwin-arm64 + linux-x64），产物落 .build/release/
bash Scripts/release-assemble.sh

# 用已经编译好的产物（快；门禁的 kernel/dist/a2 就能直接用）
bash Scripts/release-assemble.sh --bin darwin-arm64=kernel/dist/a2 \
                                 --bin linux-x64=kernel/dist/a2-linux-x64

# 带上菜单栏壳（14 票起它是自带内核的完整包，出包本身要 swift + bun 两条工具链）
bash Scripts/build-app.sh --output .build/app
bash Scripts/release-assemble.sh --app ".build/app/A2 Panel.app"
```

脚本做五件事，每件都有理由：

1. **编译或收拢各平台 bin**（`bun build --compile --target=…`）。平台表的唯一来源是
   `kernel/src/release/manifest.ts::KERNEL_TARGETS` —— 脚本经 `kernel/scripts/release-targets.ts`
   读它，绝不在 shell 里再写一遍（两处手写必然漂，而漂的后果是元数据里的资产名与真正落盘的文件名对不上）。
2. **跑 `a2 about` 落成 `NOTICE-external-programs.txt`**。声明文本不是手抄的：抄一份的那一刻它就开始与 bin 漂移。
3. **算 SHA-256、写 `a2-release.json`**（`kernel/scripts/render-release-manifest.ts`）。
4. **自检**：用**包里那个 bin** 跑一次 `a2 about --json`，确认它看得见随包的两份静态文本。
   少拷一份声明的发布包在这里就停，而不是发出去之后才发现。
5. **面板包的内嵌内核对账**（14 票）：`.app` 里嵌着一份内核 bin，于是一个发布包里有了**两处内核**。
   版本不是抄的——脚本**解开 zip、拿包里那份 bin 跑一次 `version`**，写进元数据；自检时**再解一遍最终那个
   zip、再跑一次**，与元数据字段、与单文件那份三处对账。两版内核的发布包会让用户装到哪一版全看他点了哪里。

三条 fail-closed 的结构约束写在 schema 里（`ReleaseManifestSchema`），不是写在注释里：
**声明文本与 GPL 全文各恰好一份**、**不认识的文件不许混进发布包**、**面板包必须记下内嵌内核的版本且与本次
发布同版**。任一条不满足，元数据就生成不出来。

### 1.1 平台与实测状态

| 平台键 | 资产名 | 状态 |
|---|---|---|
| `darwin-arm64` | `a2-darwin-arm64` | 本机原生编译，门禁每次都在跑 |
| `linux-x64` | `a2-linux-x64` | 13 票现场交叉编译通过（95MiB，`file` 报 `ELF 64-bit LSB executable, x86-64`，魔数 `7f 45 4c 46`）。**本机跑不了它**——只验"能产出 + 文件头对"，实机运行属【人工项】 |
| `darwin-x64` / `linux-arm64` | — | 平台表里有，**默认不产出**：本机没下过那两个目标运行时，也没有任何实测背书。要发就显式 `--targets`，并在发之前找一台真机跑一次 |

### 1.2 发布元数据的形状

```jsonc
{
  "schema": "a2-release/1",          // 安装脚本据它判断读不读得懂
  "product": "a2",
  "version": "0.1.0",                // 问 bin 自己要的（a2 version），不是手填
  "generatedAt": "2026-08-05T…Z",
  "channel": { "base": "…", "status": "undecided|configured", "note": "…" },
  "mihomo": {                        // 06 票安装档的版本源
    "lockedVersion": "v1.19.28",
    "license": "GPL-3.0",
    "source": "https://github.com/MetaCubeX/mihomo",
    "releases": "https://github.com/MetaCubeX/mihomo/releases",
    "licenseUrl": "https://www.gnu.org/licenses/gpl-3.0.txt",
    "bundled": false                 // 恒 false：我们不分发它的二进制
  },
  "artifacts": [
    {"name":"a2-darwin-arm64","kind":"kernel-bin","platform":"darwin-arm64","sha256":"…","bytes":64304738},
    // 面板包多一个字段：包里嵌的那份内核 bin 自报的版本（跑出来的，不是抄的；必须 = 上面的 version）
    {"name":"A2-Panel-0.1.0-macos.zip","kind":"panel-app","platform":"darwin","embeddedKernelVersion":"0.1.0","sha256":"…","bytes":24554183}
  ]
}
```

**每个工件恰好一行**是与安装脚本的格式约定（那是个 POSIX sh 脚本，没有 jq —— 装 a2 之前不该先装一个
JSON 解析器）。这条约定有断言钉着（`kernel/test/release-manifest.test.ts`）。

---

## 2. 装（四条路，选一条）

> **§2.0 是 mac 上给「只想点图标的人」的路；§2.1–§2.3 是 CLI 渠道**（要在终端里敲 `a2` 的人走这三条）。
> 「装完记得敲 `a2 service install`」这句口径**只属于 CLI 渠道**——走 §2.0 的人不需要开终端。

### 2.0 mac：下载 `.app`，点一下（**不需要终端**）

```
1. 下载 A2-Panel-<版本>-macos.zip → 双击解压 → 把「A2 Panel.app」拖进「应用程序」
2. 打开它：菜单栏出现图标（LSUIElement，没有 Dock 图标）
   首次打开且内核还没装时，会弹一次说明框：装什么、怎么卸、「安装并启动」/「稍后」
3. 点「安装并启动」——面板经**包里那份内核 bin** 装上 launchd 用户服务 com.a2.kernel 并起起来
```

这条路径的四条口径（[ADR 0012](../adr/0012-panel-self-sufficient-bootstrap.md)）：

- **不隐式**：壳不会自己装、自己起。系统状态只因**你那一次点击**而改变——与 CLI「永不隐式拉起」
  （[ADR 0008](../adr/0008-kernel-bin-ui-optional.md) 第 6 条）是同一条边界，只是显式发起的入口多了一个。
  选「稍后」就不再纠缠，菜单项常驻，想装随时点。
- **不进 PATH**：面板不提供「装 CLI」，不写 shell 配置，不建 symlink。想要终端里的 `a2` 请另走 §2.1–§2.3。
- **服务不指向 `.app`**：unit 指的是 `~/.a2/bin/a2` 的**拷贝**。所以 `.app` 可以随便挪位置、改名、删掉，
  服务照跑；**反过来说，删掉 `.app` 不会卸掉服务**（怎么卸见 §4）。
- **升级仍然显式**：换了新版 `.app` 之后，面板发现版本不一致才提示「升级内核」，**点了才升**；没有静默更新。

**落地状态（如实）**：三票齐了，这条路径**代码上已经点得动**。

- 14 票交付**包**：`.app` 里真的嵌着当前这版内核；
- 15 票交付**内核侧机制**：`service install --copy-to-home`、`service status` 的 `binPath`；
- 16 票交付**面板侧引导**：首启说明框（触发判据是纯函数，四输入全组合有断言）、
  菜单的「安装并启动内核 / 启动内核 / 升级内核 vX→vY」与「高级 → 停止并卸载内核服务」（带确认），
  执行器只发 [ADR 0012](../adr/0012-panel-self-sufficient-bootstrap.md) 那四条白名单命令、只读机读 JSON。

门禁 ⑤ 步每次都在验：恰两个可执行、内嵌 bin 自报版本 = 本次构建的内核版本、arm64 单架构，
外加 **APP11**——内嵌 bin 以一次性 `A2_HOME` 实跑一次 `service status --json`（**只读**），
证明"面板将要调的第一条命令"在包内真的可用。

**门禁验不到的那一段，如实说**：门禁**从不**真的装服务（`install` / `uninstall` 会动 launchd，
那只归产品运行期用户那一次点击）。所以「点下去真的装上了、菜单真的跟着变、
`.app` 挪走之后服务照跑」这一串，仍要人在真机上走一遍——已列入 §8 的人工项。

### 2.1 curl 一条命令（有发布渠道时）

```bash
curl -fsSL <发布渠道>/install.sh | sh
```

### 2.2 已经有发布包（本地目录 / 内网 / 离线）

```bash
A2_RELEASE_BASE=/path/to/release sh install.sh
A2_RELEASE_BASE=https://你的地址/a2 sh install.sh
```

### 2.3 只下单文件（**根本不需要脚本**）

```bash
chmod +x a2-darwin-arm64 && mv a2-darwin-arm64 ~/.local/bin/a2
a2 about            # 读许可与外部程序声明
a2 service install  # 装成系统托管的常驻服务（**CLI 渠道**的口径；走 §2.0 的人不敲这条）
```

脚本只是省事，不是必需 —— 内核就是一个单文件，拷到 PATH 上就完事了。

---

## 3. 安装脚本的口径（每条都有断言：`kernel/test/install-script.test.ts`）

| 口径 | 定的是什么 | 为什么 |
|---|---|---|
| **PATH 落点** | 默认 `~/.local/bin`；`--dir` 或 `A2_INSTALL_DIR` 覆写 | 用户目录、**不要 sudo**。`/usr/local/bin` 在新 mac 上默认不存在且要管理员权限，而一个 `curl \| sh` 的脚本去要 sudo 是最不该有的姿势 |
| **不改 shell 配置** | 落点不在 PATH 时**打印**该加哪一行，绝不替用户写 rc 文件 | 一条命令悄悄改了你的 shell 配置，是最难排查的一类"我的环境怎么变了" |
| **校验** | 资产 SHA-256 来自元数据，对不上就一个字节都不落盘 | 它是要被 `curl \| sh` 的东西 |
| **自检** | 落位前先 `a2 version` 跑一次 | 连自报版本都做不到的东西不该进你的 PATH |
| **原子落位** | 先写同目录临时名再 `mv` | 替换正在被执行的 bin 也不会撕成两半 |
| **幂等** | 同版本重跑：**不下载**、不改动、退出 0，指引照打 | 重跑一条安装命令不该有任何代价 |
| **升级永远显式** | = **显式重跑脚本**（或直接换掉那个单文件） | **没有静默更新**：不留定时任务、不后台自查版本（[ADR 0006](../adr/0006-local-first-no-cloud.md) 暂缓清单）。同一句口径另有两处落点——`a2 about` 的 `upgrade` 字段与安装脚本结束时的提示，**三处各有断言**（`kernel/test/release-manifest.test.ts` ▸ 三处落点都在文） |
| **不碰系统托管** | 装完只**打印** `a2 service install`，绝不替你 launchctl | 系统状态的改变永远由用户显式发起（ADR 0008 第 6 条）。§2.0 那条路径同一条边界：面板也不自己装，是**你点的**（[ADR 0012](../adr/0012-panel-self-sufficient-bootstrap.md) 第 2 条） |

### 3.1 【人工项】发布渠道未定

默认的 `A2_RELEASE_BASE` 是一个 **`.invalid` 占位地址**（RFC 2606 保留域，永远解析不了）。
不给 `--base` / `A2_RELEASE_BASE` 时脚本**当场失败**并给出两条明路（本地包 / 直接下单文件），
而不是去连一个看起来能用、点下去 404 的假地址。

渠道定下来那天要改两处（有断言逼着同时改）：
`kernel/src/release/manifest.ts::RELEASE_CHANNEL_PLACEHOLDER` 与 `Scripts/install.sh` 的 `DEFAULT_RELEASE_BASE`。

### 3.2 磁盘占用

| 东西 | 大小 | 落在哪 |
|---|---|---|
| `a2` 单文件 | 60–95MiB（内置完整 Bun 运行时） | 你指定的 PATH 目录 |
| mihomo（**装了才有**） | 约 42MiB | `<A2_HOME>/mihomo/`，由 `a2 mihomo install` 下载 |
| 插件工件 | 每个几 KB~几百 KB | `<A2_HOME>/plugins/`（单文件工件 + `plugins.json`，**没有 node_modules**） |
| 日志、订阅、系统代理快照 | 小 | `<A2_HOME>/` 下 |

---

## 4. 卸载（顺序有讲究）

```bash
a2 proxy off              # 还原系统代理到接管前（唯一的还原入口）
a2 service uninstall      # 停掉并移除 com.a2.kernel
a2 mihomo uninstall       # 停掉并移除 a2 自管的那份 mihomo（不动你自己装的）
sh install.sh --uninstall # 删掉 bin
rm -rf ~/.a2              # 可选：插件、订阅、日志、a2 自管的 mihomo 目录全在这里
```

**顺序不是建议，是硬约束**：上面前三条的执行者正是 `a2` 自己 —— bin 删了就没有工具能收拾它们了。
所以 `install.sh --uninstall` 会**先看后删**：只要 `~/Library/LaunchAgents/com.a2.*.plist`、
`~/.config/systemd/user/com.a2.*.service` 或 `<A2_HOME>/system-proxy.json` 还在，它就**拒绝删 bin**
并把该先跑的命令打出来。这些判据全是**文件在不在**，脚本不调用任何 supervisor。

### 4.1 走 §2.0 装的（面板引导那条路）

⚠️ **删掉 `.app` 不会卸掉服务**——这正是「unit 指向 `~/.a2/bin/a2` 拷贝」的直接后果
（[ADR 0012](../adr/0012-panel-self-sufficient-bootstrap.md) 第 4 条：换来的是挪包/删包不断服）。
卸载与安装**对等**，从面板里点就行：

```
面板菜单 →「高级」→「停止并卸载内核服务」（带确认弹窗）
```

它走的是与安装同一条白名单命令（`service uninstall`），**只拆 unit**。剩下的东西按需自己清：

```bash
rm -rf ~/.a2                    # 那份拷贝的 bin、插件、订阅、日志、a2 自管的 mihomo 都在这里
rm -rf "/Applications/A2 Panel.app"
```

留下 `~/.a2` 是**有意的**：数据同侧的东西不该被一次点击带走——与 `install.sh --uninstall`
「先看后删」是同一种姿势。若你还用系统代理/mihomo，先按上面 §4 的前三条顺序收拾干净再删。

（面板本身除 TCC 授权外不写任何系统状态；它装出来的那个 launchd 服务是**你点出来的**，按上面卸。）

---

## 5. 换了 bin 的位置怎么办

`a2 service install` 写进 unit 的是**当时那个 a2 的绝对路径**。把 bin 挪了位置（或版本号进了路径），
老 unit 会指向一个不存在的文件。

```bash
a2 service install   # 幂等，会把 unit 收敛到新位置
```

**分发物里不预置任何 unit 文件** —— `~/Library/LaunchAgents` 与 `~/.config/systemd/user` 是内核自己写的。

---

## 6. GPL 义务在分发链里的位置

- **必带两份静态文本**：`NOTICE-external-programs.txt`（`a2 about` 的输出）与
  `LICENSE-mihomo-GPL-3.0.txt`。少一份，`a2-release.json` 就生成不出来（§1 的结构约束）。
- **权威落点是命令行**：`a2 about` —— 不依赖 daemon、不依赖任何 UI，Linux 无头端与 mac 终端一样读得到。
- **菜单栏壳的关于页**是同一份声明的**可选呈现面**，不是义务落点。14 票起 `.app` 里还嵌着内核 bin
  本身，也就是说那份声明的**产出者**就在包里（`Contents/Resources/a2 about`）——但义务落点的口径不变，
  仍是命令行那条。**没有新增任何 GPL 二进制**：mihomo 依旧不随任何分发物打包。
- **我们不分发 GPL 二进制**：mihomo 由 `a2 mihomo install` 从官方渠道取，锁定版写在发布元数据里。
  「内核重签校验」整条已废除（前提随不随包分发一并消失）。

---

## 7. 后续渠道备忘（V1 明确不做）

| 渠道 | 结论 | 真要做时需要什么 |
|---|---|---|
| **Homebrew Formula** | **不做**（spec 分发节：列后续渠道备忘） | 一个稳定的、带版本号与摘要的公开下载地址（= §3.1 那件事先解决）；tap 仓库；每次发版更新 formula 的 `url`/`sha256`。收益是 `brew install` 的熟悉度，代价是多一条要跟着发版走的链路 —— 在只有单文件的阶段不划算 |
| GitHub Releases | 候选（渠道未定的最可能落点） | remote 仓库 + 发版流程；`install.sh` 只需 `A2_RELEASE_BASE` 指过去 |
| Sparkle 自更新 | 只适用于 `.app`，且**必须用户确认**（不做静默） | EdDSA key、appcast；`a2` bin 的升级永远是显式命令，不进这条链 |
| 包管理器（apt/dnf/AUR） | 远景 | 各自的打包规范；先要有稳定渠道与版本节奏 |
| App Store | 排期外（暂缓清单） | 沙箱与 launchd 托管的冲突要先解决 |

---

## 8. 【人工项】清单 —— **分发相关的完整并集**

> 这一节是**唯一一份齐的**：13 票之前，这些条目散在四处（本文 §7 的渠道备忘、签名 runbook §4、
> 路线图 Phase 1 的 5 条表、以及各票 nightlog）。**明早验收按这一份走**；每条都注了原始落点，
> 要追出处照着翻即可。
>
> 与路线图那 5 条人工项的关系：第 3、4、5 条是**同一件事的两处登记**（那 5 条属 Phase 1 遗留），
> 其余是 13 票落地后才出现的（**#10、#11 是 14 票「面板自足」带来的新条目**）。别重复计数。

| # | 事情 | 缺什么条件 / 谁来做 | 原始落点 |
|---|---|---|---|
| 1 | **确定发布渠道**，把 `RELEASE_CHANNEL_PLACEHOLDER`（TS）与 `DEFAULT_RELEASE_BASE`（`install.sh`）两处占位符改掉 | 一个真实的托管位置（remote / 对象存储 / Releases）。两处有对账断言逼着同时改 | 本文 §3.1 |
| 2 | **Linux 实机跑一遍**：装、`a2 service install`（systemd user）、`a2 mihomo install`、旗舰链 | 一台 Linux 机器。交叉编译产物已能产出且 ELF 文件头正确，但**本机跑不了它** | 本文 §1.1；路线图「Linux 口径」 |
| 3 | 真开发者证书签 `A2 Panel.app` + 公证 | 付费 Developer ID；换身份只改 `AA_CODESIGN_IDENTITY` 一个 env | [签名 runbook](signing-and-authorization.md) §3；路线图 5 条之第 1、2 条 |
| 4 | 首次 TCC / 通知授权（**对 `com.a2.panel`**） | 真人双击 `.app` 点弹窗 | [签名 runbook](signing-and-authorization.md) §5；路线图 5 条之第 3 条 |
| 5 | 在干净机器上装一次**真 mihomo** 跑旗舰链 | 一台没跑着用户自己 mihomo 的机器（本机那份是施工红线，绝不触碰） | `kernel/test/swift-parity-map.md` 10 票 G 组；路线图 Phase 1 判据 3 的「缺口」 |
| 6 | 发布前冒烟 checklist（装 / 升级 / 回滚 / 卸载各走一遍） | 上面 1、2 就位之后 | 路线图 Phase 3 |
| 7 | **换证书那天**手工跑一次 `AA_CODESIGN_IDENTITY="NONEXISTENT" bash Scripts/build-app.sh`，确认它 exit≠0 且说明了原因 | 旧门禁里那条「签名身份 seam 必须 fail-closed」的断言随旧引擎退场，**新门禁没有等价断言**（⚠️ 别与新门禁的 APP11 混淆——同号不同事：新的那条验的是内嵌 bin 跑不跑得动 `service status`） | [签名 runbook](signing-and-authorization.md) §4 |
| 8 | 裁定 **`a2` bin 自身的签名 / 公证形态** | 它走单文件下载、不吃 `.app` 的签名链；Gatekeeper 会不会拦一个下载来的裸可执行，要等渠道定了才谈得上 | 本文 §0 表；签名 runbook §0 |
| 9 | **Homebrew Formula**（V1 明确**不做**，列此以免被当成漏项） | 先要 #1；再要 tap 仓库与"每次发版更新 formula" 的流程 | 本文 §7 |
| 10 | **带 quarantine 的 `.app` 双击首启实测**：App Translocation 到底发不发生、包内路径稳不稳、内嵌 bin 还能不能跑 | 一次**真下载**（浏览器打 quarantine 标记）+ 真人双击。本地构建的包不带 quarantine（13 票实测），造不出这个条件 | [ADR 0012](../adr/0012-panel-self-sufficient-bootstrap.md) Context；签名 runbook §6.2 |
| 11 | **小白路径真机走一遍**：下载 → 打开 → 点「安装并启动」→ 内核起来 → 菜单能用 | **代码已就位**（16 票）；只差一台干净机器 + 真人点那几下。门禁**从不**真装服务（install/uninstall 会动 launchd），所以这一段永远只能由人验 | 本文 §2.0；[ADR 0012](../adr/0012-panel-self-sufficient-bootstrap.md) |

**另外两条不属分发、但同批顺延的**（列此免得验收时以为漏了）：真 Codex 经 `a2 … --json` + `prefix_rule`
跑一遍旗舰操作、换源 dangerous 的真机点验（人真的点那个按钮）——两条都在路线图 Phase 1 的 5 条表里。
