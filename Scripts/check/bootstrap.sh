#!/bin/bash
# PROJECT_AA V1 编译门禁 —— 一条命令的红绿循环入口。
#
# 引擎(11 票起):**`swift build` + `swift test`**。Package.swift 是依赖图的唯一真值来源,
#   编译编排、拓扑序、模块搜索路径全交给 SPM,门禁不再手写 target 顺序与 -I。
#   build.sh 构建两次:一次 -DAA_TESTING(出 aa / aa-agent / aahost / registry-tests),
#   一次 -DAA_E2E(只为拿不含 AA_TESTING 的生产 aahost);swift-test.sh 跑 swift-testing 用例;
#   其余仍是 shell 断言阶段(进程级 / UDS 级 / E2E,那些搬不进 swift test)。
#
# 取舍(11 票的结账时刻,必须如实写明):**门禁自此只能在 SPM 可用的机器上跑。**
#   此前是 swiftc 直编 + vfsoverlay 回落 —— 靠遮蔽 CLT 里重复定义 SwiftBridging 的僵尸 modulemap,
#   让「坏 CLT 的机器」也能跑门禁。换成 swift build 之后这条回落已无意义:坏 CLT 的 SPM
#   (libPackageDescription.dylib 与其 .swiftmodule 接口错配)本来就构建不了任何东西,
#   「坏 CLT 也能跑门禁」这条路径不复存在。故 vfsoverlay 回落分支彻底删除。
#   overlay 本体保留在 Spikes/S1PetOverlay/toolchain-workaround/ 做历史留档(不删,但门禁不再引用)。
#   代价是环境门槛(需要一份 SPM 可用的工具链),买到的是真依赖图 + swift test + 将来可引第三方包。
#
# 02 票增量:
#   * AAHostMacOS 落地为 AppKit accessory 宿主(菜单栏 + UDS server)。注意其终态是「库」(Host Port 的 macOS 实现);
#     11 票起 @main 住在独立的 `aahost` executable target;GUI 宿主终态是 LSUIElement 菜单栏 `.app`,由 12 票落地。
#     (12 票起该 `.app` 不再走 XcodeGen/xcodebuild —— 本机无 Xcode,改为 `Scripts/build-app.sh` 手工组 bundle + ad-hoc 签名;
#      范围变更的完整理由写在该脚本顶部与 `.scratch/v1-core-proxy/issues/12-xcodegen-app-shell.md`。)
#   * AAContracts 加线协议 Codable(WireRequest/WireResponse/CapabilityDescriptor/…)与 UDS 路径常量。
#   * AAHostRuntime 加 Registry(纯逻辑,注册 + list)。
#   * AAHostTestKit 加 Registry 纯逻辑测试(假件 seam),由 `registry-tests` target 执行(11 票起是真源文件,不再动态生成)。
#   * 断言从 01 的 aa 占位(RiskLevel.parse)替换为 02 真断言:注册表纯逻辑 + list E2E(起真宿主)。
#
# 03 票增量:
#   * AAContracts 加 JSONValue / ParameterSpec / 退出码表(AAExitCode)/ WireErrorCode / describe·call 线协议。
#   * AAHostRuntime 的 Registry 加 invoke(集中校验 + 风险路由)+ 两个 demo(safe/echo、normal/note.set)。
#   * AAHostMacOS 的 UDSServer 路由补 describe/call;aa 补 describe/call 子命令 + 退出码映射 + 帮助里的退出码表。
#   * 阶段 B 增:describe/call E2E、schema 校验失败(6)、未知能力(6)、业务失败(5)、用法错(1)、
#     超时(3,借 python3 假监听器 + AA_TIMEOUT_SECONDS)、host 不可达(4)、帮助退出码表逐码断言。
#
# 04 票增量(dangerous 宿主确认纵切):
#   * AAHostRuntime.Registry 填实 dangerous 分支(注入 confirmDangerous;nil→fail-closed denied / false→denied / true→执行),
#     并注册 dangerous demo 能力 demo.wipe。
#   * AAHostMacOS 注入真 GUI 确认(NSAlert)+ test-only env seam AA_CONFIRM_AUTO(approve/deny 不弹窗即时返回)。
#   * AAHostTestKit 加三分支纯逻辑断言(含「confirm=nil fail-closed 绝不执行」保底 + 计数器反证)。
#   * 阶段 B 增:纯逻辑三分支断言;E2E 无人值守两分支(AA_CONFIRM_AUTO=deny→exit2 / approve→exit0);
#     反向不可绕过(裸 UDS python3 直连构造 capabilities.call demo.wipe → 仍 denied、未执行)。
#   * headless 下 GUI 弹窗不能真阻塞:靠 AA_CONFIRM_AUTO 让回调不弹窗即时返回,check.sh 不会挂在对话框上。
#
# 05 票增量(agent-first 命令面与接入引导,纯 CLI 层,无宿主/注册表改动):
#   * aa 增:域子命令(注册表元数据驱动,先 describe 取 schema→按声明类型强转 --参数[number 钳制 inf/nan]→走 call 底座
#     performCall)、aa docs agents-md(接入片段)、aa install-cli(符号链接入 PATH,幂等/--prefix/--force/--uninstall,
#     符号链接比较 canonical 化)、宿主未运行 UX 正式化(--json 时 stdout 机读 host_unreachable 信封 + stderr 人读 + 退出码 4)。
#   * 阶段 B 增:宿主未运行 --json 信封(2a2);域子命令≡call 逐字节一致 + 多级动词 + 缺参同契约 + string 强转按声明类型分派 +
#     选项值不吞旗标 + 未知参数=1 + 未知域=1 且机读 unknown_command 信封(2''''组);dangerous 域子命令 deny 仍走确认层
#     未绕过(D1b);docs agents-md grep(组5);install-cli 幂等/覆盖/缺目录 + canonical 相对链接判 already-installed +
#     --uninstall 幂等/拒误删(组6)。install-cli 只碰 $BUILD 下临时 --prefix,绝不碰真实 /usr/local/bin。
#
# 09 票增量(控制面能力包:模式/节点/组/测速):
#   * PluginProxy.MihomoRESTClient 加三扩展(PATCH /configs 切模式 / PUT /proxies/<g> 选节点 / GET /group/<g>/delay 按组测速,超时如实标注;动词对齐真核)。
#   * ProxyPlugin.capabilities() 加四能力:proxy.groups.list(safe)/ proxy.latency.test(safe)/ proxy.mode.set(normal)/ proxy.node.select(normal),各带 cliAlias。
#   * AAContracts.ParameterSpec 加可选 allowedValues(向后兼容);Registry.validate 据它做取值域校验(非法→invalid_params→退出码6)。
#   * Scripts/fake-mihomo.py 升级为**有状态**(内存维护 mode 与各组 now;PUT 改、GET 读回;/group/<g>/delay 含超时节点)。
#   * 阶段 B 增:1e 纯逻辑(REST 写读构造/解析 + 四能力风险级/别名/allowedValues + 取值域校验);
#     CP E2E(改后读回 mode/now 生效 + 逐节点测速含超时 + normal 零 GUI + number 强转 inf/nan→1)。
#
# 12 票增量(`.app` 壳:shell 组 bundle + ad-hoc 签名;**范围已从 XcodeGen 改写**):
#   * 新增 `Scripts/build-app.sh` —— 一条命令出 `.app`(`--variant production|e2e`、`--output`、
#     签名身份 env seam `AA_CODESIGN_IDENTITY` 缺省 `-`/ad-hoc)。不再有 XcodeGen / `xcodebuild`:
#     本机没有 Xcode,`.xcodeproj` 无消费者;理由与实测证据写在该脚本顶部。
#   * `Sources/PluginProxy/MihomoKernelResource.swift` 在 `Bundle.module` 之前先查
#     `Bundle.main.resourceURL/PROJECT_AA_PluginProxy.bundle/Resources/<name>` ——
#     实测「`Bundle.module` 能找到的落点」与「`codesign` 接受的落点」在 `.app` 形态下没有交集,详见 build-app.sh。
#   * 新增断言组 APP(`Scripts/check/app-bundle.sh`,6 条;15 票追加 4 条 → 现共 10 条):production 档只做静态断言(结构 / plist / 签名),
#     **绝不启动**(AA_MIHOMO_DATA_DIR 是 `#if AA_E2E` 门控的,起 production 宿主会往真实 AppSupport 写);
#     e2e 档直接 exec `.app` 内的 aahost 跑全链(UDS / capabilities / 真内核 / install-cli)。
#   * 断言组 3f:反孤儿信号钩子「无可执行同时装两套」的依赖闭包守卫(此前只在文档里声称存在,门禁里其实没有)。
#
# 15 票增量(GPL 关于页 + 内核重签入构建链;ADR 0007 义务落地):
#   * 新能力 `proxy.license`(safe,cliAlias `aa proxy license`)—— 报随包内核的版本/许可证/GPL 全文路径/
#     源码地址/子进程红线。**纯静态资源信息,内核不必在跑**。关于页的数据一律经它取(GUI 薄壳无私有逻辑)。
#   * `MihomoKernelResource` 补 `license` / `sourceURL`(由 version 派生)/ `licenseTextPath`(复用同一条资源查找)
#     / `subprocessBoundary` —— **内核版本与出处的单一来源就是这个类型**,与本文件解析的 $MIHOMO_VERSION 同源。
#   * 关于页落地为独立类型 `Sources/AAHostMacOS/AboutWindow.swift`(14 票重建菜单时原样复用,不必重写 GPL 呈现面)。
#   * `Scripts/build-app.sh` 给内嵌可执行签名时显式 `--identifier <bundle id>.<文件名>`,替掉 mihomo 官方产物
#     带来的 Go 默认 `Identifier=a.out`。
#   * 断言组 APP 追加 4 条(APP7–APP10):GPL 全文随包完整(SHA-256 现算现比)、`.app` 内 Mach-O 全签且身份一致
#     (**ad-hoc 下无证书链,口径见 app-bundle.sh 里的告示**)、`aa proxy license` 报出的内核版本与本文件解析值一致、
#     子进程红线原文真的经能力面暴露。后两条复用 e2e 档那一个已就绪的宿主,不另起。
#
# 14 票增量(菜单栏轻壳 + 手搓快照):
#   * 菜单从「只读能力清单」换成可操作的 ClashX Meta 式轻壳。核心是**一个模型、两个渲染器**:
#     纯数据模型 `AAUISystem.AAMenuModel` / `AAMenuModelBuilder`(零 AppKit,可单测)→
#     渲染器 A `AAMenuModel → NSMenu`(Sources/AAHostMacOS/MenuBarController.swift,真菜单 + 动作路由)、
#     渲染器 B `AAMenuModel → PNG`(Sources/AAHostMacOS/MenuSnapshotRenderer.swift,门禁可 diff 的那份)。
#     NSMenu 本身无法离屏截图 —— 拆出模型层正是「快照能进 headless 门禁」的唯一前提。
#   * **薄壳铁律**:每个可点菜单项的 action 都经同一个 `registry.invoke(capabilityID:input:)` 出口,
#     菜单里没有任何业务逻辑;dangerous(proxy.subscription.add)因此自动走宿主确认路由。
#   * 新可执行 `menu-snapshot`(门禁内部工具,无 product):渲染三种状态 → 落 `$BUILD/snapshots/` →
#     与入库 golden(`Snapshots/menubar/`,含 README)比像素 + 比模型文本。`AA_SNAPSHOT_RECORD=1` 显式重录
#     (且以非零码结束;门禁自己**永不**传它 —— 否则断言永远为真)。
#   * 两个 test-only env seam(与 AA_CONFIRM_AUTO 同口径,均在 HostApp.swift 的 `#if AA_TESTING` 内):
#     `AA_MENU_PROMPT_AUTO`(替掉「换源要用户填 name/source」的模态输入框)、
#     `AA_MENU_CLICK_PROBE`(启动后经 NSApp.sendAction 激活**真 NSMenuItem** 的 action)。13 票分发前须一并处置。
#   * 新断言组 MB(Scripts/check/menubar.sh,5 条):覆盖面/可追溯性、三态如实反映(判据在纯逻辑套件
#     MenuModelConformanceTests,shell 只 grep 结论行)、快照产物有效性、golden 比对、dangerous 菜单路径 deny。

# 接口契约(11 票换引擎前后**逐字不变**,这正是 11 票要守的那条):
#   一条命令跑完、任一步失败即非零退出;终端有清楚的 PASS/FAIL 输出。
#
# 不用 set -e:编译步骤各自显式判错退出,断言阶段要逐条收集结果不能一失败就退(对标 S2 test.sh)。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 全部中间产物落在 .build/(已被 .gitignore 忽略),不污染仓库。
BUILD="$ROOT/.build/check"
HOSTLOG="$BUILD/aahost.log"      # E2E 里宿主 stdout/stderr

# 可执行产物路径($BIN / $HOST_BIN / $PROD_HOST_BIN / $TESTRUNNER / $KILLPAT)由 build.sh 现场赋值:
#   它们是 `swift build --show-bin-path` 的输出,构建完成前无从得知(SPM 的 bin 目录带三元组与配置名)。
#   这带来一个真雷 —— 见下面 cleanup() 上方的说明。

# E2E 运行时资源(落在 Application Support 运行时目录,不进仓库);清场靠 KILLPAT + trap 兜底。
SOCK="$HOME/Library/Application Support/AA/aa.sock"
# 只盯本次构建的绝对路径,避免误杀用户机上别处同名的 aahost 进程。
# KILLPAT="$HOST_BIN" 现在在 build.sh 里赋值(HOST_BIN 要等 --show-bin-path 才知道)。

# 06 票:fake mihomo stub(测试替身,非真 mihomo)——供 proxy.status E2E 由宿主 ProcessPort 拉起/回收。
# 反孤儿断言与清场都按此模式兜底(杀宿主 + 杀 stub)。
# stub 以**绝对路径**入 argv(宿主 Process executableURL = $STUB),故 pkill/pgrep 盯绝对路径,
# 沿用本仓库「只盯本次构建绝对路径、避免误杀用户机上同名进程」的约定(02 票同款,不用裸文件名)。
STUB="$ROOT/Scripts/fake-mihomo.py"
KILLPAT_STUB="$STUB"

# 锁版内核版本号 —— 门禁侧的**单一来源**:从随包的 MIHOMO-VERSION.txt 解析,不在断言里散写字面量。
#   (此前 "1.19.28" 硬编码在 mihomo-real-e2e.sh 两处 + app-bundle.sh 两处;换内核版本时漏改一处,
#    断言就会拿旧版本号去比,红得莫名其妙 —— 或者更糟:比中了旧号却跑着新核。)
#   Swift 侧的对应单一来源是 MihomoKernelResource.version;两者同源于这个文件(15 票的「版本号单一来源」验收即此)。
MIHOMO_VERSION_FILE="$ROOT/Sources/PluginProxy/Resources/MIHOMO-VERSION.txt"
MIHOMO_VERSION="$(sed -n '1s/.*Meta v\([0-9][0-9.]*\).*/\1/p' "$MIHOMO_VERSION_FILE" 2>/dev/null)"
if [ -z "$MIHOMO_VERSION" ]; then
  echo "FAIL: 解析不出锁版内核版本号($MIHOMO_VERSION_FILE 首行格式应为 'Mihomo Meta vX.Y.Z …')"
  exit 1
fi

# 08 票:接管态持久化默认落点 —— **全局导出**到 $BUILD 临时区,确保**所有**测试宿主(06/07/08)绝不污染真实 AppSupport。
#   宿主读 env seam AA_TAKEOVER_STATE_PATH(生产缺省为真实 AppSupport)。08 各 kill -9 剧本按需以 per-launch env 覆盖到独立文件。
export AA_TAKEOVER_STATE_PATH="$BUILD/takeover-default.json"
# 10 票:订阅目录默认落点 —— 同样**全局导出**到 $BUILD 临时区,确保**所有**测试宿主(含 06/07/08/09 的非订阅宿主,
#   它们启动时也会读订阅清单做重启恢复)绝不污染真实 AppSupport 的 subscriptions/。订阅 E2E 各场景按需 per-launch 覆盖到独立子目录。
export AA_SUBSCRIPTION_DIR="$BUILD/subs-default"
# 真实 AppSupport 的接管态文件:跑前 md5 快照,跑后比对,断言本次运行未触碰它(未污染真实 AppSupport 的证明)。
REAL_TAKEOVER="$HOME/Library/Application Support/AA/takeover-state.json"
REAL_TAKEOVER_BEFORE="$( [ -e "$REAL_TAKEOVER" ] && md5 -q "$REAL_TAKEOVER" 2>/dev/null || echo ABSENT )"
REAL_TAKEOVER_RECOVERY="$REAL_TAKEOVER.recovery"
REAL_TAKEOVER_RECOVERY_BEFORE="$( [ -e "$REAL_TAKEOVER_RECOVERY" ] && md5 -q "$REAL_TAKEOVER_RECOVERY" 2>/dev/null || echo ABSENT )"
REAL_TAKEOVER_CLEARED="$REAL_TAKEOVER.cleared"
REAL_TAKEOVER_CLEARED_BEFORE="$( [ -e "$REAL_TAKEOVER_CLEARED" ] && md5 -q "$REAL_TAKEOVER_CLEARED" 2>/dev/null || echo ABSENT )"
# 10 票:真实 AppSupport 的订阅目录同法快照(递归列表 md5),跑后比对,证明未污染。
REAL_SUBS_DIR="$HOME/Library/Application Support/AA/subscriptions"
REAL_SUBS_BEFORE="$( [ -e "$REAL_SUBS_DIR" ] && ls -laR "$REAL_SUBS_DIR" 2>/dev/null | md5 2>/dev/null || echo ABSENT )"

# 12 票:**用户自己的 mihomo 绝不能被门禁碰到**(它很可能就是这台机器当下的上网通道 ——
#   动它 = 把用户的网络掐了)。本仓库自带一份**同名但不同文件**的锁版内核
#   (Sources/PluginProxy/Resources/mihomo-darwin-arm64),门禁起停的只有它。
#
# 靠「代码里没写 pkill mihomo」来保证这件事是不够的 —— 那是靠人读代码,读漏一次就出事。
#   这里按本仓库既有的「跑前快照 / 跑后比对」口径把它钉死:记下所有**不在本仓库树内**的
#   mihomo 进程 pid,跑完比对。少了一个就说明门禁误伤了用户的进程 → 当场红。
#
# 判据用「可执行路径不以 $ROOT 开头」:仓库自带内核与 Scripts/fake-mihomo.py 都在 $ROOT 下,
#   会被排除;用户装在 /usr/local/bin 或别处的那份则被纳入看护。
# 已知误报场景(如实写明):**若你自己在门禁运行期间重启了 mihomo,这条会红** —— 那是预期行为,
#   不是缺陷:这条断言分不清「被门禁杀了」和「你自己重启了」,它宁可误报也不漏报。
# 返回「不在本仓库树内的 mihomo pid」列表;**pgrep 自身出错时返回哨兵串**,而不是装作「一个都没有」——
#   否则守卫坏掉的表现会是「跑前跑后都是空 → 一致 → PASS」,又是一次白送(见 finalize.sh 同款口径)。
#   pgrep 退出码:0=有匹配,1=无匹配(正常),>1=自身出错。
foreign_mihomo_pids() {
  local pids rc pid exe
  # 先用 `pgrep -f`(匹配整条命令行)**宽召回**,再逐个按**可执行路径**筛 —— 两步都必要:
  #   * 只用 -f 会误报:任何 argv 里出现 "mihomo" 字样的进程(比如一条 `grep "…mihomo…" 日志` 的 shell)
  #     都会被算成「用户的 mihomo」。13 票实测撞过一次:守卫报「多了一个 pid」,查出来是监控用的 shell。
  #     那种红最坏 —— 它长得像「门禁误伤了用户内核」,会把人吓一跳,查半天发现是自己。
  #   * 但**不能**因此改成只匹配可执行名:`pgrep` 的名字匹配有长度截断,宽召回这一步要留着。
  # 按 `ps -o comm=` 筛。**这里必须把话说准,不许含糊**:
  #   * macOS 上 `comm` 严格说是 **argv[0]**,不是内核记录的可执行真实路径 —— 进程可以改写它。
  #     实测本机 `ps -p 553 -o comm=` 给的是 `/usr/local/bin/mihomo`,够用,但别把它当防伪凭证。
  #   * 这次收窄**主要**是更精确(消掉 argv 误报),**但确实有一类变松了**:
  #     如果有人把 mihomo 二进制**改了名**(可执行名不含 mihomo)再配 mihomo 配置目录跑,
  #     旧的 argv 判据能抓到它,新判据会放过。这是双轴 CR 指出来的,如实记下,不粉饰。
  #   * 之所以仍然收窄:误报率高的守卫会被人学会无视,那比守卫窄一点更危险 —— 而且这条守卫本就是
  #     **兜底网**(第一道防线是「每个 pkill 都只盯仓库树内绝对路径」,那条没有放松)。
  #   取舍记在 13 票票面,要不要换更硬的判据(如比对可执行 inode)由用户定。
  pids="$(pgrep -f mihomo 2>/dev/null)"; rc=$?
  if [ "$rc" -gt 1 ]; then printf 'PGREP_ERROR(rc=%s)' "$rc"; return 0; fi
  for pid in $pids; do
    exe="$(ps -p "$pid" -o comm= 2>/dev/null)"
    if [ -z "$exe" ]; then
      # ps 拿不到:两种情形要分开,**不能一律当「不是 mihomo」丢掉**。
      #   进程已经退出(pgrep 与 ps 之间的竞态)→ 无所谓,跳过;
      #   进程**还活着**而 ps 失败 → 守卫此刻是瞎的。若照旧静默跳过,它就不进跑前快照;
      #     万一门禁随后真误杀了它,跑后同样查不到 → 前后相等 → **白送一个 PASS**。
      #   这正是本函数头上那条规矩(守卫自身出错要出哨兵、不许装作一个都没有)。
      if kill -0 "$pid" 2>/dev/null; then printf 'PS_ERROR(pid=%s)' "$pid"; return 0; fi
      continue
    fi
    case "$exe" in
      "$ROOT"/*) continue ;;              # 仓库自带的锁版内核 / fake stub,不在看护范围
                                          #   末尾带 `/` 是边界:否则 `<ROOT>-something/mihomo` 会被误判成仓库内
      *mihomo*)  printf '%s ' "$pid" ;;   # 仓库外的真 mihomo —— 正是要看护的那些
      *)         continue ;;              # argv[0] 不含 mihomo(监控 shell 之类)
    esac
  done
}
FOREIGN_MIHOMO_BEFORE="$(foreign_mihomo_pids)"

# $SWIFT_BIN 由下方「工具链探测(SPM 可用性)」段现场决定(须在 $BUILD 建好之后 —— 探测要往里写 scratch)。
# env seam:AA_SWIFT 可显式指定 swift(例如独立工具链里的绝对路径);缺省按候选顺序自动挑。
# (11 票前的 AA_SWIFTC / SWIFTC_BIN / SWIFTC_COMMON / build_lib 已全部删除:不再有 swiftc 直编这条路。
#  SDKROOT 那段也随之删掉 —— 它是为「装在家目录的独立工具链直编时找不到 SDK」加的,
#  `swift build` 自己会做 SDK 解析,那段已无调用方。)

# 超时 E2E 用的「只 accept 不回应」假监听器脚本(python3,绑定同一 socket 路径);清场按此模式兜底。
TIMEOUT_LISTENER="$BUILD/timeout_listener.py"

# agent-delegation 06 的真进程测试使用唯一时长，便于精确清场且不误杀用户的普通 sleep。
AGENT_SLEEP_SUITE="sleep 87137"
AGENT_SLEEP_PROBE="sleep 87139"

# 12 票:`.app` 壳的产物落点与其中的可执行/内核绝对路径(断言组 APP 用;清场也要盯它们)。
#   这几个是**静态常量**——全由 $BUILD 派生,在 trap 装上之前就已赋值,不可能为空。
#   与 $KILLPAT / $PROD_HOST_BIN 那种「要等 build.sh 的 --show-bin-path 才知道」的动态路径**不是一类**,
#   故下面 cleanup() 里直接用、不加非空守卫(照本文件既有口径:多余的守卫会让读的人误以为它们也会空)。
#   落在 $BUILD 下 = 每轮门禁开头随 `rm -rf "$BUILD"` 一起清掉,不留旧产物。
#   (build-app.sh 自己的 SPM scratch 在 $ROOT/.build/app-build-<档>,**刻意**不在 $BUILD 里 —— 那是增量构建缓存,要跨轮保留。)
APP_OUT_PROD="$BUILD/app-production"
APP_OUT_E2E="$BUILD/app-e2e"
APP_PROD_HOST_BIN="$APP_OUT_PROD/AA.app/Contents/MacOS/aahost"   # 只做静态断言,**绝不启动**(理由见 app-bundle.sh 顶部)
APP_E2E_HOST_BIN="$APP_OUT_E2E/AA.app/Contents/MacOS/aahost"
APP_E2E_KERNEL="$APP_OUT_E2E/AA.app/Contents/Resources/PROJECT_AA_PluginProxy.bundle/Resources/mihomo-darwin-arm64"

# 失败/成功任一路径都清场,杜绝僵尸宿主 / 残 socket / 残假监听器。
#
# **每一个变量型 pkill 都必须有非空守卫** —— 这是 11 票引入的真雷,不是洁癖:
#   `$KILLPAT` / `$PROD_HOST_BIN` 等路径变量此前是静态的(bootstrap.sh 里就定死),现在改由 build.sh
#   在 `swift build` 成功后才赋值。于是**只要门禁在 build.sh 之前就失败退出**(工具链探测失败、
#   构建失败……),trap 触发时这些变量还是空串,而 `pkill -f ""` 的空模式会匹配**一切进程**并杀掉
#   —— 一次工具链探测失败就能把用户的整个会话清空。故**凡是 build.sh 之后才赋值的路径变量**
#   都写成 `[ -n "${VAR:-}" ] && pkill -f "$VAR"`(下面注明了哪几个)。
#   本文件里在 trap 装上之前就已赋值的静态常量(KILLPAT_STUB / AGENT_SLEEP_*)与字面量模式
#   (timeout_listener.py 等)不可能为空,直接用,不加多余守卫 —— 免得读的人以为它们也会空。
#   finalize.sh 的 pgrep 同理,但那边还多一层:守卫**不可用**时必须显式判 FAIL,不能静默算过。
cleanup() {
  # ↓ 这三个由 build.sh 现场赋值(见 build.sh「下游路径变量」段),故必须守卫。
  [ -n "${KILLPAT:-}" ] && pkill -f "$KILLPAT" 2>/dev/null
  [ -n "${PROD_HOST_BIN:-}" ] && pkill -f "$PROD_HOST_BIN" 2>/dev/null
  # ↓ 以下是本文件里的静态常量/字面量,恒非空。
  # 12 票:`.app` 里那个 aahost 与它拉起的内核。**是与 $KILLPAT / $PROD_HOST_BIN 完全不同的绝对路径**
  #   (在 $BUILD/app-*/AA.app/Contents/… 下),不盯就会漏掉 —— 三者互相没有子串关系,一条 pkill 覆盖不了。
  #   内核**只**按 `.app` 内绝对路径杀:绝不 pkill 裸 "mihomo",用户机上可能正跑着自己的那一份。
  pkill -f "$APP_E2E_HOST_BIN" 2>/dev/null
  pkill -f "$APP_PROD_HOST_BIN" 2>/dev/null
  pkill -f "$APP_E2E_KERNEL" 2>/dev/null
  pkill -f "$KILLPAT_STUB" 2>/dev/null
  pkill -f "timeout_listener.py" 2>/dev/null
  pkill -f "raw_uds_client.py" 2>/dev/null
  pkill -f "$AGENT_SLEEP_SUITE" 2>/dev/null
  pkill -f "$AGENT_SLEEP_PROBE" 2>/dev/null
  [ -n "${FAKE_AGENT_DIR:-}" ] && pkill -f "$FAKE_AGENT_DIR/fake-" 2>/dev/null
  # 10:订阅 http 假源(python3 -m http.server)按 PID 收场(端口随机、只杀本次起的那个,绝不 pkill 'http.server' 误伤用户机上别的服务)。
  [ -n "${SUBHTTP_PID:-}" ] && kill "$SUBHTTP_PID" 2>/dev/null
  [ -n "${REAL_KERNEL_PID:-}" ] && kill "$REAL_KERNEL_PID" 2>/dev/null
  rm -f "$SOCK" 2>/dev/null
  rm -f "$AA_TAKEOVER_STATE_PATH" "$AA_TAKEOVER_STATE_PATH.recovery" "$AA_TAKEOVER_STATE_PATH.cleared" 2>/dev/null   # 08:清临时区主副文件与墓碑
}
trap cleanup EXIT

echo "========================================"
echo " PROJECT_AA check.sh —— swift build + swift test 门禁"
echo " ROOT   = $ROOT"
echo "========================================"

rm -rf "$BUILD"
mkdir -p "$BUILD"

# ---- 工具链探测(SPM 可用性)-----------------------------------------------------
# 判据只有一条:**`swift package dump-package` 能 rc=0**。
#   它要求真正加载 libPackageDescription 并解析清单 —— 坏 CLT 的那份 dylib 与其 .swiftmodule
#   接口错配(880 个符号但零个 `Package.__allocating_init`),这一步必 rc=1。好工具链 rc=0。
#   比「swiftc 能不能编个 hello world」严格得多,而后者根本不覆盖 SPM 这条路。
# 候选顺序(第一个 rc=0 的胜出):
#   ① $AA_SWIFT              —— env seam,显式指定(CI / 多工具链机器)
#   ② ~/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift —— 官方独立工具链的约定落点
#   ③ PATH 上的 swift        —— CLT 或已 xcode-select 到的那个
# 一个都不行 → 如实报错退出,**不假装能跑**。
PROBE="$BUILD/toolchain-probe"
mkdir -p "$PROBE"

SWIFT_CANDIDATES=()
[ -n "${AA_SWIFT:-}" ] && SWIFT_CANDIDATES+=("$AA_SWIFT")
SWIFT_CANDIDATES+=("$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift")
SWIFT_CANDIDATES+=("swift")

SWIFT_BIN=""
PROBE_REPORT=""
PROBE_I=0
for cand in "${SWIFT_CANDIDATES[@]}"; do
  PROBE_I=$((PROBE_I+1))
  # 先确认这个候选真存在(PATH 上的名字或可执行的绝对路径),否则 dump-package 的 rc 没有诊断价值。
  if ! command -v "$cand" >/dev/null 2>&1 && [ ! -x "$cand" ]; then
    PROBE_REPORT="$PROBE_REPORT
  [$PROBE_I] $cand —— 不存在 / 不可执行"
    continue
  fi
  if "$cand" package dump-package --scratch-path "$PROBE/spm-probe-$PROBE_I" \
       >"$PROBE/dump-$PROBE_I.log" 2>&1; then
    SWIFT_BIN="$cand"
    break
  fi
  PROBE_REPORT="$PROBE_REPORT
  [$PROBE_I] $cand —— \`swift package dump-package\` rc≠0(SPM 不可用),日志: $PROBE/dump-$PROBE_I.log"
done

if [ -z "$SWIFT_BIN" ]; then
  echo "FAIL: 找不到 SPM 可用的 swift —— 门禁的编译引擎是 swift build,没有它就跑不了。"
  echo "  已试候选:$PROBE_REPORT"
  echo
  echo "  最常见原因:CLT 自带的 SPM 是坏的(libPackageDescription.dylib 与其 .swiftmodule 接口错配)。"
  echo "  解法是装一份官方独立工具链到家目录(**不需要 Xcode,也不需要 sudo**):"
  echo "    curl -O https://download.swift.org/swift-6.1.2-release/xcode/swift-6.1.2-RELEASE/swift-6.1.2-RELEASE-osx.pkg"
  echo "    installer -pkg ~/Downloads/swift-6.1.2-RELEASE-osx.pkg -target CurrentUserHomeDirectory"
  echo "  (详见 .scratch/v1-core-proxy/issues/11-skeleton-truth-up-xcode.md)"
  echo "  装好后本脚本会自动认到 ~/Library/Developer/Toolchains/swift-latest.xctoolchain;"
  echo "  也可用 AA_SWIFT=<swift 绝对路径> 显式指定。"
  exit 1
fi

echo " swift    = $SWIFT_BIN"
echo " 版本     = $("$SWIFT_BIN" --version 2>/dev/null | head -1)"
echo " 引擎     = swift build + swift test(Package.swift 是依赖图唯一真值来源)"
echo "========================================"
echo
