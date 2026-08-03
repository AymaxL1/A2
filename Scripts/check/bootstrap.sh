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
#     11 票起 @main 住在独立的 `aahost` executable target,GUI 宿主终态是 XcodeGen app 壳(LSUIElement),归 12 票。
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
