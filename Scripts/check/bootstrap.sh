#!/bin/bash
# PROJECT_AA V1 骨架期编译门禁 —— 一条命令的红绿循环入口。
#
# 姿态:本机 CLT 损坏(module.modulemap 与 bridging.modulemap 重复定义 SwiftBridging),SPM 整体不可用,
# 故不走 swift build,改用 spike 已固化的 vfsoverlay 直编:
#   swiftc + -vfsoverlay <空 modulemap 遮掉重复定义> + -module-cache-path <独立缓存>。
# 按 07 票拓扑序逐 target 编译(库 target 产 .swiftmodule,后续 target 用 -I 指向前序模块目录;
# aa 产真可执行;AAHostMacOS 是库,但门禁借 vfsoverlay 把它单独编成可执行做冒烟),再跑 assert 测试。
#
# 02 票增量:
#   * AAHostMacOS 落地为 AppKit accessory 宿主(菜单栏 + UDS server)。注意其终态是「库」(Host Port 的 macOS 实现);
#     @main 只是过桥,GUI 宿主终态是 XcodeGen app 壳(LSUIElement),归 12 票——门禁这里照 S2 run.sh 单独把它编成可执行冒烟。
#   * AAContracts 加线协议 Codable(WireRequest/WireResponse/CapabilityDescriptor/…)与 UDS 路径常量。
#   * AAHostRuntime 加 Registry(纯逻辑,注册 + list)。
#   * AAHostTestKit 加 Registry 纯逻辑测试(假件 seam),由门禁生成的 runner 执行。
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
# 接口契约(11 票换成 swift build + swift test 引擎时保持不变):
#   一条命令跑完、任一步失败即非零退出;终端有清楚的 PASS/FAIL 输出。
#
# 不用 set -e:编译步骤各自显式判错退出,断言阶段要逐条收集结果不能一失败就退(对标 S2 test.sh)。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# vfsoverlay 只读复用 S1 spike 里那份(遮掉 CLT 重复的 SwiftBridging modulemap);CLT 修好后可移除该旗标。
OVERLAY="$ROOT/Spikes/S1PetOverlay/toolchain-workaround/overlay.yaml"

# 全部中间产物落在 .build/(已被 .gitignore 忽略),不污染仓库。
BUILD="$ROOT/.build/check"
MCACHE="$BUILD/mcache"     # 独立 module-cache
MODULES="$BUILD/modules"   # 所有库 target 的 .swiftmodule 汇总目录
OBJ="$BUILD/obj"           # 库 target 的目标文件(.o),供可执行 target 链接
PPMODS="$BUILD/pp-modules" # 只含 SDK/Contracts/UISystem 的受限搜索路径,用于证明 PluginProxy 不需要 Host*
BIN="$BUILD/bin"           # 可执行产物
RUNNER="$BUILD/registry-runner" # 门禁生成的 TestKit runner 入口 shim

HOST_BIN="$BIN/aahost"           # AppKit accessory 宿主可执行
PROD_HOST_BIN="$BIN/aahost-production-e2e" # 不含 AA_TESTING，真核全链 E2E 宿主
TESTRUNNER="$BIN/registry-tests" # Registry 纯逻辑测试 runner
HOSTLOG="$BUILD/aahost.log"      # E2E 里宿主 stdout/stderr

# E2E 运行时资源(落在 Application Support 运行时目录,不进仓库);清场靠 KILLPAT + trap 兜底。
SOCK="$HOME/Library/Application Support/AA/aa.sock"
# 只盯本次构建的绝对路径,避免误杀用户机上别处同名的 aahost 进程。
KILLPAT="$HOST_BIN"

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
# 10 票:真实 AppSupport 的订阅目录同法快照(递归列表 md5),跑后比对,证明未污染。
REAL_SUBS_DIR="$HOME/Library/Application Support/AA/subscriptions"
REAL_SUBS_BEFORE="$( [ -e "$REAL_SUBS_DIR" ] && ls -laR "$REAL_SUBS_DIR" 2>/dev/null | md5 2>/dev/null || echo ABSENT )"

SWIFTC_COMMON=(-swift-version 5 -vfsoverlay "$OVERLAY" -module-cache-path "$MCACHE")

# 超时 E2E 用的「只 accept 不回应」假监听器脚本(python3,绑定同一 socket 路径);清场按此模式兜底。
TIMEOUT_LISTENER="$BUILD/timeout_listener.py"

# 失败/成功任一路径都清场,杜绝僵尸宿主 / 残 socket / 残假监听器。
cleanup() {
  pkill -f "$KILLPAT" 2>/dev/null
  pkill -f "$PROD_HOST_BIN" 2>/dev/null
  pkill -f "$KILLPAT_STUB" 2>/dev/null
  pkill -f "timeout_listener.py" 2>/dev/null
  pkill -f "raw_uds_client.py" 2>/dev/null
  # 10:订阅 http 假源(python3 -m http.server)按 PID 收场(端口随机、只杀本次起的那个,绝不 pkill 'http.server' 误伤用户机上别的服务)。
  [ -n "${SUBHTTP_PID:-}" ] && kill "$SUBHTTP_PID" 2>/dev/null
  [ -n "${REAL_KERNEL_PID:-}" ] && kill "$REAL_KERNEL_PID" 2>/dev/null
  rm -f "$SOCK" 2>/dev/null
  rm -f "$AA_TAKEOVER_STATE_PATH" 2>/dev/null   # 08:清临时区默认持久化文件(绝不落真实 AppSupport)
}
trap cleanup EXIT

echo "========================================"
echo " PROJECT_AA check.sh —— vfsoverlay 直编门禁"
echo " ROOT   = $ROOT"
echo " OVERLAY= $OVERLAY"
echo "========================================"

if [ ! -f "$OVERLAY" ]; then
  echo "FAIL: 找不到 vfsoverlay:$OVERLAY"
  exit 1
fi

rm -rf "$BUILD"
mkdir -p "$MCACHE" "$MODULES" "$OBJ" "$PPMODS" "$BIN" "$RUNNER"

# ---- 编 1 个库 target:同时产 .swiftmodule(到 $MODULES,供下游 import)与 .o(到 $OBJ,供可执行链接)----
#      -c 为主动作(产目标文件),-emit-module-path 为附带产物;-wmo 让多源文件汇成单一 .o。
#      -I 指向 $MODULES,可见全部前序模块。
build_lib() {  # $1 = target 名
  local name="$1"
  echo "-- 编译库 target: $name"
  swiftc "${SWIFTC_COMMON[@]}" -wmo \
    -parse-as-library \
    -module-name "$name" \
    -c -o "$OBJ/$name.o" \
    -emit-module-path "$MODULES/$name.swiftmodule" \
    -I "$MODULES" \
    "Sources/$name"/*.swift \
    || { echo "FAIL: 编译 $name 失败"; exit 1; }
}

echo
