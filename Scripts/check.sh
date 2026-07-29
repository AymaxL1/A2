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
  pkill -f "$KILLPAT_STUB" 2>/dev/null
  pkill -f "timeout_listener.py" 2>/dev/null
  pkill -f "raw_uds_client.py" 2>/dev/null
  # 10:订阅 http 假源(python3 -m http.server)按 PID 收场(端口随机、只杀本次起的那个,绝不 pkill 'http.server' 误伤用户机上别的服务)。
  [ -n "${SUBHTTP_PID:-}" ] && kill "$SUBHTTP_PID" 2>/dev/null
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
echo "==== 阶段 A:按拓扑序编译全部 target ===="

# ① 零依赖底座(含线协议 Codable + UDS 路径常量)
build_lib AAContracts

# ② 只依赖 Contracts(06 票:AAPluginSDK 现含 ProcessPort/HTTPPort 两个宿主 Port 协议 + PluginCapability)
build_lib AAPluginSDK
build_lib AAHostRuntime   # 含 Registry(纯逻辑)
build_lib AAUISystem

# ③ PluginProxy —— 受限搜索路径:只放 SDK/Contracts/UISystem,故意不放任何 Host* 模块。
#    若它能在这条受限 -I 下编过,即从编译期证明「PluginProxy 不需要 Host*」(01 票铁律,06 票继续把关:
#    新增的 ProcessPort/HTTPPort 协议在 SDK,故插件仍只靠 SDK 即可编过)。
#    06 票起 PluginProxy 需被 AAHostTestKit(测试)与 AAHostMacOS(宿主装配)链接,故这里除 .swiftmodule 外也产 .o。
#    先于 AAHostTestKit / AAHostMacOS 编译(二者都 import PluginProxy)。
echo "-- 编译库 target: PluginProxy(受限 -I:仅 SDK/Contracts/UISystem,无 Host*;产 .o + module)"
cp "$MODULES/AAContracts.swiftmodule" "$MODULES/AAPluginSDK.swiftmodule" "$MODULES/AAUISystem.swiftmodule" "$PPMODS/" \
  || { echo "FAIL: 准备 PluginProxy 受限模块目录失败"; exit 1; }
swiftc "${SWIFTC_COMMON[@]}" -wmo \
  -parse-as-library \
  -module-name PluginProxy \
  -c -o "$OBJ/PluginProxy.o" \
  -emit-module-path "$MODULES/PluginProxy.swiftmodule" \
  -I "$PPMODS" \
  Sources/PluginProxy/*.swift \
  || { echo "FAIL: 编译 PluginProxy(受限 -I)失败 —— 它可能意外依赖了 Host* 或其它未提供模块"; exit 1; }

# ④ 假件 + 06 票纯逻辑测试(AAHostTestKit 现依赖 AAPluginSDK + PluginProxy:Port 假件 + RESTClient/status 测试)
build_lib AAHostTestKit

# ⑤ 宿主(库,但门禁单独把它编成可执行做冒烟;@main 是过桥,终态是 12 票 XcodeGen app 壳)。
#    06 票:宿主装配 ProxyPlugin(注入真 SystemProcessPort/SocketHTTPPort),故链接补 AAPluginSDK.o / PluginProxy.o / AAUISystem.o。
echo "-- 编译可执行 target: AAHostMacOS(库→冒烟可执行;AppKit,首次编译约 30s)"
swiftc "${SWIFTC_COMMON[@]}" \
  -parse-as-library \
  -I "$MODULES" \
  -o "$HOST_BIN" \
  "$OBJ/AAContracts.o" "$OBJ/AAHostRuntime.o" "$OBJ/AAPluginSDK.o" "$OBJ/PluginProxy.o" "$OBJ/AAUISystem.o" \
  Sources/AAHostMacOS/*.swift \
  || { echo "FAIL: 编译 AAHostMacOS 失败"; exit 1; }

# ④ CLI 可执行:@main 入口需 -parse-as-library;链接其依赖 AAContracts.o;产真二进制。
echo "-- 编译可执行 target: aa"
swiftc "${SWIFTC_COMMON[@]}" \
  -parse-as-library \
  -I "$MODULES" \
  -o "$BIN/aa" \
  "$OBJ/AAContracts.o" \
  Sources/aa/*.swift \
  || { echo "FAIL: 编译 aa 失败"; exit 1; }

# ⑤ 门禁生成的 Registry 纯逻辑测试 runner —— 断言逻辑在 AAHostTestKit.RegistryConformanceTests,
#    这里只是入口 shim(main.swift 顶层代码,不需 -parse-as-library)。链接 TestKit + Runtime + Contracts。
echo "-- 编译测试 runner: registry-tests(驱动 AAHostTestKit.RegistryConformanceTests)"
cat > "$RUNNER/main.swift" <<'SWIFT'
// 门禁自动生成:纯逻辑测试的入口 shim(断言逻辑在 AAHostTestKit)。
// 06 票:除 RegistryConformanceTests 外,追加 ProxyConformanceTests(Port 假件 / RESTClient / proxy.status 域逻辑)。
import AAHostTestKit
import Foundation
let r1 = RegistryConformanceTests.run()
for line in r1.lines { print(line) }
let r2 = ProxyConformanceTests.run()
for line in r2.lines { print(line) }
print("REGISTRY_TESTS passed=\(r1.passed) failed=\(r1.failed)")
print("PROXY_TESTS passed=\(r2.passed) failed=\(r2.failed)")
let failed = r1.failed + r2.failed
print("ALL_UNIT passed=\(r1.passed + r2.passed) failed=\(failed)")
fflush(stdout)
exit(failed == 0 ? 0 : 1)
SWIFT
swiftc "${SWIFTC_COMMON[@]}" \
  -I "$MODULES" \
  -o "$TESTRUNNER" \
  "$OBJ/AAContracts.o" "$OBJ/AAHostRuntime.o" "$OBJ/AAHostTestKit.o" \
  "$OBJ/AAPluginSDK.o" "$OBJ/PluginProxy.o" "$OBJ/AAUISystem.o" \
  "$RUNNER/main.swift" \
  || { echo "FAIL: 编译 registry-tests runner 失败"; exit 1; }

echo "全部 target 编译通过。"

# ------------------------------------------------------------
echo
echo "==== 阶段 B:assert 测试 ===="
PASS=0; FAIL=0
assert_contains() {  # $1 实际文本  $2 期望子串(定长字符串,非正则)  $3 描述
  if printf '%s' "$1" | grep -qF -- "$2"; then
    echo "PASS: $3"; PASS=$((PASS+1))
  else
    echo "FAIL: $3 (未找到 '$2';实际输出: $1)"; FAIL=$((FAIL+1))
  fi
}
assert_exit() {  # $1 期望码  $2 实际码  $3 描述
  if [ "$1" -eq "$2" ]; then
    echo "PASS: $3 (exit=$2)"; PASS=$((PASS+1))
  else
    echo "FAIL: $3 (期望 exit=$1, 实际 $2)"; FAIL=$((FAIL+1))
  fi
}

# ============ E2E 宿主生命周期助手(消除就绪竞态,累积负载下稳)============
# 根因(09 排查):E2E 宿主是 AppKit accessory app,其启动含 NSApplication + 状态栏项(触达 WindowServer)。
#   在一整轮门禁的累积负载下(多轮编译 + 反复起停宿主 + python stub + pkill),AppKit 启动偶尔慢于旧的 20s 就绪窗口,
#   于是「socket 未在窗口内出现」被记成一条模糊 FAIL(如 dangerous deny 组的「宿主未就绪」)。这不是能力逻辑问题,是就绪竞态。
# 修法(不靠盲加 sleep):① 起下一个宿主前,轮询确认上一个**真死**(kill -0 失败为止)+ 删残留 socket + 清默认持久化标记,杜绝重叠争用与跨 E2E 污染;
#   ② 就绪窗口放宽到 40s 并**区分「启动即死」与「起得过慢」**,两种都立刻 dump 宿主日志(不再混成一条模糊 FAIL,便于定位)。

# 彻底停掉本次构建的宿主(+ 可选 stub),轮询等其真死(带上限 15s),再删残留 socket 与**默认**持久化标记。
# 取代此前的盲 `sleep 1`。注:只清 $AA_TAKEOVER_STATE_PATH(默认标记);08 各剧本用独立的 $SHSTATE,由其自身逻辑管理,不受此影响。
teardown_hosts() {  # $1(可选)= also-stub:同时停 fake mihomo stub 并等其真死(避免残 stub 占 MIHOMO_PORT 的小竞态)
  local also_stub="no"
  [ "${1:-}" = "also-stub" ] && also_stub="yes"
  pkill -f "$KILLPAT" 2>/dev/null
  [ "$also_stub" = "yes" ] && pkill -f "$KILLPAT_STUB" 2>/dev/null
  local i
  for i in $(seq 1 150); do
    if pgrep -f "$KILLPAT" >/dev/null 2>&1; then sleep 0.1; continue; fi
    if [ "$also_stub" = "yes" ] && pgrep -f "$KILLPAT_STUB" >/dev/null 2>&1; then sleep 0.1; continue; fi
    break   # 宿主(及 also-stub 时的 stub)均已真死
  done
  rm -f "$SOCK"
  rm -f "$AA_TAKEOVER_STATE_PATH" 2>/dev/null   # 清默认标记:非接管类 E2E 宿主启动自愈恒 decision=clean,快速就绪、零跨 E2E 污染
}

# 轮询等宿主就绪(socket 出现)。$1=宿主 PID。置全局 SOCK_UP(1=就绪 / 0=失败)。返回 0/1 便于调用方分支。
# 窗口 40s(200×0.2);区分「启动即死」(kill -0 失败)与「存活但过慢」(窗口耗尽),两种都 dump 宿主日志。
wait_host_ready() {  # $1 = HOST_PID
  local pid="$1" i
  SOCK_UP=0
  for i in $(seq 1 200); do
    [ -S "$SOCK" ] && { SOCK_UP=1; return 0; }
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "    [就绪探测] 宿主(pid=$pid)启动即退出(socket 未出现)——是启动失败,非「慢」。宿主日志:"
      sed 's/^/      /' "$HOSTLOG" 2>/dev/null
      return 1
    fi
    sleep 0.2
  done
  echo "    [就绪探测] 宿主(pid=$pid)存活但 40s 内 socket 未出现(启动过慢)。宿主日志:"
  sed 's/^/      /' "$HOSTLOG" 2>/dev/null
  return 1
}

# --- 断言组 1:Registry 纯逻辑(经 AAHostTestKit 假件,不起真宿主 / 不碰 UDS)---
echo "--- 断言组 1:Registry 纯逻辑(AAHostTestKit.RegistryConformanceTests)---"
OUT="$("$TESTRUNNER" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/    /'
assert_exit 0 $RC "registry-tests 全绿退出码"
assert_contains "$OUT" "demo.echo" "纯逻辑测试覆盖 demo.echo"
# 04 票安全核三分支(纯逻辑,假件驱动,不起宿主):
assert_contains "$OUT" "假 confirm=true 时 handler 恰执行一次" "纯逻辑:dangerous+confirm=true → 执行 handler"
assert_contains "$OUT" "假 confirm=false → denied" "纯逻辑:dangerous+confirm=false → denied"
assert_contains "$OUT" "handler 绝不执行(fail-closed 保底)" "纯逻辑:confirm=nil → fail-closed 绝不执行(安全保底)"
assert_contains "$OUT" "failed=0" "纯逻辑测试无失败项"

# 06 票纯逻辑断言(同一 runner 输出;ProxyConformanceTests:Port 假件 / RESTClient / proxy.status 域逻辑)
echo "--- 断言组 1b:06 票插件域逻辑纯逻辑(ProxyConformanceTests)---"
assert_contains "$OUT" "PROXY_TESTS passed=" "06 纯逻辑套件已运行(ProxyConformanceTests)"
assert_contains "$OUT" "假 ProcessPort:拉起后探活为真" "①ProcessPort 假件:拉起→探活为真"
assert_contains "$OUT" "假 ProcessPort:终止后探活为假" "①ProcessPort 假件:终止→探活为假"
assert_contains "$OUT" "假 ProcessPort:回收调用被记录(反孤儿可核验)" "①ProcessPort 假件:回收调用被记录"
assert_contains "$OUT" "假 ProcessPort:外部死亡后探活为假(健康检查基石)" "①ProcessPort 假件:外部死亡可检测"
assert_contains "$OUT" "REST 客户端:解析 /configs → mode=rule" "②REST 解析:mode"
assert_contains "$OUT" "REST 客户端:解析 /configs → mixed-port=7890" "②REST 解析:监听端口"
assert_contains "$OUT" "REST 客户端:解析 /proxies → 当前节点 STUB-NODE" "②REST 解析:当前节点"
assert_contains "$OUT" "status 域逻辑:内核存活 → running=true" "③status 域逻辑:内核存活→反映真实"
assert_contains "$OUT" "内核死亡 → running=false(如实未运行,不报错)" "③status 域逻辑:内核死亡→如实未运行(退出码 0)"
assert_contains "$OUT" "无内核句柄 → running=false" "③status 域逻辑:无内核句柄→如实未运行"

# 07 票纯逻辑断言(同一 runner 输出;SystemProxyConformanceTests:快照/接管/还原,注入内存假 NetworkConfigPort)
echo "--- 断言组 1c:07 票系统代理快照/接管/还原纯逻辑(SystemProxyConformanceTests)---"
assert_contains "$OUT" "07 快照:capture 捕获全部服务" "①快照:capture 捕获各服务代理原状态"
assert_contains "$OUT" "07 快照:capture 记录 Ethernet 原第三方 HTTP 代理" "①快照:记录原第三方代理(开关+host+port)"
assert_contains "$OUT" "均指向内核端口 127.0.0.1:7890" "②接管:各服务 HTTP/HTTPS/SOCKS 指向内核端口"
assert_contains "$OUT" "原本第三方代理→精确还原成第三方 203.0.113.9:8080(不是一律关闭)" "③还原:原本第三方代理→还原成第三方(非关闭)"
assert_contains "$OUT" "原本关闭的 SOCKS → 还原成关闭" "③还原:原本关闭→还原关闭"
assert_contains "$OUT" "还原后再次快照 == 接管前快照(终态精确复原)" "③还原:终态==接管前快照"
assert_contains "$OUT" "重复 enable 不覆盖首次快照" "④幂等:重复 enable 不覆盖首次快照"
assert_contains "$OUT" "内核端口未就绪时 enable 报 capability_failed(退出码5,不崩)" "⑤内核端口未就绪→enable 报业务失败(不崩)"
assert_contains "$OUT" "还原覆盖接管后新增的服务→回到接管前第三方代理(不残留指向内核死端口)" "④'重放漏洞修复:接管后新增服务也进快照、能被还原(不残留死端口)"

# 08 票纯逻辑 + 执行编排断言(同一 runner 输出;CrashRecoveryConformanceTests:判定五分支 + reap 孤儿 + 不变式,注入假件)
echo "--- 断言组 1d:08 票崩溃自愈判定/执行纯逻辑(CrashRecoveryConformanceTests)---"
# 判定五分支(纯函数 SelfHealDecision.decide):
assert_contains "$OUT" "08 自愈判定:无持久化标记 → clean(无操作)" "①判定:无标记→clean"
assert_contains "$OUT" "08 自愈判定:有标记但代理已不指向我方端口 → 用户手动改过(不覆盖,只清标记)" "②判定:用户手动改过代理→不覆盖只清标记"
assert_contains "$OUT" "08 自愈判定:残留接管 + 内核可健康重启 → 恢复接管(重指存活端口)" "③a 判定:残留+可重启→恢复接管"
assert_contains "$OUT" "08 自愈判定:残留接管 + 内核不可健康重启 → 还原快照(降级直连)" "③b 判定:残留+不可重启→还原快照"
assert_contains "$OUT" "08 自愈判定:代理指向我方端口且端口仍活 → 校正标记(视为正常)" "④判定:指向且端口活→校正标记"
# 执行编排(经 ProxyPlugin.selfHeal + 假件):恢复/还原/用户改过/无标记 + 孤儿先 reap。
assert_contains "$OUT" "08 孤儿清理:上世代残留内核 pid 4242 被先 reap(恢复前清孤儿)" "⑤孤儿 pid→自愈前先 reap(还 06 反孤儿债)"
assert_contains "$OUT" "08 恢复接管:系统代理指向存活端口 127.0.0.1:7890(内核已重启)" "执行:恢复接管→代理指向存活端口"
assert_contains "$OUT" "08 还原快照:精确还原成接管前第三方代理 203.0.113.9:8080(非一律关闭)" "执行:还原快照→精确复原第三方代理"
assert_contains "$OUT" "08 用户改过:绝不覆盖用户设置(用户的第三方代理 198.51.100.5:1080 原封不动)" "执行:用户改过→不覆盖用户设置"
assert_contains "$OUT" "08 clean:无标记时不写系统代理(提前返回,避免无谓触达真 networksetup)" "执行:无标记→不触达 networksetup"
# 核心不变式:任一自愈路径后系统代理都不指向死端口(恢复→存活端口 / 还原→直连-第三方 / 用户改过→尊重用户)。
assert_contains "$OUT" "08 不变式(恢复):恢复接管后有存活受管内核" "核心不变式(恢复路径):不指向死端口"
assert_contains "$OUT" "08 不变式(还原):还原后系统代理不再指向死端口 127.0.0.1:7890" "核心不变式(还原路径):不指向死端口"
assert_contains "$OUT" "08 不变式(用户改过):终态不指向我方死端口 7890" "核心不变式(用户改过路径):不指向死端口"
# code-review 修复:pid 身份核验(修盲杀)+ 还原失败保留标记(修清标记)+ 读代理失败 deferred(修误判)。
assert_contains "$OUT" "08 身份核验:路径不符(pid 已复用为无辜进程)→ 判为非我方 → 不 reap" "修盲杀·纯逻辑:pid 路径不符→不 reap"
assert_contains "$OUT" "08 身份核验:读不到当前路径(pid 已死 / EPERM 非本用户进程)→ 不 reap" "修盲杀·纯逻辑:读不到路径/EPERM→不 reap"
assert_contains "$OUT" "08 修盲杀:持久化 pid 身份不符(路径≠记录内核路径)→ 绝不 reap(不杀无辜进程)" "修盲杀·执行:身份不符 pid 绝不被 SIGKILL"
assert_contains "$OUT" "08 修盲杀:自愈后系统代理不再指向死端口(网络照常复原)" "修盲杀·执行:不杀之余网络仍自愈(不指向死端口)"
assert_contains "$OUT" "08 修清标记 bug:还原失败 → 保留持久化标记(clearCount=0),下次启动重试" "修清标记:还原失败→保留标记待重试(不留死端口后清标记)"
assert_contains "$OUT" "08 修误判:读当前系统代理失败 → deferred(保守中止,不误判用户改过)" "修误判:读代理失败→deferred 保留标记,不误判 userChanged"

# 09 票纯逻辑断言(同一 runner 输出;ProxyConformanceTests 09 子测 + RegistryConformanceTests allowedValues):
#   控制面 REST 写/读(mode.set/node.select 构造对的 PUT;groups.list 解析;latency 逐节点 + 超时标注)+ 四能力风险级/别名/allowedValues。
echo "--- 断言组 1e:09 控制面能力包纯逻辑(REST 写读 + 能力暴露 + allowedValues 校验)---"
assert_contains "$OUT" "09 groups.list:解析出分组 PROXY(含候选节点 STUB-NODE/NODE-B/SLOW-NODE)" "09 纯逻辑:groups.list 解析组/候选"
assert_contains "$OUT" "09 groups.list:PROXY 当前选中 now=STUB-NODE" "09 纯逻辑:groups.list 解析 now"
assert_contains "$OUT" "09 mode.set:构造对的 PATCH /configs(body mode=global)" "09 纯逻辑:mode.set 构造对的 PATCH /configs(body;真核动词)"
assert_contains "$OUT" "09 node.select:构造对的 PUT /proxies/PROXY(body name=NODE-B)" "09 纯逻辑:node.select 构造对的 PUT /proxies/<g>(body)"
assert_contains "$OUT" "09 latency:逐节点延迟解析(STUB-NODE=120ms)" "09 纯逻辑:latency 逐节点延迟解析"
assert_contains "$OUT" "09 latency:超时节点如实标注(SLOW-NODE delayMs=nil, timeout=true)" "09 纯逻辑:latency 超时节点如实标注"
assert_contains "$OUT" "09 能力暴露:proxy.groups.list=safe cliAlias[proxy,groups] 无入参" "09 纯逻辑:groups.list=safe + cliAlias"
assert_contains "$OUT" "09 能力暴露:proxy.latency.test=safe cliAlias[proxy,ping]" "09 纯逻辑:latency.test=safe + cliAlias"
assert_contains "$OUT" "09 能力暴露:proxy.mode.set=normal cliAlias[proxy,mode]" "09 纯逻辑:mode.set=normal + cliAlias"
assert_contains "$OUT" "09 能力暴露:proxy.mode.set 的 mode 声明 allowedValues[rule,global,direct]" "09 纯逻辑:mode 参数带 allowedValues"
assert_contains "$OUT" "09 能力暴露:proxy.node.select=normal cliAlias[proxy,node]" "09 纯逻辑:node.select=normal + cliAlias"
assert_contains "$OUT" "09 allowedValues:非法取值(bogus)→ invalid_params(退出码6)" "09 纯逻辑:allowedValues 非法值→invalid_params"
assert_contains "$OUT" "09 allowedValues:合法取值(global)放行执行" "09 纯逻辑:allowedValues 合法值放行"
assert_contains "$OUT" "09 防呆:超大有限 timeout(1e300)→ invalid_params(不 Int(Double) 越界崩宿主)" "09 纯逻辑:latency timeout 越界防呆(不崩,invalid_params)"

# 10 票纯逻辑断言(同一 runner 输出;SubscriptionConformanceTests + RegistryConformanceTests 的 F2:id 生成/状态机/回滚/损坏/确认收到 input)
echo "--- 断言组 1f:10 订阅管理状态机纯逻辑(id 生成/list/activate/update+回滚/add/损坏/F2 确认收 input)---"
# F1 id 生成(确定性 + 抗碰撞 + 空名拒绝)
assert_contains "$OUT" "10 F1 id:同名(大小写不敏感)→ 同 id" "10 纯逻辑 F1:同名→同 id"
assert_contains "$OUT" "10 F1 id:两个不同非 ASCII 名 → 不同 id(消除碰撞)" "10 纯逻辑 F1:异名(非ASCII)→异 id(消碰撞)"
assert_contains "$OUT" "10 F1 add:空/纯空白名 → invalidParams(退出码6)" "10 纯逻辑 F1:空名→invalidParams(6)"
assert_contains "$OUT" "10 F1 add:空名先于任何 I/O 拒绝(未 fetch、未写 config/清单)" "10 纯逻辑 F1:空名不留痕"
# list / add
assert_contains "$OUT" "10 list:空清单 → active=null、subscriptions 为空" "10 纯逻辑:list 空清单"
assert_contains "$OUT" "10 add:新增订阅成功(added=true,id 带 slug 前缀 sub-a-)" "10 纯逻辑:add 新增(slug 前缀)"
assert_contains "$OUT" "10 add:add 后 active 仍为 null(不自动激活)" "10 纯逻辑:add 不自动激活"
assert_contains "$OUT" "10 add:同 name 再 add → 同 id(确定性)" "10 纯逻辑:add 同 name 同 id"
assert_contains "$OUT" "10 add:upsert 同 name 覆盖=替换源(仍 1 条)" "10 纯逻辑:add upsert 替换源"
assert_contains "$OUT" "10 add:拉取失败不留痕(未写 config、未写清单)" "10 纯逻辑:add 拉取失败不留痕"
assert_contains "$OUT" "10 add:空内容 → 业务失败" "10 纯逻辑:add 空内容业务失败"
# activate
assert_contains "$OUT" "10 activate:激活 A 成功(activated=true,active→idA)" "10 纯逻辑:activate 成功切换"
assert_contains "$OUT" "10 activate:已是 active 幂等成功且不重复重载(reload 计数不变)" "10 纯逻辑:activate 幂等不重载"
assert_contains "$OUT" "10 activate:切到 B 成功(active→idB)" "10 纯逻辑:activate 切换到 B"
assert_contains "$OUT" "10 activate:不存在 id → 业务失败且 active 不变" "10 纯逻辑:activate not-found 不改 active"
assert_contains "$OUT" "10 activate:重载失败后 active 不变(无半态,仍未激活)" "10 纯逻辑:activate 重载失败无半态"
# update + 回滚(含 F6 回滚自身失败)
assert_contains "$OUT" "10 update:激活项更新成功(updated=true,带 lastUpdatedAt)" "10 纯逻辑:update 激活项生效"
assert_contains "$OUT" "10 update:拉取失败什么都没改(未写 config,旧配置原封不动)" "10 纯逻辑:update 拉取失败什么都不改"
assert_contains "$OUT" "10 update:空内容什么都没改(未写 config)" "10 纯逻辑:update 空内容什么都不改"
assert_contains "$OUT" "10 update 回滚:配置回退为旧 OLD(内核带回已知 good)" "10 纯逻辑:update 回滚 config 回退旧"
assert_contains "$OUT" "10 update 回滚:saveConfig 序列 [新,旧] 且末次写回旧字节" "10 纯逻辑:update 回滚写序列[新,旧]"
assert_contains "$OUT" "10 update 回滚:尝试重载旧配置(reload 共 2 次:新失败 + 回滚旧)" "10 纯逻辑:update 回滚尝试重载旧"
assert_contains "$OUT" "10 F6 回滚自身失败:写回旧失败则不再发第二次 reload(reload 仅 1 次)" "10 纯逻辑 F6:回滚写失败不再发二次 reload"
# F5 损坏清单
assert_contains "$OUT" "10 F5 损坏清单:list → capabilityFailed(不臆造空清单)" "10 纯逻辑 F5:损坏清单 list 业务失败"
assert_contains "$OUT" "10 F5 损坏清单:未发生 saveCatalog 覆盖(不抹掉用户数据)" "10 纯逻辑 F5:损坏清单不覆盖(护用户数据)"
# F2 确认回调收到 input(不再盲批)
assert_contains "$OUT" "10 F2:dangerous 确认回调确实收到本次请求的 input(不再盲批)" "10 纯逻辑 F2:确认层收到 input(消除盲批)"
# 能力暴露
assert_contains "$OUT" "10 能力暴露:proxy.subscription.add=dangerous 需必填 name+source" "10 纯逻辑:add=dangerous+必填 name/source"

# --- 断言组 2:list 纵切 E2E(aa capabilities list ⇄ 宿主 UDS)---
echo "--- 断言组 2:list E2E(起真宿主)---"
# 先清场:确保无旧宿主 / 旧 socket(轮询等真死 + 删残留,取代盲 sleep)
teardown_hosts

# (2a) 宿主未运行 → aa 明确错误 + 非零退出码(host 不可达=4)
ERR="$("$BIN/aa" capabilities list 2>&1 >/dev/null)"; RC=$?
assert_exit 4 $RC "宿主未运行时 aa capabilities list 退出码=4(host 不可达)"
assert_contains "$ERR" "host 不可达" "宿主未运行时 stderr 有明确错误"

# (2a2) 05 票:宿主未运行 UX 正式化 —— --json 时 stdout 机读错误信封(host_unreachable)+ stderr 人读提示 + 退出码 4。
#       这套对所有需要连宿主的命令一致生效(此处用 call 代证;域子命令/describe 同走 roundTrip 底座)。
"$BIN/aa" capabilities call demo.echo --json >"$BUILD/hostdown.out" 2>"$BUILD/hostdown.err"; RC=$?
HD_OUT="$(cat "$BUILD/hostdown.out")"; HD_ERR="$(cat "$BUILD/hostdown.err")"
echo "    宿主未运行 call --json: stdout=$HD_OUT | stderr=$HD_ERR"
assert_exit 4 $RC "宿主未运行时 call --json 退出码=4"
assert_contains "$HD_OUT" '"code":"host_unreachable"' "宿主未运行时 --json stdout 机读错误信封(host_unreachable)"
assert_contains "$HD_OUT" '"ok":false' "宿主未运行时 --json 信封 ok=false"
assert_contains "$HD_ERR" "宿主未运行" "宿主未运行时 stderr 人读提示含启动指引"

# 起宿主(accessory app,stdout/stderr 收进日志)
"$HOST_BIN" > "$HOSTLOG" 2>&1 &
HOST_PID=$!
# 从 job 表摘除:pkill 清场时 shell 不再打印 "Terminated: 15"(PID 仍有效,kill -0 / pkill 照常工作)。
disown "$HOST_PID" 2>/dev/null || true

# 就绪等待(窗口 40s;区分启动即死 vs 起得慢,失败自带日志 dump)
wait_host_ready "$HOST_PID"

# (2b) 宿主进程起来 + UDS 在监听(状态栏视觉可见属人工/快照,此处以「进程活着 + socket 在监听」代证)
if [ "$SOCK_UP" -eq 1 ] && kill -0 "$HOST_PID" 2>/dev/null; then
  echo "PASS: 宿主进程起来且 UDS 在监听($SOCK)"; PASS=$((PASS+1))
else
  echo "FAIL: 宿主未就绪(socket_up=$SOCK_UP, pid=$HOST_PID)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# (2c) aa capabilities list --json:退出 0 + stdout 含 demo 能力的 id / risk / schema 摘要
if [ "$SOCK_UP" -eq 1 ]; then
  OUT="$("$BIN/aa" capabilities list --json 2>/dev/null)"; RC=$?
  echo "    aa 输出: $OUT"
  assert_exit 0 $RC "aa capabilities list --json 退出码"
  assert_contains "$OUT" '"id":"demo.echo"' "list --json 含 demo.echo 的 id"
  assert_contains "$OUT" '"risk":"safe"' "list --json 含 risk=safe(RiskLevel 经 Codable 编码走一遭)"
  assert_contains "$OUT" '"schemaSummary"' "list --json 含 schemaSummary 键"
  assert_contains "$OUT" 'message' "list --json 携带 schema 摘要内容(input message …)"
else
  echo "FAIL: 宿主未就绪,跳过 list --json 断言(计为失败)"; FAIL=$((FAIL+1))
fi

# --- 断言组 2':describe / call 纵切 E2E(退出码 0/5/6 逐码)---
if [ "$SOCK_UP" -eq 1 ]; then
  echo "--- 断言组 2':describe / call E2E(03 票主体)---"

  # (2d) describe demo.echo --json:退出 0 + 输出含结构化 parameters(name/type/required),足以构造调用
  OUT="$("$BIN/aa" capabilities describe demo.echo --json 2>/dev/null)"; RC=$?
  echo "    describe 输出: $OUT"
  assert_exit 0 $RC "describe demo.echo --json 退出码=0"
  assert_contains "$OUT" '"parameters"' "describe 输出含 parameters 键"
  assert_contains "$OUT" '"name":"message"' "describe 参数含 name=message"
  assert_contains "$OUT" '"type":"string"' "describe 参数含 type=string"
  assert_contains "$OUT" '"required":true' "describe 参数含 required=true(足以让 agent 构造调用)"

  # (2e) safe call 成功:call demo.echo --input '{"message":"hi"}' → 退出 0 + 回显 hi
  OUT="$("$BIN/aa" capabilities call demo.echo --input '{"message":"hi"}' --json 2>/dev/null)"; RC=$?
  echo "    echo 输出: $OUT"
  assert_exit 0 $RC "call demo.echo(safe)退出码=0"
  assert_contains "$OUT" '"echo":"hi"' "call demo.echo 结果含回显 echo=hi"

  # (2f) normal call 成功且零 GUI:call demo.note.set → 退出 0 + set=true(headless 下自然无 GUI 阻塞)
  OUT="$("$BIN/aa" capabilities call demo.note.set --input '{"key":"k","value":"v"}' --json 2>/dev/null)"; RC=$?
  echo "    note.set 输出: $OUT"
  assert_exit 0 $RC "call demo.note.set(normal)退出码=0(零 GUI 打断)"
  assert_contains "$OUT" '"set":true' "call demo.note.set 结果含 set=true"

  # (2g) schema 校验失败:缺必填 message → 退出 6 + 统一错误信封含 error.code=missing_parameter
  OUT="$("$BIN/aa" capabilities call demo.echo --input '{}' --json 2>/dev/null)"; RC=$?
  echo "    缺参输出: $OUT"
  assert_exit 6 $RC "call 缺必填参数退出码=6(协议/校验错)"
  assert_contains "$OUT" '"code":"missing_parameter"' "缺参走统一 JSON 错误信封(error.code=missing_parameter)"

  # (2h) schema 校验失败:类型不符(message 给数字)→ 退出 6 + error.code=type_mismatch
  OUT="$("$BIN/aa" capabilities call demo.echo --input '{"message":123}' --json 2>/dev/null)"; RC=$?
  echo "    类型不符输出: $OUT"
  assert_exit 6 $RC "call 参数类型不符退出码=6"
  assert_contains "$OUT" '"code":"type_mismatch"' "类型不符走统一错误信封(error.code=type_mismatch)"

  # (2i) 未知能力 → 退出 6 + error.code=unknown_capability
  OUT="$("$BIN/aa" capabilities call demo.nope --input '{}' --json 2>/dev/null)"; RC=$?
  echo "    未知能力输出: $OUT"
  assert_exit 6 $RC "call 未知能力退出码=6"
  assert_contains "$OUT" '"code":"unknown_capability"' "未知能力 error.code=unknown_capability"

  # (2j) 业务失败:message=='boom' → 退出 5 + error.code=capability_failed
  OUT="$("$BIN/aa" capabilities call demo.echo --input '{"message":"boom"}' --json 2>/dev/null)"; RC=$?
  echo "    业务失败输出: $OUT"
  assert_exit 5 $RC "call 业务失败退出码=5"
  assert_contains "$OUT" '"code":"capability_failed"' "业务失败 error.code=capability_failed"

  # (2k) 用法错(客户端侧):--input 非法 JSON → 退出 1(未触达宿主语义)
  ERR="$("$BIN/aa" capabilities call demo.echo --input 'not-json' --json 2>&1 >/dev/null)"; RC=$?
  assert_exit 1 $RC "call --input 非法 JSON 退出码=1(用法错)"
  assert_contains "$ERR" "合法 JSON" "非法 --input 有明确 stderr 提示"

  # (2k2) 用法错:call 缺 <id> → 退出 1
  "$BIN/aa" capabilities call >/dev/null 2>&1; RC=$?
  assert_exit 1 $RC "call 缺 <id> 退出码=1(用法错)"

  # --- 05 票:域子命令 ≡ call 底座(同路由、同输出、同退出码)---
  echo "--- 断言组 2'''':域子命令 ≡ call 底座(05 票)---"

  # (2L) aa demo echo --message hi 与 capabilities call demo.echo --input '{"message":"hi"}' 逐字节一致 + 都 exit 0
  DOUT="$("$BIN/aa" demo echo --message hi --json 2>/dev/null)"; DRC=$?
  COUT="$("$BIN/aa" capabilities call demo.echo --input '{"message":"hi"}' --json 2>/dev/null)"; CRC=$?
  echo "    域子命令输出=$DOUT | call 底座输出=$COUT"
  assert_exit 0 $DRC "域子命令 aa demo echo --message hi 退出码=0"
  assert_exit 0 $CRC "对照 call demo.echo 退出码=0"
  if [ "$DOUT" = "$COUT" ] && [ -n "$DOUT" ]; then
    echo "PASS: 域子命令与 call 底座输出逐字节一致($DOUT)"; PASS=$((PASS+1))
  else
    echo "FAIL: 域子命令与 call 输出不一致(域='$DOUT' vs call='$COUT')"; FAIL=$((FAIL+1))
  fi
  # (2L2) 参数类型强转(string):--message hi 按 schema 声明的 string 强转进 input,回显正确
  assert_contains "$DOUT" '"echo":"hi"' "域子命令 string 参数强转正确(echo=hi)"

  # (2L2b) 强转按 schema 声明类型分派:message 声明为 string,故 --message inf 原样承载为字符串 "inf"
  #        (不误当 number 解析;这也间接把守 number 分支的 inf/nan 不会误漏到 string 参数上)。
  DINF="$("$BIN/aa" demo echo --message inf --json 2>/dev/null)"; DRCI=$?
  assert_exit 0 $DRCI "域子命令 --message inf(string 参数)退出码=0(按声明类型分派,不当 number)"
  assert_contains "$DINF" '"echo":"inf"' "string 参数 inf 原样承载为字符串(强转 schema-type-driven)"
  # NOTE(05,强转覆盖边界):number(inf/nan→退出码1)、bool、object/array 分支需"非 string 声明参数"才能 E2E 驱动;
  #   demo 注册表参数全为 string 且本票不改注册表 → 这三类分支无法在此 E2E 断言。isFinite 钳制已在 coerceArgument 落地
  #   (非有限 number→failUsage 退出码1,杜绝旧 bug:inf/nan 经 JSONEncoder 抛错被误报退出码4);待 06/09 引入真实
  #   number/bool 参数时补 E2E。此处以 string 分派证明强转"按声明类型"工作。
  echo "    NOTE(05): number/bool/object/array 强转分支待 06/09 的真实类型参数补 E2E(demo 全 string,本票不改注册表)"

  # (2L2c) 选项值不能是下一个旗标:aa demo echo --message --json → 缺值用法错(退出码 1),不把 --json 吞成值
  "$BIN/aa" demo echo --message --json >/dev/null 2>&1; RCF=$?
  assert_exit 1 $RCF "域子命令选项值为旗标(--message --json)→ 退出码=1(不吞旗标当值)"

  # (2L2d) 未知 --参数(能力未声明)→ 退出码 1(badArgument)
  "$BIN/aa" demo echo --nope x --json >/dev/null 2>&1; RCU=$?
  assert_exit 1 $RCU "域子命令未知 --参数(未声明)→ 退出码=1"

  # (2L3) 多级动词映射:aa demo note set → demo.note.set,并执行(set=true)
  DOUT2="$("$BIN/aa" demo note set --key k --value v --json 2>/dev/null)"; DRC2=$?
  echo "    多级域子命令输出=$DOUT2"
  assert_exit 0 $DRC2 "多级域子命令 aa demo note set 退出码=0(映射 demo.note.set)"
  assert_contains "$DOUT2" '"set":true' "多级域子命令映射到 demo.note.set 并执行(set=true)"

  # (2L4) 域子命令校验错也走同一退出码契约:demo echo 缺必填(不带 --message)→ 退出 6 + missing_parameter(与 call 一致)
  DOUT3="$("$BIN/aa" demo echo --json 2>/dev/null)"; DRC3=$?
  assert_exit 6 $DRC3 "域子命令缺必填参数退出码=6(与 call 底座同契约)"
  assert_contains "$DOUT3" '"code":"missing_parameter"' "域子命令缺参走同一 error.code=missing_parameter"

  # (2M) 未知域/动词 → 退出码 1(用法错,非协议错 6)+ 机读 unknown_command 信封 + 可发现提示(区别于 call 未知能力=6)
  UOUT="$("$BIN/aa" bogusdomain frobnicate --json 2>"$BUILD/unknown.err")"; URC=$?
  UERR="$(cat "$BUILD/unknown.err")"
  echo "    未知域 stdout=$UOUT | stderr=$UERR"
  assert_exit 1 $URC "未知域子命令退出码=1(人体工学层用法错,非协议错 6)"
  assert_contains "$UOUT" '"code":"unknown_command"' "未知域 --json stdout 机读信封 error.code=unknown_command"
  assert_contains "$UOUT" '"ok":false' "未知域 --json 信封 ok=false"
  assert_contains "$UERR" "aa capabilities list" "未知域给出可发现提示(指向 aa capabilities list)"
else
  echo "FAIL: 宿主未就绪,跳过 describe/call E2E(计为失败)"; FAIL=$((FAIL+1))
fi

# 清场:杀宿主 + 删 socket(轮询等真死;trap 亦会兜底)
teardown_hosts

# --- 断言组 2''':dangerous 宿主确认纵切 E2E(04 票主体:无人值守两分支 + 反向不可绕过)---
echo "--- 断言组 2''':dangerous 宿主确认 E2E(04 票)---"

# 裸 UDS 直连客户端(python3):连 socket → 写一行 JSON 请求 → 读一行响应 → 打印。用于「绕过 aa 直连」反向证明。
RAW_CLIENT="$BUILD/raw_uds_client.py"
cat > "$RAW_CLIENT" <<'PY'
import socket, sys
sock_path, req = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(sock_path)
s.sendall((req + "\n").encode("utf-8"))
buf = b""
while b"\n" not in buf:
    chunk = s.recv(4096)
    if not chunk:
        break
    buf += chunk
sys.stdout.write(buf.decode("utf-8", "replace"))
s.close()
PY

# 起宿主(带指定 AA_CONFIRM_AUTO)并等 socket 就绪。置全局 HOST_PID / SOCK_UP。$1=模式(deny/approve)。
# 无内核/无接管:teardown_hosts 已清默认标记 → 启动自愈恒 clean → 快速就绪(dangerous E2E 不涉及接管)。
start_host_confirm() {
  local mode="$1"
  teardown_hosts
  AA_CONFIRM_AUTO="$mode" "$HOST_BIN" > "$HOSTLOG" 2>&1 &
  HOST_PID=$!
  disown "$HOST_PID" 2>/dev/null || true
  wait_host_ready "$HOST_PID"
}

# (D1) AA_CONFIRM_AUTO=deny 起宿主 → aa call demo.wipe → 退出码 2(denied)
start_host_confirm deny
if [ "$SOCK_UP" -eq 1 ]; then
  OUT="$("$BIN/aa" capabilities call demo.wipe --json 2>/dev/null)"; RC=$?
  echo "    deny 分支输出: $OUT"
  assert_exit 2 $RC "AA_CONFIRM_AUTO=deny → aa call demo.wipe 退出码=2(denied)"
  assert_contains "$OUT" '"code":"denied"' "deny 分支统一错误信封 error.code=denied"
  # 反证「未执行」:deny 分支 aa 响应里绝不能出现 handler 成功标志 wiped(与裸 UDS D3 同等严谨度)
  if printf '%s' "$OUT" | grep -qF -- '"wiped"'; then
    echo "FAIL: deny 分支 aa 响应竟出现 wiped —— 疑似 handler 被执行!"; FAIL=$((FAIL+1))
  else
    echo "PASS: deny 分支 aa 响应未出现执行结果 wiped(handler 绝不执行)"; PASS=$((PASS+1))
  fi

  # (D3) 反向不可绕过:裸 UDS 直连(python3)构造 capabilities.call demo.wipe → 仍 denied、未执行
  RAW="$(python3 "$RAW_CLIENT" "$SOCK" '{"op":"capabilities.call","capability":"demo.wipe","input":{}}' 2>&1)"
  echo "    裸 UDS 直连响应: $RAW"
  assert_contains "$RAW" '"code":"denied"' "裸 UDS 直连 demo.wipe 仍被 denied(绕过 aa 也躲不过确认)"
  assert_contains "$RAW" '"ok":false' "裸 UDS 直连响应 ok=false"
  # 反证「未执行」:响应里绝不能出现 handler 成功标志 wiped(用显式 grep 退出码判,杜绝假绿)
  if printf '%s' "$RAW" | grep -qF -- '"wiped"'; then
    echo "FAIL: 裸 UDS 直连 demo.wipe 竟出现 wiped —— 疑似绕过确认执行了!"; FAIL=$((FAIL+1))
  else
    echo "PASS: 裸 UDS 直连 demo.wipe 未出现执行结果 wiped(确认未被绕过、未执行)"; PASS=$((PASS+1))
  fi

  # (D1b) 05 票:dangerous 域子命令与 call 同底座 → 同样经路由层确认,不得绕过。
  #        deny 下 `aa demo wipe --target …`(域形式)→ 仍 denied 退出码 2 且未执行(与 D1 对 call 一致)。
  DW="$("$BIN/aa" demo wipe --target disk9 --json 2>/dev/null)"; DWRC=$?
  echo "    dangerous 域子命令(deny)输出: $DW"
  assert_exit 2 $DWRC "dangerous 域子命令 aa demo wipe(deny)退出码=2(经确认层,未绕过)"
  assert_contains "$DW" '"code":"denied"' "dangerous 域子命令 deny 走同一确认层 error.code=denied"
  if printf '%s' "$DW" | grep -qF -- '"wiped"'; then
    echo "FAIL: dangerous 域子命令 deny 竟出现 wiped —— 疑似绕过确认!"; FAIL=$((FAIL+1))
  else
    echo "PASS: dangerous 域子命令 deny 未出现 wiped(域入口未绕过确认)"; PASS=$((PASS+1))
  fi
else
  echo "FAIL: deny 宿主未就绪,跳过 deny/反向断言(计为失败)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# (D2) AA_CONFIRM_AUTO=approve 起宿主 → aa call demo.wipe → 退出码 0 + 结果 wiped=true(handler 执行成功)
start_host_confirm approve
if [ "$SOCK_UP" -eq 1 ]; then
  OUT="$("$BIN/aa" capabilities call demo.wipe --input '{"target":"disk0"}' --json 2>/dev/null)"; RC=$?
  echo "    approve 分支输出: $OUT"
  assert_exit 0 $RC "AA_CONFIRM_AUTO=approve → aa call demo.wipe 退出码=0(批准执行)"
  assert_contains "$OUT" '"wiped":true' "approve 分支结果 wiped=true(批准后 handler 执行成功)"
  assert_contains "$OUT" '"target":"disk0"' "approve 分支结果回执 target=disk0"
else
  echo "FAIL: approve 宿主未就绪,跳过 approve 断言(计为失败)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# 清场:杀宿主 + 删 socket(轮询等真死;trap 亦兜底)
pkill -f "raw_uds_client.py" 2>/dev/null
teardown_hosts

# --- 断言组 2'':超时(退出码 3)—— 借 python3「只 accept 不回应」假监听器 + 短超时 ---
echo "--- 断言组 2'':超时 E2E(退出码 3)---"
cat > "$TIMEOUT_LISTENER" <<'PY'
import socket, os, sys, time
p = sys.argv[1]
try:
    os.unlink(p)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(p)
s.listen(4)
# 只 accept、绝不回写 → 客户端 SO_RCVTIMEO 到点判超时。被 pkill 收场。
while True:
    try:
        c, _ = s.accept()
        # 保持连接开着但不响应;睡一会儿即可(会被清场杀掉)。
        time.sleep(60)
    except Exception:
        break
PY
python3 "$TIMEOUT_LISTENER" "$SOCK" >/dev/null 2>&1 &
LISTENER_PID=$!
disown "$LISTENER_PID" 2>/dev/null || true
# 等假监听器就绪
LIS_UP=0
for _ in $(seq 1 50); do
  [ -S "$SOCK" ] && { LIS_UP=1; break; }
  kill -0 "$LISTENER_PID" 2>/dev/null || break
  sleep 0.2
done
if [ "$LIS_UP" -eq 1 ]; then
  # 短超时(1s)后应判超时 → 退出码 3
  ERR="$(AA_TIMEOUT_SECONDS=1 "$BIN/aa" capabilities call demo.echo --input '{"message":"hi"}' --json 2>&1 >/dev/null)"; RC=$?
  assert_exit 3 $RC "连上但宿主不回应 → 退出码=3(超时)"
  assert_contains "$ERR" "超时" "超时有明确 stderr 提示"
else
  echo "FAIL: 假监听器未就绪,跳过超时断言(计为失败)"; FAIL=$((FAIL+1))
fi
pkill -f "timeout_listener.py" 2>/dev/null
teardown_hosts

# --- 断言组 P:proxy.status 内核生命周期 E2E(06 票主体:真子进程 fake mihomo stub + 真 localhost REST)---
echo "--- 断言组 P:proxy.status 内核生命周期 E2E(06 票)---"
chmod +x "$STUB" 2>/dev/null
# 由 OS 分配一个空闲高位端口(避开常用端口 / 撞端口),交给内核 stub 监听、RESTClient 连接。
MIHOMO_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null)"
[ -z "$MIHOMO_PORT" ] && MIHOMO_PORT=48123
echo "    fake mihomo 控制端口 = $MIHOMO_PORT"

# 起宿主并注入内核 env:AA_MIHOMO_KERNEL_PATH → stub;AA_MIHOMO_CONTROL_PORT → 空闲端口。置全局 HOST_PID/SOCK_UP。
# teardown_hosts also-stub 已清默认标记 → 启动自愈恒 clean → 快速就绪(P/CP 场景不预置接管态)。
start_host_kernel() {
  teardown_hosts also-stub
  AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT" "$HOST_BIN" > "$HOSTLOG" 2>&1 &
  HOST_PID=$!
  disown "$HOST_PID" 2>/dev/null || true
  wait_host_ready "$HOST_PID"
}

# —— 场景 A:健康检查 + status 真实呈现(内核存活→反映真实;内核死亡→如实未运行且退出码 0)——
start_host_kernel
if [ "$SOCK_UP" -eq 1 ]; then
  # 等内核 REST 就绪(宿主拉起 stub、stub 绑定端口需一瞬):poll 直到 running:true(上限 ~10s)
  READY=0
  for _ in $(seq 1 50); do
    # 等 REST 真就绪(apiReachable:true),而非仅进程存活(running:true 在拉起瞬间即真、但 stub 尚未绑定端口)。
    if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then READY=1; break; fi
    sleep 0.2
  done
  if [ "$READY" -eq 1 ]; then
    echo "PASS: 宿主经 ProcessPort 拉起 fake mihomo,REST 就绪(随宿主启停)"; PASS=$((PASS+1))
  else
    echo "FAIL: 内核 REST 未在时限内就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
  fi

  # (P1) aa proxy status --json:退出 0 + 真实(stub)状态(running/端口/mode/节点),经真 localhost REST 读取
  SP="$("$BIN/aa" proxy status --json 2>/dev/null)"; PRC=$?
  echo "    aa proxy status(内核存活)输出: $SP"
  assert_exit 0 $PRC "aa proxy status --json(内核存活)退出码=0"
  assert_contains "$SP" '"running":true' "proxy status 反映内核存活(running=true)"
  assert_contains "$SP" '"mode":"rule"' "proxy status 经真 REST 反映真实模式(mode=rule)"
  assert_contains "$SP" '"mixedPort":7890' "proxy status 反映监听端口(mixedPort=7890)"
  assert_contains "$SP" '"node":"STUB-NODE"' "proxy status 反映当前节点(node=STUB-NODE)"

  # (P1b) 域子命令 ≡ capabilities call 底座:两种入口结果一致
  CP="$("$BIN/aa" capabilities call proxy.status --json 2>/dev/null)"; CPRC=$?
  assert_exit 0 $CPRC "capabilities call proxy.status --json 退出码=0"
  if [ "$SP" = "$CP" ] && [ -n "$SP" ]; then
    echo "PASS: 域子命令 aa proxy status ≡ capabilities call proxy.status 逐字节一致"; PASS=$((PASS+1))
  else
    echo "FAIL: proxy 域子命令与 call 底座输出不一致(域='$SP' vs call='$CP')"; FAIL=$((FAIL+1))
  fi

  # (P2) 健康检查:杀内核(stub)但宿主仍活 → 死亡可检测 → status 如实未运行、退出码 0(非报错)
  pkill -f "$KILLPAT_STUB" 2>/dev/null
  sleep 2
  SD="$("$BIN/aa" proxy status --json 2>/dev/null)"; DRC=$?
  echo "    aa proxy status(内核已死)输出: $SD"
  assert_exit 0 $DRC "内核死亡后 aa proxy status --json 退出码=0(如实呈现,非报错/非零)"
  assert_contains "$SD" '"running":false' "健康检查:内核死亡可检测,status 反映真实存活(running=false)"
else
  echo "FAIL: proxy 场景A 宿主未就绪(socket_up=$SOCK_UP)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# —— 场景 B:反孤儿(宿主退出必回收内核,零孤儿 stub)——
start_host_kernel
if [ "$SOCK_UP" -eq 1 ]; then
  READY=0
  for _ in $(seq 1 50); do
    # 等 REST 真就绪(apiReachable:true),而非仅进程存活(running:true 在拉起瞬间即真、但 stub 尚未绑定端口)。
    if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then READY=1; break; fi
    sleep 0.2
  done
  STUB_PIDS="$(pgrep -f "$KILLPAT_STUB")"
  echo "    场景B:宿主拉起的 fake mihomo pid(s)=[$STUB_PIDS]"
  if [ -n "$STUB_PIDS" ]; then
    echo "PASS: 宿主经 ProcessPort 拉起了 fake mihomo 子进程(pid: $STUB_PIDS)"; PASS=$((PASS+1))
  else
    echo "FAIL: 宿主未拉起 fake mihomo 子进程。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
  fi
  # 只杀宿主(SIGTERM,模拟宿主退出)——绝不直接碰 stub;stub 应被宿主退出钩子(atexit/信号)回收。
  pkill -f "$KILLPAT" 2>/dev/null
  sleep 2
  LEFT="$(pgrep -f "$KILLPAT_STUB")"
  if [ -z "$LEFT" ]; then
    echo "PASS: 宿主退出后无孤儿 fake mihomo 进程(反孤儿回收生效,零孤儿)"; PASS=$((PASS+1))
  else
    echo "FAIL: 宿主退出后仍有孤儿 stub 进程: $LEFT"; FAIL=$((FAIL+1)); pkill -9 -f "$KILLPAT_STUB" 2>/dev/null
  fi
else
  echo "FAIL: proxy 场景B 宿主未就绪(socket_up=$SOCK_UP)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# 清场:杀宿主 + stub(轮询等真死;trap 亦兜底)
teardown_hosts also-stub

# —— 场景 C:SIGTERM-忽略型内核经 terminate 仍被 SIGKILL 兜底回收(暴露"发完 SIGTERM 立刻 unrecord"的孤儿洞)——
# 内核以 --ignore-sigterm 运行(装 handler 吞掉 SIGTERM);宿主收 SIGUSR1 → 优雅退出 → reclaimKernel →
# ProcessPort.terminate:SIGTERM 被忽略 → 有界等待后 SIGKILL 兜底 → 内核被回收。旧 bug(发完 SIGTERM 立刻 unrecord)
# 会让该内核既不被 terminate 的 SIGKILL 兜到(未升级)、又从缓冲摘除(退出钩子够不着)→ 孤儿。修后必被回收、无孤儿。
echo "--- 断言组 P-C:SIGTERM-忽略型内核的 terminate SIGKILL 兜底 ---"
teardown_hosts also-stub
AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT" AA_MIHOMO_KERNEL_EXTRA_ARGS="--ignore-sigterm" \
  "$HOST_BIN" > "$HOSTLOG" 2>&1 &
HOST_PID=$!
disown "$HOST_PID" 2>/dev/null || true
wait_host_ready "$HOST_PID"
if [ "$SOCK_UP" -eq 1 ]; then
  READY=0
  for _ in $(seq 1 50); do
    if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then READY=1; break; fi
    sleep 0.2
  done
  STUB_PIDS="$(pgrep -f "$KILLPAT_STUB")"
  echo "    场景C:SIGTERM-忽略型内核 pid(s)=[$STUB_PIDS]"
  if [ -n "$STUB_PIDS" ]; then
    echo "PASS: 宿主拉起 SIGTERM-忽略型 fake mihomo(REST 就绪)"; PASS=$((PASS+1))
  else
    echo "FAIL: 未拉起 SIGTERM-忽略型 stub。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
  fi
  # 触发宿主优雅退出(SIGUSR1)→ 走 applicationWillTerminate → reclaimKernel → ProcessPort.terminate 完整回收路径。
  kill -USR1 "$HOST_PID" 2>/dev/null
  # terminate:SIGTERM(被忽略)→ ~1.5s 有界等待 → SIGKILL 兜底 → 回收;再加宿主退出时间。给足 6s。
  sleep 6
  LEFTC="$(pgrep -f "$KILLPAT_STUB")"
  if [ -z "$LEFTC" ]; then
    echo "PASS: SIGTERM-忽略型内核经 terminate 被 SIGKILL 兜底回收,无孤儿(反孤儿兜底真生效)"; PASS=$((PASS+1))
  else
    echo "FAIL: SIGTERM-忽略型内核成孤儿(terminate 兜底失效): $LEFTC"; FAIL=$((FAIL+1)); pkill -9 -f "$KILLPAT_STUB" 2>/dev/null
  fi
  if kill -0 "$HOST_PID" 2>/dev/null; then
    echo "FAIL: 宿主收 SIGUSR1 后未退出"; FAIL=$((FAIL+1)); pkill -f "$KILLPAT" 2>/dev/null
  else
    echo "PASS: 宿主经 SIGUSR1 优雅退出(走完 terminate 回收路径)"; PASS=$((PASS+1))
  fi
else
  echo "FAIL: proxy 场景C 宿主未就绪(socket_up=$SOCK_UP)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# 清场:杀宿主 + stub(轮询等真死;trap 亦兜底)
teardown_hosts also-stub

# --- 断言组 CP:控制面能力包 E2E(09 票主体:有状态 fake stub「改后读回」+ 逐节点测速 + normal 零 GUI + number 强转)---
# 姿态:start_host_kernel 起「宿主 + 有状态 fake mihomo stub」;**不设 AA_CONFIRM_AUTO**——mode.set/node.select 为 normal,
#   若误走 dangerous 确认会在 headless 挂起(→ 客户端超时退出码3);它们快速退出码0 即证明「normal 零 GUI 确认」。
#   CP 四能力只经 RESTClient 读/写内核,绝不触达 networksetup(真件被注入但从不被调用),不碰真系统。
echo "--- 断言组 CP:控制面能力包 E2E(09 票:模式/节点/组/测速,改后读回)---"
start_host_kernel
if [ "$SOCK_UP" -eq 1 ]; then
  READY=0
  for _ in $(seq 1 50); do
    if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then READY=1; break; fi
    sleep 0.2
  done
  if [ "$READY" -eq 1 ]; then echo "PASS: CP 内核 REST 就绪(控制面可读写)"; PASS=$((PASS+1)); else echo "FAIL: CP 内核 REST 未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1)); fi

  # (CP0) 元数据:四能力风险级 + cliAlias + allowedValues(经 wire 下发,读=safe / 改状态=normal)。
  DGL="$("$BIN/aa" capabilities describe proxy.groups.list --json 2>/dev/null)"
  assert_contains "$DGL" '"risk":"safe"' "CP0 proxy.groups.list 风险档=safe(只读)"
  assert_contains "$DGL" '"cliAlias":["proxy","groups"]' "CP0 proxy.groups.list cliAlias=[proxy,groups]"
  DLT="$("$BIN/aa" capabilities describe proxy.latency.test --json 2>/dev/null)"
  assert_contains "$DLT" '"risk":"safe"' "CP0 proxy.latency.test 风险档=safe(只读)"
  assert_contains "$DLT" '"cliAlias":["proxy","ping"]' "CP0 proxy.latency.test cliAlias=[proxy,ping]"
  assert_contains "$DLT" '"name":"timeout"' "CP0 proxy.latency.test 声明 timeout 参数(number 强转基石)"
  DMS="$("$BIN/aa" capabilities describe proxy.mode.set --json 2>/dev/null)"
  assert_contains "$DMS" '"risk":"normal"' "CP0 proxy.mode.set 风险档=normal(改状态,零 GUI 确认)"
  assert_contains "$DMS" '"cliAlias":["proxy","mode"]' "CP0 proxy.mode.set cliAlias=[proxy,mode]"
  assert_contains "$DMS" '"allowedValues":["rule","global","direct"]' "CP0 proxy.mode.set 描述含 allowedValues(agent 可知合法取值)"
  DNS="$("$BIN/aa" capabilities describe proxy.node.select --json 2>/dev/null)"
  assert_contains "$DNS" '"risk":"normal"' "CP0 proxy.node.select 风险档=normal(改状态,零 GUI 确认)"
  assert_contains "$DNS" '"cliAlias":["proxy","node"]' "CP0 proxy.node.select cliAlias=[proxy,node]"

  # (CP1) aa proxy groups(别名→proxy.groups.list):列出组/候选/当前选中(now)。
  GRP="$("$BIN/aa" proxy groups --json 2>/dev/null)"; GRPRC=$?
  echo "    aa proxy groups 输出: $GRP"
  assert_exit 0 $GRPRC "aa proxy groups(safe)退出码=0"
  assert_contains "$GRP" '"name":"PROXY"' "CP1 groups 列出分组 PROXY"
  assert_contains "$GRP" '"now":"STUB-NODE"' "CP1 groups 反映当前选中 now=STUB-NODE(初始)"
  assert_contains "$GRP" '"all":["STUB-NODE","NODE-B","SLOW-NODE"]' "CP1 groups 列出该组候选节点"

  # (CP2) aa proxy mode --mode global(别名→proxy.mode.set,normal,不设 AA_CONFIRM_AUTO 仍不挂):退出0 → 经 status 读回 mode==global(生效)。
  MSET="$("$BIN/aa" proxy mode --mode global --json 2>/dev/null)"; MSRC=$?
  echo "    aa proxy mode --mode global 输出: $MSET"
  assert_exit 0 $MSRC "aa proxy mode --mode global(normal)退出码=0(零 GUI 确认,不阻塞/不超时)"
  assert_contains "$MSET" '"set":true' "CP2 mode.set 报告已切换(set=true)"
  MRB="$("$BIN/aa" proxy status --json 2>/dev/null)"
  echo "    切模式后 proxy status 读回: $MRB"
  assert_contains "$MRB" '"mode":"global"' "CP2 改后读回:proxy.status 反映 mode==global(经 REST 读回,生效)"

  # (CP2b) 取值域约束:aa proxy mode --mode bogus → invalid_params(退出码6);内核状态不被改动(仍 global)。
  MBAD="$("$BIN/aa" proxy mode --mode bogus --json 2>/dev/null)"; MBRC=$?
  echo "    aa proxy mode --mode bogus 输出: $MBAD"
  assert_exit 6 $MBRC "CP2b mode.set 非法取值(bogus,不在 allowedValues)→ 退出码=6"
  assert_contains "$MBAD" '"code":"invalid_params"' "CP2b 非法取值走统一错误信封 error.code=invalid_params"
  MRB2="$("$BIN/aa" proxy status --json 2>/dev/null)"
  assert_contains "$MRB2" '"mode":"global"' "CP2b 非法取值被校验层拦下,未触达内核(mode 仍 global)"

  # (CP3) aa proxy node --group PROXY --node NODE-B(别名→proxy.node.select,normal):退出0 → 经 groups/status 读回该组 now==NODE-B。
  NSEL="$("$BIN/aa" proxy node --group PROXY --node NODE-B --json 2>/dev/null)"; NSRC=$?
  echo "    aa proxy node --group PROXY --node NODE-B 输出: $NSEL"
  assert_exit 0 $NSRC "aa proxy node(normal)退出码=0(零 GUI 确认,不阻塞/不超时)"
  assert_contains "$NSEL" '"selected":true' "CP3 node.select 报告已选中(selected=true)"
  GRB="$("$BIN/aa" proxy groups --json 2>/dev/null)"
  echo "    选节点后 aa proxy groups 读回: $GRB"
  assert_contains "$GRB" '"now":"NODE-B"' "CP3 改后读回:proxy.groups.list 反映 PROXY now==NODE-B(生效)"
  SRB="$("$BIN/aa" proxy status --json 2>/dev/null)"
  assert_contains "$SRB" '"node":"NODE-B"' "CP3 改后读回:proxy.status 反映当前节点==NODE-B(经 REST 读回)"

  # (CP4) aa proxy ping --group PROXY(别名→proxy.latency.test,safe):返回逐节点延迟,超时节点如实标注。
  PING="$("$BIN/aa" proxy ping --group PROXY --json 2>/dev/null)"; PINGRC=$?
  echo "    aa proxy ping --group PROXY 输出: $PING"
  assert_exit 0 $PINGRC "aa proxy ping(safe)退出码=0"
  assert_contains "$PING" '"delayMs":120,"node":"STUB-NODE"' "CP4 测速:逐节点延迟(STUB-NODE=120ms)"
  assert_contains "$PING" '"node":"SLOW-NODE","timeout":true' "CP4 测速:超时节点如实标注(SLOW-NODE timeout=true)"
  assert_contains "$PING" '"delayMs":null,"node":"SLOW-NODE"' "CP4 测速:超时节点 delayMs=null(不臆造 0)"

  # (CP5) number 参数强转 E2E(补 05 缺口):--timeout 5000 正确强转为 number;--timeout inf/nan → 退出码1(isFinite 钳制首次真被行使)。
  PT="$("$BIN/aa" proxy ping --group PROXY --timeout 5000 --json 2>/dev/null)"; PTRC=$?
  assert_exit 0 $PTRC "CP5 aa proxy ping --timeout 5000(number 强转正确)退出码=0"
  assert_contains "$PT" '"node":"STUB-NODE"' "CP5 --timeout 5000 强转成功、正常返回测速结果"
  "$BIN/aa" proxy ping --group PROXY --timeout inf --json >/dev/null 2>&1; PIRC=$?
  assert_exit 1 $PIRC "CP5 aa proxy ping --timeout inf → 退出码=1(非有限 number 被 isFinite 钳制)"
  "$BIN/aa" proxy ping --group PROXY --timeout nan --json >/dev/null 2>&1; PNRC=$?
  assert_exit 1 $PNRC "CP5 aa proxy ping --timeout nan → 退出码=1(非有限 number 被 isFinite 钳制)"

  # (CP5b) 宿主侧越界防呆(修 Int(Double) trap DoS 洞):经 capabilities call --input 原样 JSON(绕过 CLI 强转,直击宿主 handler)
  #   传超大**有限** timeout=1e300(CLI 只钳 isFinite、不钳范围,故此洞在宿主侧)→ 宿主**不崩**、返回 invalid_params(退出码6)。
  OVF="$("$BIN/aa" capabilities call proxy.latency.test --input '{"group":"PROXY","timeout":1e300}' --json 2>/dev/null)"; OVFRC=$?
  echo "    超大 timeout(1e300)输出: $OVF"
  assert_exit 6 $OVFRC "CP5b 超大有限 timeout(1e300)→ 退出码=6(宿主侧越界防呆,非 Int(Double) trap 崩)"
  assert_contains "$OVF" '"code":"invalid_params"' "CP5b 越界 timeout 返回 invalid_params(而非崩宿主)"
  # 反证宿主仍活:随后再发正常请求应成功(证明宿主没被这次越界请求 DoS 崩)。
  ALIVE="$("$BIN/aa" proxy status --json 2>/dev/null)"; ALIVERC=$?
  assert_exit 0 $ALIVERC "CP5b 越界请求后宿主仍存活(status 退出码=0,未被 DoS 崩溃)"
  assert_contains "$ALIVE" '"running":true' "CP5b 越界请求后宿主仍正常服务(running=true)"

  # (CP6) 别名 ≡ call 底座:aa proxy groups ≡ capabilities call proxy.groups.list(同路由同输出)。
  CG="$("$BIN/aa" capabilities call proxy.groups.list --json 2>/dev/null)"; CGRC=$?
  assert_exit 0 $CGRC "CP6 capabilities call proxy.groups.list 退出码=0"
  if [ "$GRB" = "$CG" ] && [ -n "$CG" ]; then echo "PASS: CP6 aa proxy groups ≡ capabilities call proxy.groups.list 逐字节一致(别名同底座)"; PASS=$((PASS+1)); else echo "FAIL: CP6 别名与 call 输出不一致(alias='$GRB' vs call='$CG')"; FAIL=$((FAIL+1)); fi
else
  echo "FAIL: CP 宿主未就绪(socket_up=$SOCK_UP)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# 清场:杀宿主 + stub(轮询等真死;trap 亦兜底)
teardown_hosts also-stub

# --- 断言组 SP:系统代理接管/还原 E2E(07 票主体:文件后端假 NetworkConfigPort + fake mihomo stub,绝不碰真 networksetup)---
# 姿态:宿主经 env(AA_NETWORKSETUP_FAKE_STATE)注入文件后端假 NetworkConfigPort,读写 $BUILD 下的 JSON 状态文件;
#   check.sh 据该文件断言「接管指向内核 mixed-port / 精确还原(含原第三方代理)/ 宿主正常退出后复原」。
#   宿主**不设 AA_CONFIRM_AUTO**——enable/disable 为 normal,若误走 dangerous 确认会在 headless 挂起(超时退出码3);
#   它们快速退出码0 即证明 normal 零确认(不弹窗、不阻塞)。绝不设置真 networksetup。
echo "--- 断言组 SP:系统代理接管/还原 E2E(07 票)---"
teardown_hosts also-stub

# 假 networksetup 初始状态(接管前快照):Wi-Fi 全关;Ethernet 原本就有第三方代理(HTTP/HTTPS→203.0.113.9:8080,SOCKS 关)。
NETFAKE="$BUILD/netfake-state.json"
cat > "$NETFAKE" <<'JSON'
{"services":[
{"service":"Wi-Fi","http":{"enabled":false,"host":"","port":0},"https":{"enabled":false,"host":"","port":0},"socks":{"enabled":false,"host":"","port":0}},
{"service":"Ethernet","http":{"enabled":true,"host":"203.0.113.9","port":8080},"https":{"enabled":true,"host":"203.0.113.9","port":8080},"socks":{"enabled":false,"host":"","port":0}}
]}
JSON
# 留一份接管前初始快照的规整副本,供「终态=接管前快照」语义对比(经 python 归一,忽略键序/空白)。
python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2],"w"), sort_keys=True)' "$NETFAKE" "$BUILD/netfake-initial.json" 2>/dev/null

# 起宿主:内核 stub + 文件后端假 NetworkConfigPort(env 注入),不设 AA_CONFIRM_AUTO。
AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT" AA_NETWORKSETUP_FAKE_STATE="$NETFAKE" \
  "$HOST_BIN" > "$HOSTLOG" 2>&1 &
HOST_PID=$!
disown "$HOST_PID" 2>/dev/null || true
wait_host_ready "$HOST_PID"

# 语义对比助手:比较状态文件与接管前初始快照是否等价(python 归一)。
netfake_equals_initial() {
  python3 -c 'import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
sys.exit(0 if a==b else 1)' "$NETFAKE" "$BUILD/netfake-initial.json" 2>/dev/null
}

if [ "$SOCK_UP" -eq 1 ]; then
  # 等内核 REST 就绪(enable 要经 REST 读 mixed-port)。
  READY=0
  for _ in $(seq 1 50); do
    if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then READY=1; break; fi
    sleep 0.2
  done
  if [ "$READY" -eq 1 ]; then echo "PASS: SP 内核 REST 就绪(enable 可读 mixed-port)"; PASS=$((PASS+1)); else echo "FAIL: SP 内核 REST 未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1)); fi

  # (SP0) 元数据:enable/disable 为 normal(→零 GUI 确认)且各带 cliAlias(经 wire 下发,别名解析基石)。
  DEN="$("$BIN/aa" capabilities describe proxy.system.enable --json 2>/dev/null)"; DENRC=$?
  echo "    describe proxy.system.enable: $DEN"
  assert_exit 0 $DENRC "describe proxy.system.enable 退出码=0"
  assert_contains "$DEN" '"risk":"normal"' "proxy.system.enable 风险档=normal(→ 零 GUI 确认,safe/normal 直通)"
  assert_contains "$DEN" '"cliAlias":["proxy","on"]' "proxy.system.enable 声明 cliAlias=[proxy,on](经 wire 下发)"
  DDIS="$("$BIN/aa" capabilities describe proxy.system.disable --json 2>/dev/null)"
  assert_contains "$DDIS" '"risk":"normal"' "proxy.system.disable 风险档=normal(→ 零 GUI 确认)"
  assert_contains "$DDIS" '"cliAlias":["proxy","off"]' "proxy.system.disable 声明 cliAlias=[proxy,off]"

  # (SP1) aa proxy on(别名→proxy.system.enable):退出0(normal 零确认,未设 AA_CONFIRM_AUTO 仍不挂)+ 接管成功。
  ON1="$("$BIN/aa" proxy on --json 2>/dev/null)"; ONRC=$?
  echo "    aa proxy on 输出: $ON1"
  assert_exit 0 $ONRC "aa proxy on(别名→proxy.system.enable,normal)退出码=0(零 GUI 确认,不阻塞/不超时)"
  assert_contains "$ON1" '"enabled":true' "aa proxy on 结果 enabled=true(接管成功)"
  assert_contains "$ON1" '"port":7890' "aa proxy on 指向内核 mixed-port 7890(端口复用 06 RESTClient)"

  # (SP2) 断言假 networksetup 各服务 HTTP/HTTPS/SOCKS 均指向 127.0.0.1:7890(读状态文件,绝不碰真设置)。
  echo "    接管后假 networksetup: $(cat "$NETFAKE")"
  ON_COUNT="$(grep -o '"enabled":true,"host":"127.0.0.1","port":7890' "$NETFAKE" | wc -l | tr -d ' ')"
  if [ "$ON_COUNT" -eq 6 ]; then echo "PASS: 接管后 2 服务×3 类代理均指向 127.0.0.1:7890(6/6,含原关闭的 Wi-Fi/SOCKS)"; PASS=$((PASS+1)); else echo "FAIL: 接管后指向内核端口的项应为6,实际 $ON_COUNT。文件: $(cat "$NETFAKE")"; FAIL=$((FAIL+1)); fi
  if grep -qF '203.0.113.9' "$NETFAKE"; then echo "FAIL: 接管后仍残留第三方代理 203.0.113.9(未被接管覆盖)"; FAIL=$((FAIL+1)); else echo "PASS: 接管后原第三方代理被内核端口覆盖(接管彻底)"; PASS=$((PASS+1)); fi

  # (SP3) 别名 ≡ call:aa proxy on ≡ capabilities call proxy.system.enable(幂等 enable → 逐字节一致、同退出码0)。
  ON2="$("$BIN/aa" capabilities call proxy.system.enable --json 2>/dev/null)"; ON2RC=$?
  assert_exit 0 $ON2RC "capabilities call proxy.system.enable 退出码=0"
  if [ "$ON1" = "$ON2" ] && [ -n "$ON1" ]; then echo "PASS: aa proxy on ≡ capabilities call proxy.system.enable 逐字节一致(别名同路由同底座)"; PASS=$((PASS+1)); else echo "FAIL: 别名与 call 输出不一致(alias='$ON1' vs call='$ON2')"; FAIL=$((FAIL+1)); fi

  # (SP3b) 06 的 id 映射与 07 的别名共存:aa proxy status(id 映射)仍可用。
  SPST="$("$BIN/aa" proxy status --json 2>/dev/null)"; SPSTRC=$?
  assert_exit 0 $SPSTRC "aa proxy status(06 id 映射)仍退出码=0(与别名共存)"
  assert_contains "$SPST" '"running":true' "aa proxy status 仍反映内核存活(id 映射与 cliAlias 别名并存)"

  # (SP4) aa proxy off(别名→proxy.system.disable):退出0 + 精确还原(含原第三方代理)。
  OFF1="$("$BIN/aa" proxy off --json 2>/dev/null)"; OFFRC=$?
  echo "    aa proxy off 输出: $OFF1 | 还原后假 networksetup: $(cat "$NETFAKE")"
  assert_exit 0 $OFFRC "aa proxy off(别名→proxy.system.disable,normal)退出码=0(零 GUI 确认)"
  assert_contains "$OFF1" '"restored":true' "aa proxy off 报告已还原(restored=true)"
  if grep -qF '"enabled":true,"host":"203.0.113.9","port":8080' "$NETFAKE"; then echo "PASS: 还原后 Ethernet 精确回到第三方代理 203.0.113.9:8080(非一律关闭)"; PASS=$((PASS+1)); else echo "FAIL: 还原未精确回到第三方代理。文件: $(cat "$NETFAKE")"; FAIL=$((FAIL+1)); fi
  if grep -qF '127.0.0.1' "$NETFAKE"; then echo "FAIL: 还原后仍残留内核端口 127.0.0.1(接管痕迹未清)"; FAIL=$((FAIL+1)); else echo "PASS: 还原后无内核端口残留(接管痕迹已清)"; PASS=$((PASS+1)); fi
  if netfake_equals_initial; then echo "PASS: aa proxy off 后假 networksetup 终态=接管前快照(精确复原)"; PASS=$((PASS+1)); else echo "FAIL: aa proxy off 后终态≠接管前快照。终态: $(cat "$NETFAKE")"; FAIL=$((FAIL+1)); fi

  # (SP5) 宿主正常退出还原:重新接管 → SIGUSR1 优雅退出 → applicationWillTerminate 先还原代理再停内核。
  "$BIN/aa" proxy on --json >/dev/null 2>&1; RC=$?
  assert_exit 0 $RC "SP5 前置:重新 aa proxy on 退出码=0"
  if grep -qF '127.0.0.1' "$NETFAKE"; then echo "PASS: SP5 前置接管生效(文件含内核端口 127.0.0.1)"; PASS=$((PASS+1)); else echo "FAIL: SP5 前置接管未生效"; FAIL=$((FAIL+1)); fi
  STUB_BEFORE="$(pgrep -f "$KILLPAT_STUB")"
  echo "    SP5:退出前 fake mihomo pid(s)=[$STUB_BEFORE]"
  kill -USR1 "$HOST_PID" 2>/dev/null
  sleep 5
  # 退出后①:假 networksetup 终态=接管前初始快照(退出即复原,网络立即直连)。
  if netfake_equals_initial; then echo "PASS: 宿主正常退出后假 networksetup 终态=接管前快照(已复原,退出后直连)"; PASS=$((PASS+1)); else echo "FAIL: 宿主退出后假 networksetup 未复原到接管前快照。终态: $(cat "$NETFAKE")"; FAIL=$((FAIL+1)); fi
  # 退出后②:内核已停(先还原代理→再停内核 顺序生效),无孤儿 stub。
  LEFTSP="$(pgrep -f "$KILLPAT_STUB")"
  if [ -z "$LEFTSP" ]; then echo "PASS: 宿主正常退出后内核已停、无孤儿(还原代理→停内核 顺序生效)"; PASS=$((PASS+1)); else echo "FAIL: 宿主退出后仍有孤儿 stub: $LEFTSP"; FAIL=$((FAIL+1)); pkill -9 -f "$KILLPAT_STUB" 2>/dev/null; fi
  # 退出后③:宿主进程已退出。
  if kill -0 "$HOST_PID" 2>/dev/null; then echo "FAIL: 宿主收 SIGUSR1 后未退出"; FAIL=$((FAIL+1)); pkill -f "$KILLPAT" 2>/dev/null; else echo "PASS: 宿主经 SIGUSR1 优雅退出(走完 还原代理→停内核 路径)"; PASS=$((PASS+1)); fi
else
  echo "FAIL: SP 宿主未就绪(socket_up=$SOCK_UP)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# 清场:杀宿主 + stub(轮询等真死;trap 亦兜底)
teardown_hosts also-stub

# --- 断言组 SH:崩溃自愈 E2E(08 票主体:文件后端假 NetworkConfigPort + fake stub + 持久化临时区,kill -9 剧本,绝不碰真系统)---
# 姿态:整条剧本用 kill -9 强杀宿主(atexit/信号退出钩子**都不跑**)——留下「代理指向死端口 + 持久化接管态标记 + 孤儿内核」。
#   重启宿主 → 启动早期自愈跑一次:reap 上世代孤儿内核 → 恢复接管(重启内核+重指存活端口)或还原快照(降级直连)或
#   (用户改过)只清标记。**硬不变式**:任一自愈路径后系统代理都不指向死端口。持久化写 $BUILD 临时区(per-launch env),绝不碰真 AppSupport。
echo "--- 断言组 SH:崩溃自愈 E2E(08 票 kill -9 剧本)---"
teardown_hosts also-stub

SHNET="$BUILD/selfheal-netfake.json"
SHSTATE="$BUILD/selfheal-takeover.json"

# 接管前初始快照(Wi-Fi 全关;Ethernet 原第三方代理 203.0.113.9:8080,SOCKS 关)—— 证明还原精确、非一律关闭。
write_shnet_initial() {
cat > "$SHNET" <<'JSON'
{"services":[
{"service":"Wi-Fi","http":{"enabled":false,"host":"","port":0},"https":{"enabled":false,"host":"","port":0},"socks":{"enabled":false,"host":"","port":0}},
{"service":"Ethernet","http":{"enabled":true,"host":"203.0.113.9","port":8080},"https":{"enabled":true,"host":"203.0.113.9","port":8080},"socks":{"enabled":false,"host":"","port":0}}
]}
JSON
python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2],"w"), sort_keys=True)' "$SHNET" "$BUILD/selfheal-initial.json" 2>/dev/null
}
shnet_equals_initial() {
python3 -c 'import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
sys.exit(0 if a==b else 1)' "$SHNET" "$BUILD/selfheal-initial.json" 2>/dev/null
}

# 建立「一个崩溃世代」:起宿主(内核 stub + 假网络 + 独立持久化文件)→ 等 REST 就绪 → proxy on 接管 →
#   捕获内核 stub pid 为 $ORPHAN_PID → kill -9 宿主(退出钩子不跑)。留:代理指向死端口 + 持久化标记 + 孤儿内核。返回非 0 表示前置失败。
crash_generation() {
  teardown_hosts also-stub          # 轮询等上一剧本宿主真死 + 清默认标记(本剧本用独立 $SHSTATE,不受影响)
  write_shnet_initial
  rm -f "$SHSTATE"
  AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT" AA_NETWORKSETUP_FAKE_STATE="$SHNET" \
    AA_TAKEOVER_STATE_PATH="$SHSTATE" "$HOST_BIN" > "$HOSTLOG" 2>&1 &
  HOST_PID=$!
  disown "$HOST_PID" 2>/dev/null || true
  wait_host_ready "$HOST_PID" || true
  [ "$SOCK_UP" -eq 1 ] || return 1
  READY=0
  for _ in $(seq 1 50); do
    if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then READY=1; break; fi
    sleep 0.2
  done
  [ "$READY" -eq 1 ] || return 1
  "$BIN/aa" proxy on --json >/dev/null 2>&1 || return 1
  ORPHAN_PID="$(pgrep -f "$KILLPAT_STUB" | head -1)"
  kill -9 "$HOST_PID" 2>/dev/null   # SIGKILL:atexit/信号钩子都不跑 → 孤儿内核 stub 被 launchd 收养、仍存活
  sleep 2
  rm -f "$SOCK"                     # 清 kill -9 遗留的陈旧 socket 文件(避免下次启动的就绪探测假阳)
  return 0
}

# 起「重启后的新世代」宿主并等 socket 就绪。$1..= 额外 env 赋值(如 AA_MIHOMO_KERNEL_PATH=…)。
# 关键:先删被 kill -9 的上世代留下的**陈旧 socket 文件**(kill -9 不清 UDS 文件),否则「socket 存在」会假就绪——
#   自愈在 UDS server 启动**之前**同步跑完,故新 socket 出现 == 自愈已完成且开始服务(SOCK_UP 才是可靠就绪信号)。
start_restart_host() {
  rm -f "$SOCK"   # 只删陈旧 socket;**绝不 pkill**——上世代孤儿 stub 须存活,供本世代自愈 reap
  # 用 env 施加 env 变量:从 "$@" 展开来的 NAME=VALUE 无法被 bash 当赋值处理,必须交给 env 命令解析。
  env "$@" AA_NETWORKSETUP_FAKE_STATE="$SHNET" AA_TAKEOVER_STATE_PATH="$SHSTATE" "$HOST_BIN" > "$HOSTLOG" 2>&1 &
  HOST_PID=$!
  disown "$HOST_PID" 2>/dev/null || true
  wait_host_ready "$HOST_PID" || true
}

# —— 剧本 A:接管 → kill -9 → 重启(带内核)→ 恢复接管(reap 孤儿 + 重启内核 + 重指存活端口)——
if crash_generation; then
  echo "    剧本A:crash 后 orphan 内核 pid=$ORPHAN_PID"
  # 崩溃残留三件套:代理指向死端口 + 持久化标记(含 kernelPort/kernelPID/snapshot)+ 孤儿内核仍活。
  if grep -qF '"enabled":true,"host":"127.0.0.1","port":7890' "$SHNET"; then echo "PASS: 剧本A crash 后系统代理仍指向死端口 127.0.0.1:7890(断网态,待自愈)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A crash 后未见指向死端口的代理。文件: $(cat "$SHNET")"; FAIL=$((FAIL+1)); fi
  if [ -f "$SHSTATE" ] && grep -qF '"kernelPort":7890' "$SHSTATE" && grep -qF '"snapshot"' "$SHSTATE" && grep -qF '"kernelPID"' "$SHSTATE"; then echo "PASS: 剧本A crash 后持久化接管态清单在(含 snapshot/kernelPort/kernelPID)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A crash 后持久化清单缺失/不完整: $(cat "$SHSTATE" 2>/dev/null)"; FAIL=$((FAIL+1)); fi
  if [ -n "$ORPHAN_PID" ] && kill -0 "$ORPHAN_PID" 2>/dev/null; then echo "PASS: 剧本A crash 后孤儿内核仍存活(pid=$ORPHAN_PID;kill -9 宿主退出钩子没跑到)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A crash 后孤儿内核未存活(pid=$ORPHAN_PID)——无法验证跨世代 reap"; FAIL=$((FAIL+1)); fi

  start_restart_host AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT"
  if [ "$SOCK_UP" -eq 1 ]; then
    READY=0
    for _ in $(seq 1 60); do
      if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then READY=1; break; fi
      sleep 0.2
    done
    echo "    剧本A 重启+自愈日志:"; grep -F 'self-heal' "$HOSTLOG" | sed 's/^/      /'
    NEW_STUB="$(pgrep -f "$KILLPAT_STUB" | grep -vx "$ORPHAN_PID" | head -1)"
    if grep -qF 'self-heal decision=recoverTakeover' "$HOSTLOG"; then echo "PASS: 剧本A 自愈判定=恢复接管(recoverTakeover)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A 自愈未走恢复接管。日志: $(grep -F self-heal "$HOSTLOG")"; FAIL=$((FAIL+1)); fi
    if [ -n "$ORPHAN_PID" ] && ! kill -0 "$ORPHAN_PID" 2>/dev/null; then echo "PASS: 剧本A 自愈 reap 了上世代孤儿内核(旧 pid=$ORPHAN_PID 已不存活,还 06 反孤儿债)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A 上世代孤儿内核未被 reap(pid=$ORPHAN_PID 仍在)"; FAIL=$((FAIL+1)); pkill -9 -f "$KILLPAT_STUB" 2>/dev/null; fi
    SPA="$("$BIN/aa" proxy status --json 2>/dev/null)"
    if printf '%s' "$SPA" | grep -qF '"running":true'; then echo "PASS: 剧本A 自愈后有存活受管内核(proxy.status running=true → 端口非死)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A 自愈后无存活受管内核。status=$SPA"; FAIL=$((FAIL+1)); fi
    if grep -qF '"enabled":true,"host":"127.0.0.1","port":7890' "$SHNET"; then echo "PASS: 剧本A 自愈后系统代理指向 127.0.0.1:7890(现由重启内核承载,不指向死端口)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A 自愈后代理未指向内核端口。文件: $(cat "$SHNET")"; FAIL=$((FAIL+1)); fi
    if [ -n "$NEW_STUB" ] && [ "$NEW_STUB" != "$ORPHAN_PID" ]; then echo "PASS: 剧本A 自愈重启了新内核(new pid=$NEW_STUB ≠ 旧孤儿 $ORPHAN_PID)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A 未见与旧孤儿不同的新内核(new=$NEW_STUB, orphan=$ORPHAN_PID)"; FAIL=$((FAIL+1)); fi
    if [ -n "$NEW_STUB" ] && [ -f "$SHSTATE" ] && grep -qF "\"kernelPID\":$NEW_STUB" "$SHSTATE"; then echo "PASS: 剧本A 自愈更新了持久化标记(kernelPID=$NEW_STUB,仍处接管态)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A 持久化标记未更新为新内核 pid(new=$NEW_STUB)。文件: $(cat "$SHSTATE" 2>/dev/null)"; FAIL=$((FAIL+1)); fi
  else
    echo "FAIL: 剧本A 重启宿主未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
  fi
else
  echo "FAIL: 剧本A crash_generation 未成功建立残留接管态(前置失败)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi
teardown_hosts also-stub   # 剧本间清场:轮询等宿主+stub 真死(取代盲 sleep 1)

# —— 剧本 B:接管 → kill -9 → 重启(不带内核)→ 还原快照(内核不可重启 → 降级直连,精确复原)——
if crash_generation; then
  echo "    剧本B:crash 后 orphan 内核 pid=$ORPHAN_PID"
  start_restart_host   # 不带 AA_MIHOMO_KERNEL_PATH → 内核不可重启
  if [ "$SOCK_UP" -eq 1 ]; then
    sleep 1
    echo "    剧本B 重启+自愈日志:"; grep -F 'self-heal' "$HOSTLOG" | sed 's/^/      /'
    if grep -qF 'self-heal decision=restoreSnapshot' "$HOSTLOG"; then echo "PASS: 剧本B 自愈判定=还原快照(restoreSnapshot,内核不可重启→降级直连)"; PASS=$((PASS+1)); else echo "FAIL: 剧本B 自愈未走还原快照。日志: $(grep -F self-heal "$HOSTLOG")"; FAIL=$((FAIL+1)); fi
    if [ -n "$ORPHAN_PID" ] && ! kill -0 "$ORPHAN_PID" 2>/dev/null; then echo "PASS: 剧本B 自愈同样先 reap 了上世代孤儿内核(旧 pid=$ORPHAN_PID 已不存活)"; PASS=$((PASS+1)); else echo "FAIL: 剧本B 孤儿内核未被 reap(pid=$ORPHAN_PID)"; FAIL=$((FAIL+1)); pkill -9 -f "$KILLPAT_STUB" 2>/dev/null; fi
    if grep -qF '127.0.0.1' "$SHNET"; then echo "FAIL: 剧本B 自愈后仍残留死端口 127.0.0.1(未清)。文件: $(cat "$SHNET")"; FAIL=$((FAIL+1)); else echo "PASS: 剧本B 自愈后系统代理不再指向死端口 127.0.0.1(降级直连,不断网)"; PASS=$((PASS+1)); fi
    if grep -qF '"enabled":true,"host":"203.0.113.9","port":8080' "$SHNET"; then echo "PASS: 剧本B 还原快照精确回到接管前第三方代理 203.0.113.9:8080(非一律关闭)"; PASS=$((PASS+1)); else echo "FAIL: 剧本B 未精确还原第三方代理。文件: $(cat "$SHNET")"; FAIL=$((FAIL+1)); fi
    if shnet_equals_initial; then echo "PASS: 剧本B 自愈后假 networksetup 终态=接管前快照(精确复原)"; PASS=$((PASS+1)); else echo "FAIL: 剧本B 终态≠接管前快照。终态: $(cat "$SHNET")"; FAIL=$((FAIL+1)); fi
    if [ ! -e "$SHSTATE" ]; then echo "PASS: 剧本B 自愈还原后清除了持久化标记(无残留接管,下次启动 clean)"; PASS=$((PASS+1)); else echo "FAIL: 剧本B 还原后持久化标记仍在: $(cat "$SHSTATE")"; FAIL=$((FAIL+1)); fi
  else
    echo "FAIL: 剧本B 重启宿主未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
  fi
else
  echo "FAIL: 剧本B crash_generation 未成功(前置失败)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi
teardown_hosts also-stub   # 剧本间清场:轮询等宿主+stub 真死(取代盲 sleep 1)

# —— 剧本 C:接管 → kill -9 → 用户手动把代理改成别的第三方 → 重启 → 只清陈旧标记、绝不覆盖用户设置 ——
if crash_generation; then
  # 用户手动把系统代理改成第三方 198.51.100.5:1080(不再指向我方 7890)。
cat > "$SHNET" <<'JSON'
{"services":[
{"service":"Wi-Fi","http":{"enabled":true,"host":"198.51.100.5","port":1080},"https":{"enabled":true,"host":"198.51.100.5","port":1080},"socks":{"enabled":false,"host":"","port":0}},
{"service":"Ethernet","http":{"enabled":true,"host":"198.51.100.5","port":1080},"https":{"enabled":true,"host":"198.51.100.5","port":1080},"socks":{"enabled":false,"host":"","port":0}}
]}
JSON
  python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2],"w"), sort_keys=True)' "$SHNET" "$BUILD/selfheal-userchanged.json" 2>/dev/null
  start_restart_host AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT"
  if [ "$SOCK_UP" -eq 1 ]; then
    sleep 1
    echo "    剧本C 重启+自愈日志:"; grep -F 'self-heal' "$HOSTLOG" | sed 's/^/      /'
    if grep -qF 'self-heal decision=userChangedProxy' "$HOSTLOG"; then echo "PASS: 剧本C 自愈判定=用户手动改过代理(userChangedProxy)"; PASS=$((PASS+1)); else echo "FAIL: 剧本C 自愈未走 userChanged。日志: $(grep -F self-heal "$HOSTLOG")"; FAIL=$((FAIL+1)); fi
    if python3 -c 'import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
sys.exit(0 if a==b else 1)' "$SHNET" "$BUILD/selfheal-userchanged.json" 2>/dev/null; then echo "PASS: 剧本C 绝不覆盖用户设置(用户第三方代理 198.51.100.5:1080 原封不动)"; PASS=$((PASS+1)); else echo "FAIL: 剧本C 自愈改动了用户设置。终态: $(cat "$SHNET")"; FAIL=$((FAIL+1)); fi
    if grep -qF '127.0.0.1' "$SHNET"; then echo "FAIL: 剧本C 竟出现 127.0.0.1(不该指向我方端口)"; FAIL=$((FAIL+1)); else echo "PASS: 剧本C 终态不指向我方死端口(尊重用户直连/第三方设置)"; PASS=$((PASS+1)); fi
    if [ ! -e "$SHSTATE" ]; then echo "PASS: 剧本C 清除了陈旧持久化标记(不再自作主张接管)"; PASS=$((PASS+1)); else echo "FAIL: 剧本C 陈旧标记仍在: $(cat "$SHSTATE")"; FAIL=$((FAIL+1)); fi
  else
    echo "FAIL: 剧本C 重启宿主未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
  fi
else
  echo "FAIL: 剧本C crash_generation 未成功(前置失败)"; FAIL=$((FAIL+1))
fi
teardown_hosts also-stub   # 剧本间清场:轮询等宿主+stub 真死(取代盲 sleep 1)
rm -f "$SHSTATE" "$AA_TAKEOVER_STATE_PATH"

# --- 断言组 SUB:订阅管理 E2E(10 票主体:多订阅存储/单一激活/切换生效 + dangerous 两分支 + normal 更新零确认 + 反向不可绕过 + http 源)---
# 姿态:起「宿主 + 有状态 fake stub + 订阅目录(AA_SUBSCRIPTION_DIR=$BUILD/…)」。add=dangerous(经 AA_CONFIRM_AUTO 两分支);
#   activate/update=normal(不设 CONFIRM_AUTO 也不弹窗——normal 不触发确认)。物化配置经内核 PUT /configs 从路径重载,
#   fake stub 解析 test-only fixture 更新内存态,故「切换激活/更新后」经 proxy groups/status 能读回配置已生效。绝不碰真系统/真网络。
echo "--- 断言组 SUB:订阅管理 E2E(10 票)---"
teardown_hosts also-stub

SUBDIR="$BUILD/subs"
rm -rf "$SUBDIR"; mkdir -p "$SUBDIR"

# 两个 file:// 源 fixture(mode/组不同,便于「切换激活后读回生效」):A=global · PROXY[A1,A2] now A1;B=direct · PROXY[B1,B2] now B1。
SUBA_FIX="$BUILD/subA.fixture.json"
SUBB_FIX="$BUILD/subB.fixture.json"
cat > "$SUBA_FIX" <<'JSON'
{"mode":"global","groups":{"PROXY":{"type":"Selector","all":["A1","A2"],"now":"A1"}}}
JSON
cat > "$SUBB_FIX" <<'JSON'
{"mode":"direct","groups":{"PROXY":{"type":"Selector","all":["B1","B2"],"now":"B1"}}}
JSON

# 起「宿主 + 有状态 fake stub + 订阅目录(+ 可选 AA_CONFIRM_AUTO)」。$1=confirm 档(approve/deny/none);$2(可选)=独立 SUBDIR。
# 不用数组展开(macOS bash 3.2 下 set -u 对空数组 "${arr[@]}" 会 unbound error),按分支各写一条 env。
start_host_sub() {
  local confirm="$1"
  local subdir="${2:-$SUBDIR}"
  teardown_hosts also-stub
  if [ "$confirm" = "none" ]; then
    env AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT" AA_SUBSCRIPTION_DIR="$subdir" \
      "$HOST_BIN" > "$HOSTLOG" 2>&1 &
  else
    env AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT" AA_SUBSCRIPTION_DIR="$subdir" \
      AA_CONFIRM_AUTO="$confirm" "$HOST_BIN" > "$HOSTLOG" 2>&1 &
  fi
  HOST_PID=$!
  disown "$HOST_PID" 2>/dev/null || true
  wait_host_ready "$HOST_PID"
}

# 轮询等内核 REST 就绪(activate/update 的重载要经 REST)。返回 0/1。
wait_rest_ready() {
  local i
  for i in $(seq 1 50); do
    if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then return 0; fi
    sleep 0.2
  done
  return 1
}

# F1:id 现带确定性哈希后缀(不可人肉预测)——从 add 单条输出捕获 id;从 list 输出捕获 active。
extract_id() { printf '%s' "$1" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p'; }
extract_active() { printf '%s' "$1" | sed -n 's/.*"active":"\([^"]*\)".*/\1/p'; }

# —— 场景 1:多订阅存储 + 单一激活 + 切换激活配置随之生效(两个 file:// 源;id 从 add 输出捕获)——
start_host_sub approve
if [ "$SOCK_UP" -eq 1 ] && wait_rest_ready; then
  echo "PASS: SUB 宿主+内核 REST 就绪(订阅 E2E 可跑)"; PASS=$((PASS+1))
  ADDA="$("$BIN/aa" capabilities call proxy.subscription.add --input "{\"name\":\"subA\",\"source\":\"file://$SUBA_FIX\"}" --json 2>/dev/null)"; ARC=$?
  IDA="$(extract_id "$ADDA")"
  echo "    add subA 输出: $ADDA | 捕获 id=$IDA"
  assert_exit 0 $ARC "SUB1 add subA(dangerous approve)退出码=0"
  assert_contains "$ADDA" '"added":true' "SUB1 add subA 成功(added=true)"
  # F2:确认层确实收到本次请求 input(name/source)——grep 宿主日志的 [confirm] 行(证明不再盲批)。
  CONFLOG="$(grep -F '[confirm] proxy.subscription.add' "$HOSTLOG" | tail -1)"
  echo "    确认层日志: $CONFLOG"
  assert_contains "$CONFLOG" '[confirm] proxy.subscription.add' "SUB1 F2:确认层收到 dangerous 请求(打印 [confirm] 行)"
  assert_contains "$CONFLOG" "source=file://$SUBA_FIX" "SUB1 F2:确认层看得见 source(不再盲批)"
  assert_contains "$CONFLOG" "name=subA" "SUB1 F2:确认层看得见 name(不再盲批)"
  ADDB="$("$BIN/aa" capabilities call proxy.subscription.add --input "{\"name\":\"subB\",\"source\":\"file://$SUBB_FIX\"}" --json 2>/dev/null)"; BRC=$?
  IDB="$(extract_id "$ADDB")"
  assert_exit 0 $BRC "SUB1 add subB(dangerous approve)退出码=0"
  LST="$("$BIN/aa" capabilities call proxy.subscription.list --json 2>/dev/null)"
  echo "    list 输出: $LST | idA=$IDA idB=$IDB"
  if [ -n "$IDA" ] && [ -n "$IDB" ] && [ "$IDA" != "$IDB" ]; then echo "PASS: SUB1 两订阅得到不同 id(idA=$IDA idB=$IDB)"; PASS=$((PASS+1)); else echo "FAIL: SUB1 id 捕获异常(idA=$IDA idB=$IDB)"; FAIL=$((FAIL+1)); fi
  assert_contains "$LST" "\"id\":\"$IDA\"" "SUB1 list 见 subA(捕获 id)"
  assert_contains "$LST" "\"id\":\"$IDB\"" "SUB1 list 见 subB(捕获 id)"
  assert_contains "$LST" '"active":null' "SUB1 add 后无激活(active=null,不自动激活)"
  # 激活 A → 读回 A 生效(mode=global / PROXY now=A1)。
  ACTA="$("$BIN/aa" capabilities call proxy.subscription.activate --input "{\"id\":\"$IDA\"}" --json 2>/dev/null)"; AARC=$?
  echo "    activate A 输出: $ACTA"
  assert_exit 0 $AARC "SUB1 activate A(normal)退出码=0(零 GUI 确认,不阻塞/不超时)"
  assert_contains "$ACTA" '"activated":true' "SUB1 activate A 报告已激活"
  GA="$("$BIN/aa" proxy groups --json 2>/dev/null)"
  echo "    激活 A 后 groups: $GA"
  assert_contains "$GA" '"now":"A1"' "SUB1 激活 A 后读回 PROXY now=A1(配置随之生效)"
  assert_contains "$GA" '"all":["A1","A2"]' "SUB1 激活 A 后读回候选 [A1,A2]"
  SA="$("$BIN/aa" proxy status --json 2>/dev/null)"
  assert_contains "$SA" '"mode":"global"' "SUB1 激活 A 后读回 mode=global(经 REST,配置生效)"
  LSTA="$("$BIN/aa" capabilities call proxy.subscription.list --json 2>/dev/null)"
  assert_contains "$LSTA" "\"active\":\"$IDA\"" "SUB1 激活后 list active=idA(单一激活)"
  # 切换到 B → 读回 B 生效(mode=direct / PROXY now=B1)。
  "$BIN/aa" capabilities call proxy.subscription.activate --input "{\"id\":\"$IDB\"}" --json >/dev/null 2>&1; ABRC=$?
  assert_exit 0 $ABRC "SUB1 activate B(切换激活)退出码=0"
  GB="$("$BIN/aa" proxy groups --json 2>/dev/null)"
  echo "    切换到 B 后 groups: $GB"
  assert_contains "$GB" '"now":"B1"' "SUB1 切换到 B 后读回 PROXY now=B1(切换激活配置生效)"
  SB="$("$BIN/aa" proxy status --json 2>/dev/null)"
  assert_contains "$SB" '"mode":"direct"' "SUB1 切换到 B 后读回 mode=direct(配置随之生效)"
  LSTB="$("$BIN/aa" capabilities call proxy.subscription.list --json 2>/dev/null)"
  assert_contains "$LSTB" "\"active\":\"$IDB\"" "SUB1 切换后 list active=idB(仍单一激活)"
else
  echo "FAIL: SUB 场景1 宿主/REST 未就绪(socket_up=$SOCK_UP)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# —— 场景 2:add dangerous 两分支(deny 专属退出码 2 且不留痕 / approve 成功可见)——
SUBDIR2="$BUILD/subs2"; rm -rf "$SUBDIR2"; mkdir -p "$SUBDIR2"
start_host_sub deny "$SUBDIR2"
if [ "$SOCK_UP" -eq 1 ] && wait_rest_ready; then
  DDENY="$("$BIN/aa" capabilities call proxy.subscription.add --input "{\"name\":\"subA\",\"source\":\"file://$SUBA_FIX\"}" --json 2>/dev/null)"; DDRC=$?
  echo "    deny add 输出: $DDENY"
  assert_exit 2 $DDRC "SUB2 add dangerous(deny)退出码=2(denied 专属码)"
  assert_contains "$DDENY" '"code":"denied"' "SUB2 deny 分支统一错误信封 error.code=denied"
  LDENY="$("$BIN/aa" capabilities call proxy.subscription.list --json 2>/dev/null)"
  echo "    deny 后 list: $LDENY"
  assert_contains "$LDENY" '"subscriptions":[]' "SUB2 deny 不留痕(catalog 无新增,subscriptions 为空)"
  if printf '%s' "$LDENY" | grep -qF '"id":'; then echo "FAIL: SUB2 deny 竟留痕(list 出现 id)"; FAIL=$((FAIL+1)); else echo "PASS: SUB2 deny 分支 catalog 无任何订阅(拒绝不留痕)"; PASS=$((PASS+1)); fi
else
  echo "FAIL: SUB2 deny 宿主/REST 未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi
start_host_sub approve "$SUBDIR2"
if [ "$SOCK_UP" -eq 1 ] && wait_rest_ready; then
  DAPP="$("$BIN/aa" capabilities call proxy.subscription.add --input "{\"name\":\"subA\",\"source\":\"file://$SUBA_FIX\"}" --json 2>/dev/null)"; DARC=$?
  IDAP="$(extract_id "$DAPP")"
  echo "    approve add 输出: $DAPP | id=$IDAP"
  assert_exit 0 $DARC "SUB2 add dangerous(approve)退出码=0"
  assert_contains "$DAPP" '"added":true' "SUB2 approve 分支 add 成功(added=true)"
  LAPP="$("$BIN/aa" capabilities call proxy.subscription.list --json 2>/dev/null)"
  assert_contains "$LAPP" "\"id\":\"$IDAP\"" "SUB2 approve 后 list 可见该订阅(捕获 id)"
else
  echo "FAIL: SUB2 approve 宿主/REST 未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# —— 场景 3:update normal 零确认(host 不设 AA_CONFIRM_AUTO 也不弹窗——normal 不触发确认)——
# 复用场景1的 SUBDIR(已持久化 subA/subB,active=idB)。新宿主**不设 CONFIRM_AUTO**:若 update 误走 dangerous 确认会 headless 挂起(→ 超时退出码3)。
# id 从新宿主的 list active 捕获(不硬编码;确定性 id 但仍走「读回再喂」的稳妥路径)。
start_host_sub none "$SUBDIR"
if [ "$SOCK_UP" -eq 1 ] && wait_rest_ready; then
  LST3="$("$BIN/aa" capabilities call proxy.subscription.list --json 2>/dev/null)"
  ACT3="$(extract_active "$LST3")"
  echo "    SUB3 当前 active=$ACT3"
  UPD="$("$BIN/aa" capabilities call proxy.subscription.update --input "{\"id\":\"$ACT3\"}" --json 2>/dev/null)"; URC=$?
  echo "    update active 输出: $UPD"
  assert_exit 0 $URC "SUB3 update 激活项(normal,无 CONFIRM_AUTO 仍不挂)退出码=0(零 GUI 确认)"
  assert_contains "$UPD" '"updated":true' "SUB3 update 报告已更新(updated=true)"
  GU="$("$BIN/aa" proxy groups --json 2>/dev/null)"
  echo "    update 后 groups: $GU"
  assert_contains "$GU" '"now":"B1"' "SUB3 update 激活项后读回 PROXY now=B1(重载生效)"
  SU="$("$BIN/aa" proxy status --json 2>/dev/null)"
  assert_contains "$SU" '"mode":"direct"' "SUB3 update 激活项后读回 mode=direct(重载生效)"
else
  echo "FAIL: SUB3 宿主/REST 未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# —— 场景 4:反向——经 UDS 直连也绕不过换源确认(复用 04 的 raw-UDS 手法;wire 请求里无任何字段能预批准)——
SUBDIR4="$BUILD/subs4"; rm -rf "$SUBDIR4"; mkdir -p "$SUBDIR4"
start_host_sub deny "$SUBDIR4"
if [ "$SOCK_UP" -eq 1 ]; then
  RAWSUB="$(python3 "$RAW_CLIENT" "$SOCK" "{\"op\":\"capabilities.call\",\"capability\":\"proxy.subscription.add\",\"input\":{\"name\":\"subA\",\"source\":\"file://$SUBA_FIX\"}}" 2>&1)"
  echo "    裸 UDS 直连 add 响应: $RAWSUB"
  assert_contains "$RAWSUB" '"code":"denied"' "SUB4 裸 UDS 直连 proxy.subscription.add 仍 denied(绕过 aa 也躲不过确认)"
  assert_contains "$RAWSUB" '"ok":false' "SUB4 裸 UDS 直连响应 ok=false"
  if printf '%s' "$RAWSUB" | grep -qF '"added"'; then echo "FAIL: SUB4 裸 UDS add 竟出现 added(疑似绕过确认执行)"; FAIL=$((FAIL+1)); else echo "PASS: SUB4 裸 UDS add 未出现执行结果 added(确认未被绕过、未留痕)"; PASS=$((PASS+1)); fi
else
  echo "FAIL: SUB4 deny 宿主未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi
pkill -f "raw_uds_client.py" 2>/dev/null

# —— 场景 5:http:// 源(本地 python3 -m http.server 假源,真正跑通 RealSubscriptionSourcePort 的 http 拉取路径)——
# F12:端口探测失败**直接 FAIL 并说明**(绝不回退固定端口——固定端口被占会变成 flaky 门禁,用户零容忍)。
SUBDIR5="$BUILD/subs5"; rm -rf "$SUBDIR5"; mkdir -p "$SUBDIR5"
HTTPSRV_DIR="$BUILD/httpsrc"; rm -rf "$HTTPSRV_DIR"; mkdir -p "$HTTPSRV_DIR"
cp "$SUBA_FIX" "$HTTPSRV_DIR/subA.json"
SUBHTTP_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null)"
if [ -z "$SUBHTTP_PORT" ]; then
  echo "FAIL: SUB5 无法探测空闲端口给 http 假源(python3 端口探测失败;拒绝回退固定端口以免 flaky 门禁)"; FAIL=$((FAIL+1))
else
  ( cd "$HTTPSRV_DIR" && exec python3 -m http.server "$SUBHTTP_PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
  SUBHTTP_PID=$!
  disown "$SUBHTTP_PID" 2>/dev/null || true
  # 轮询等 http 假源就绪(-f:非 2xx 判失败,确保真能取到 fixture);起后再用,用完 teardown。
  HTTP_UP=0
  for _ in $(seq 1 50); do
    if curl -sf -o /dev/null "http://127.0.0.1:$SUBHTTP_PORT/subA.json" 2>/dev/null; then HTTP_UP=1; break; fi
    kill -0 "$SUBHTTP_PID" 2>/dev/null || break
    sleep 0.2
  done
  if [ "$HTTP_UP" -eq 1 ]; then
    start_host_sub approve "$SUBDIR5"
    if [ "$SOCK_UP" -eq 1 ] && wait_rest_ready; then
      HADD="$("$BIN/aa" capabilities call proxy.subscription.add --input "{\"name\":\"httpSub\",\"source\":\"http://127.0.0.1:$SUBHTTP_PORT/subA.json\"}" --json 2>/dev/null)"; HARC=$?
      HID="$(extract_id "$HADD")"
      echo "    http 源 add 输出: $HADD | id=$HID"
      assert_exit 0 $HARC "SUB5 add(http:// 源,approve)退出码=0(真 RealSubscriptionSourcePort http 路径跑通)"
      assert_contains "$HADD" '"added":true' "SUB5 http 源 add 成功(added=true)"
      "$BIN/aa" capabilities call proxy.subscription.activate --input "{\"id\":\"$HID\"}" --json >/dev/null 2>&1; HACT=$?
      assert_exit 0 $HACT "SUB5 activate(http 源订阅,normal)退出码=0"
      GH="$("$BIN/aa" proxy groups --json 2>/dev/null)"
      echo "    http 源激活后 groups: $GH"
      assert_contains "$GH" '"now":"A1"' "SUB5 http 源激活后读回 PROXY now=A1(http 拉取的配置生效)"
    else
      echo "FAIL: SUB5 宿主/REST 未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
    fi
  else
    echo "FAIL: SUB5 http 假源未就绪(端口 $SUBHTTP_PORT 起不来;若持续 flaky 应降级为仅 file:// 并由 Fake 单测覆盖 http 路径)"; FAIL=$((FAIL+1))
  fi
  # 收场 http 假源(按 PID kill + 轮询等真死,绝不残留;绝不 pkill 'http.server' 误伤用户机)。
  kill "$SUBHTTP_PID" 2>/dev/null
  for _ in $(seq 1 30); do kill -0 "$SUBHTTP_PID" 2>/dev/null || break; sleep 0.1; done
fi

# —— 场景 6(F3):activate 后重启宿主 → 自动重载激活订阅配置(catalog 与内核不发散)——
SUBDIR6="$BUILD/subs6"; rm -rf "$SUBDIR6"; mkdir -p "$SUBDIR6"
start_host_sub approve "$SUBDIR6"
if [ "$SOCK_UP" -eq 1 ] && wait_rest_ready; then
  R6ADD="$("$BIN/aa" capabilities call proxy.subscription.add --input "{\"name\":\"subA\",\"source\":\"file://$SUBA_FIX\"}" --json 2>/dev/null)"
  R6ID="$(extract_id "$R6ADD")"
  "$BIN/aa" capabilities call proxy.subscription.activate --input "{\"id\":\"$R6ID\"}" --json >/dev/null 2>&1
  SPRE="$("$BIN/aa" proxy status --json 2>/dev/null)"
  echo "    SUB6 激活后(重启前)status: $SPRE"
  assert_contains "$SPRE" '"mode":"global"' "SUB6 前置:激活 A 后 mode=global"
  # 重启宿主(同 SUBDIR6,**不调 update/activate**)——新 stub 初始 mode=rule;靠 reloadActiveIfAny 自动恢复到 A。
  start_host_sub approve "$SUBDIR6"
  if [ "$SOCK_UP" -eq 1 ] && wait_rest_ready; then
    echo "    SUB6 重启恢复日志:"; grep -F '重启恢复' "$HOSTLOG" | sed 's/^/      /'
    assert_contains "$(cat "$HOSTLOG")" "重启恢复: 已让内核重载当前激活订阅的配置" "SUB6 F3:宿主启动机械补齐(重载激活订阅日志)"
    SRE="$("$BIN/aa" proxy status --json 2>/dev/null)"
    echo "    SUB6 重启后 status: $SRE"
    assert_contains "$SRE" '"mode":"global"' "SUB6 F3:重启后自动重载激活订阅配置(status mode=global,不发散)"
    GRE="$("$BIN/aa" proxy groups --json 2>/dev/null)"
    assert_contains "$GRE" '"now":"A1"' "SUB6 F3:重启后 groups 读回 PROXY now=A1(激活态自动恢复)"
  else
    echo "FAIL: SUB6 重启宿主未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
  fi
else
  echo "FAIL: SUB6 前置宿主未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# 清场:杀宿主 + stub(轮询等真死;trap 亦兜底)
teardown_hosts also-stub

# --- 断言组 3:PluginProxy 不依赖任何 Host*(01 票铁律,继续把关)---
echo "--- 断言组 3:PluginProxy 不依赖任何 Host* ---"
# (3a) 源码级 grep 守卫:PluginProxy 源码不得 import 任何 Host* 模块。
# 正则放宽以覆盖子句形 import(如 `import struct AAHostRuntime.Foo`),不止裸 `import AAHostRuntime`。
# 显式判 grep 退出码,杜绝假绿:rc==1 无匹配(好)/ rc==0 命中禁止 import(坏)/ rc>=2 grep 自身出错(无法核验,绝不算过)。
GREP_HITS="$(grep -REn 'import[[:space:]]+([a-z]+[[:space:]]+)?AAHost(Runtime|MacOS|TestKit)' Sources/PluginProxy/)"
GREP_RC=$?
if [ "$GREP_RC" -eq 1 ]; then
  echo "PASS: PluginProxy 源码不含 import Host*(AAHostRuntime|AAHostMacOS|AAHostTestKit)"; PASS=$((PASS+1))
elif [ "$GREP_RC" -eq 0 ]; then
  echo "FAIL: PluginProxy 源码出现 Host* 的 import:"; printf '%s\n' "$GREP_HITS"; FAIL=$((FAIL+1))
else
  echo "FAIL: grep 守卫自身出错(rc=$GREP_RC),无法核验 PluginProxy 边界 —— 绝不算过"; FAIL=$((FAIL+1))
fi
# (3b) 编译期守卫:上面阶段 A 已用「仅 SDK/Contracts/UISystem 的 -I」编过 PluginProxy,能到这里即已证明。
echo "PASS: PluginProxy 已在受限 -I(无 Host* 模块)下编译成功 —— 编译期证明不需要 Host*"
PASS=$((PASS+1))

# (3c) 06 票 Port 落点核验:ProcessPort/HTTPPort **协议**必须声明在 AAPluginSDK(插件只依赖 SDK),Host* 侧只能是实现/假件。
PORT_DECL_SDK="$(grep -REn 'protocol[[:space:]]+(ProcessPort|HTTPPort)' Sources/AAPluginSDK/)"
if [ -n "$PORT_DECL_SDK" ]; then
  echo "PASS: ProcessPort/HTTPPort 协议声明在 AAPluginSDK(插件只依赖 SDK 即可用)"; PASS=$((PASS+1))
else
  echo "FAIL: 未在 AAPluginSDK 找到 ProcessPort/HTTPPort 协议声明"; FAIL=$((FAIL+1))
fi
PORT_DECL_HOST="$(grep -REn 'protocol[[:space:]]+(ProcessPort|HTTPPort)' Sources/AAHostMacOS/ Sources/AAHostRuntime/ Sources/AAHostTestKit/)"
GREP_PORT_RC=$?
if [ "$GREP_PORT_RC" -eq 1 ] && [ -z "$PORT_DECL_HOST" ]; then
  echo "PASS: Host* 侧不声明 Port 协议(只提供真实现/假件),边界正确"; PASS=$((PASS+1))
else
  echo "FAIL: Port 协议不应声明在 Host*(命中: $PORT_DECL_HOST)"; FAIL=$((FAIL+1))
fi

# (3d) 08 票新增 Port 落点核验:TakeoverStateStore/ProcessReaper **协议**必须声明在 AAPluginSDK(插件只依赖 SDK),Host* 侧只能是实现/假件。
NEWPORT_DECL_SDK="$(grep -REn 'protocol[[:space:]]+(TakeoverStateStore|ProcessReaper)' Sources/AAPluginSDK/)"
if [ -n "$NEWPORT_DECL_SDK" ]; then
  echo "PASS: TakeoverStateStore/ProcessReaper 协议声明在 AAPluginSDK(08 新 Port 亦在 SDK,插件不依赖 Host*)"; PASS=$((PASS+1))
else
  echo "FAIL: 未在 AAPluginSDK 找到 TakeoverStateStore/ProcessReaper 协议声明"; FAIL=$((FAIL+1))
fi
NEWPORT_DECL_HOST="$(grep -REn 'protocol[[:space:]]+(TakeoverStateStore|ProcessReaper)' Sources/AAHostMacOS/ Sources/AAHostRuntime/ Sources/AAHostTestKit/)"
NEWPORT_RC=$?
if [ "$NEWPORT_RC" -eq 1 ] && [ -z "$NEWPORT_DECL_HOST" ]; then
  echo "PASS: Host* 侧不声明 08 新 Port 协议(只提供文件后端/假件),边界正确"; PASS=$((PASS+1))
else
  echo "FAIL: 08 新 Port 协议不应声明在 Host*(命中: $NEWPORT_DECL_HOST)"; FAIL=$((FAIL+1))
fi

# (3e) 10 票新增 Port 落点核验:SubscriptionStore/SubscriptionSourcePort **协议**必须声明在 AAPluginSDK,Host* 侧只能是真实现/假件。
SUBPORT_DECL_SDK="$(grep -REn 'protocol[[:space:]]+(SubscriptionStore|SubscriptionSourcePort)' Sources/AAPluginSDK/)"
if [ -n "$SUBPORT_DECL_SDK" ]; then
  echo "PASS: SubscriptionStore/SubscriptionSourcePort 协议声明在 AAPluginSDK(10 新 Port 亦在 SDK,插件不依赖 Host*)"; PASS=$((PASS+1))
else
  echo "FAIL: 未在 AAPluginSDK 找到 SubscriptionStore/SubscriptionSourcePort 协议声明"; FAIL=$((FAIL+1))
fi
SUBPORT_DECL_HOST="$(grep -REn 'protocol[[:space:]]+(SubscriptionStore|SubscriptionSourcePort)' Sources/AAHostMacOS/ Sources/AAHostRuntime/ Sources/AAHostTestKit/)"
SUBPORT_RC=$?
if [ "$SUBPORT_RC" -eq 1 ] && [ -z "$SUBPORT_DECL_HOST" ]; then
  echo "PASS: Host* 侧不声明 10 新 Port 协议(只提供文件后端/真网络/假件),边界正确"; PASS=$((PASS+1))
else
  echo "FAIL: 10 新 Port 协议不应声明在 Host*(命中: $SUBPORT_DECL_HOST)"; FAIL=$((FAIL+1))
fi

# --- 断言组 4:退出码语义表落进 CLI 帮助(逐码断言;补足 2/denied 无行为路径的那一码)---
echo "--- 断言组 4:aa --help 退出码语义表(逐码)---"
HELP="$("$BIN/aa" --help 2>&1)"; RC=$?
assert_exit 0 $RC "aa --help 退出码=0"
assert_contains "$HELP" "0  成功" "帮助含退出码 0=成功"
assert_contains "$HELP" "1  用法错" "帮助含退出码 1=用法错"
assert_contains "$HELP" "2  denied" "帮助含退出码 2=denied(04 票)"
assert_contains "$HELP" "3  超时" "帮助含退出码 3=超时"
assert_contains "$HELP" "4  宿主不可达" "帮助含退出码 4=宿主不可达"
assert_contains "$HELP" "5  能力业务失败" "帮助含退出码 5=能力业务失败"
assert_contains "$HELP" "6  协议/校验错" "帮助含退出码 6=协议/校验错"

# --- 断言组 5:aa docs agents-md 接入片段(05 票;纯文档,无需宿主)---
echo "--- 断言组 5:aa docs agents-md 接入片段(05 票)---"
DOCS="$("$BIN/aa" docs agents-md 2>/dev/null)"; RC=$?
assert_exit 0 $RC "aa docs agents-md 退出码=0"
assert_contains "$DOCS" "prefix_rule" "docs 含 Codex prefix_rule 信任配置示例(S3 沙箱姿态)"
assert_contains "$DOCS" "require_escalated" "docs 含 require_escalated(沙箱外执行的提权声明)"
assert_contains "$DOCS" "capabilities call" "docs 含发现/调用命令(capabilities call/list/describe)"
assert_contains "$DOCS" "When to use" "docs 含「何时用本 CLI」段"
assert_contains "$DOCS" "dangerous" "docs 含 dangerous 语义说明"
assert_contains "$DOCS" "exit code" "docs 含退出码语义(exit code 契约)"

# --- 断言组 6:aa install-cli 幂等/覆盖(05 票;临时目录,绝不碰真实 /usr/local/bin)---
echo "--- 断言组 6:aa install-cli 幂等/覆盖(05 票,临时目录)---"
IP1="$BUILD/install-prefix1"; mkdir -p "$IP1"
"$BIN/aa" install-cli --prefix "$IP1" >/dev/null 2>&1; RC=$?
assert_exit 0 $RC "install-cli 首次 --prefix 退出码=0"
if [ -L "$IP1/aa" ]; then
  echo "PASS: install-cli 建了符号链接 $IP1/aa"; PASS=$((PASS+1))
else
  echo "FAIL: install-cli 未建符号链接 $IP1/aa"; FAIL=$((FAIL+1))
fi
"$IP1/aa" --help >/dev/null 2>&1; RC=$?
assert_exit 0 $RC "经符号链接调用 aa --help 成功(链接指向可用的真 aa)"
IOUT="$("$BIN/aa" install-cli --prefix "$IP1" --json 2>/dev/null)"; RC=$?
assert_exit 0 $RC "install-cli 幂等重跑退出码=0"
assert_contains "$IOUT" "already-installed" "install-cli 幂等重跑报告 already-installed(no-op)"
# 指向别处 → 无 --force 报错;--force 覆盖成功
IP2="$BUILD/install-prefix2"; mkdir -p "$IP2"; ln -s /bin/ls "$IP2/aa"
"$BIN/aa" install-cli --prefix "$IP2" >/dev/null 2>&1; RC=$?
assert_exit 1 $RC "install-cli 目标指向别处且无 --force → 退出码=1(明确报告)"
"$BIN/aa" install-cli --prefix "$IP2" --force >/dev/null 2>&1; RC=$?
assert_exit 0 $RC "install-cli --force 覆盖成功 退出码=0"
"$IP2/aa" --help >/dev/null 2>&1; RC=$?
assert_exit 0 $RC "--force 覆盖后符号链接指向真 aa(卸载/覆盖行为明确)"
# 目标目录不存在 → 明确错误(退出码 1)
"$BIN/aa" install-cli --prefix "$BUILD/no-such-dir" >/dev/null 2>&1; RC=$?
assert_exit 1 $RC "install-cli 目标目录不存在 → 退出码=1(明确错误)"

# (hard bug2 修复)canonical 化比较:相对符号链接指向同一 aa → 判 already-installed(不逼 --force)。
#   $BIN=$BUILD/bin;从 $IPCANON 用相对路径 ../bin/aa 指向同一真 aa,字面≠已 canonical 的 source,但解析后应相等。
IPCANON="$BUILD/install-canon"; mkdir -p "$IPCANON"
( cd "$IPCANON" && ln -s "../bin/aa" "aa" )
CANOUT="$("$BIN/aa" install-cli --prefix "$IPCANON" --json 2>/dev/null)"; RC=$?
echo "    相对链接 install 输出: $CANOUT"
assert_exit 0 $RC "install-cli 相对链接指向同一 aa → 退出码=0(canonical 化)"
assert_contains "$CANOUT" "already-installed" "install-cli canonical 化后相对链接判 already-installed(hard bug2 修复:不误判指向别处)"

# --- --uninstall 幂等 + 拒误删(仍只用临时 prefix)---
IPUN="$BUILD/install-uninst"; mkdir -p "$IPUN"
"$BIN/aa" install-cli --prefix "$IPUN" >/dev/null 2>&1; RC=$?
assert_exit 0 $RC "install-cli(--uninstall 前置)安装退出码=0"
UOUT="$("$BIN/aa" install-cli --uninstall --prefix "$IPUN" --json 2>/dev/null)"; RC=$?
assert_exit 0 $RC "install-cli --uninstall 退出码=0"
assert_contains "$UOUT" "uninstalled" "--uninstall 删除本 aa 链接(action=uninstalled)"
if [ -e "$IPUN/aa" ]; then echo "FAIL: --uninstall 后链接仍在"; FAIL=$((FAIL+1)); else echo "PASS: --uninstall 后链接已删除"; PASS=$((PASS+1)); fi
UOUT2="$("$BIN/aa" install-cli --uninstall --prefix "$IPUN" --json 2>/dev/null)"; RC=$?
assert_exit 0 $RC "install-cli --uninstall 幂等重跑(目标不存在)退出码=0"
assert_contains "$UOUT2" "not-installed" "--uninstall 幂等 no-op(action=not-installed)"
# 拒误删:指向别处的链接(非本 aa)→ 退出码 1 且不删
IPFOREIGN="$BUILD/install-foreign"; mkdir -p "$IPFOREIGN"; ln -s /bin/ls "$IPFOREIGN/aa"
"$BIN/aa" install-cli --uninstall --prefix "$IPFOREIGN" >/dev/null 2>&1; RC=$?
assert_exit 1 $RC "install-cli --uninstall 拒删非本 aa 链接 → 退出码=1"
if [ -L "$IPFOREIGN/aa" ]; then echo "PASS: --uninstall 未误删指向别处的链接(不误删非自己建的)"; PASS=$((PASS+1)); else echo "FAIL: --uninstall 误删了别处链接"; FAIL=$((FAIL+1)); fi

# --- 断言组 R:跑完清场核验(无残留宿主 / stub / 假监听器)---
echo "--- 断言组 R:跑完清场核验(无残留)---"
sleep 1
RES_HOST="$(pgrep -f "$KILLPAT")"
RES_STUB="$(pgrep -f "$KILLPAT_STUB")"
RES_LIS="$(pgrep -f "timeout_listener.py")"
if [ -z "$RES_HOST" ]; then echo "PASS: 无残留宿主进程"; PASS=$((PASS+1)); else echo "FAIL: 残留宿主进程: $RES_HOST"; FAIL=$((FAIL+1)); fi
if [ -z "$RES_STUB" ]; then echo "PASS: 无残留 fake mihomo stub 进程"; PASS=$((PASS+1)); else echo "FAIL: 残留 stub 进程: $RES_STUB"; FAIL=$((FAIL+1)); fi
if [ -z "$RES_LIS" ]; then echo "PASS: 无残留超时假监听器进程"; PASS=$((PASS+1)); else echo "FAIL: 残留假监听器: $RES_LIS"; FAIL=$((FAIL+1)); fi
# 10:订阅 http 假源按 PID 核验已收场(不残留);SUB5 内已 kill+等真死,此处兜底核验。
if [ -n "${SUBHTTP_PID:-}" ] && kill -0 "$SUBHTTP_PID" 2>/dev/null; then echo "FAIL: 残留订阅 http 假源进程: $SUBHTTP_PID"; FAIL=$((FAIL+1)); else echo "PASS: 无残留订阅 http 假源进程(按 PID 收场)"; PASS=$((PASS+1)); fi

# 08:未污染真实 AppSupport 接管态文件的证明(跑前后 md5 一致;所有测试宿主的持久化都被 env seam 导向 $BUILD 临时区)。
REAL_TAKEOVER_AFTER="$( [ -e "$REAL_TAKEOVER" ] && md5 -q "$REAL_TAKEOVER" 2>/dev/null || echo ABSENT )"
if [ "$REAL_TAKEOVER_BEFORE" = "$REAL_TAKEOVER_AFTER" ]; then echo "PASS: 未污染真实 AppSupport 接管态文件(跑前后一致: $REAL_TAKEOVER_AFTER)"; PASS=$((PASS+1)); else echo "FAIL: 真实 AppSupport 接管态文件被本次运行改动(before=$REAL_TAKEOVER_BEFORE after=$REAL_TAKEOVER_AFTER)"; FAIL=$((FAIL+1)); fi
# 10:未污染真实 AppSupport 订阅目录的证明(所有测试宿主的订阅目录都被 env seam 导向 $BUILD 临时区)。
REAL_SUBS_AFTER="$( [ -e "$REAL_SUBS_DIR" ] && ls -laR "$REAL_SUBS_DIR" 2>/dev/null | md5 2>/dev/null || echo ABSENT )"
if [ "$REAL_SUBS_BEFORE" = "$REAL_SUBS_AFTER" ]; then echo "PASS: 未污染真实 AppSupport 订阅目录(跑前后一致)"; PASS=$((PASS+1)); else echo "FAIL: 真实 AppSupport 订阅目录被本次运行改动(before=$REAL_SUBS_BEFORE after=$REAL_SUBS_AFTER)"; FAIL=$((FAIL+1)); fi

echo
echo "========================================"
echo " 结果: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo " ALL PASS ✅"
  echo "========================================"
  exit 0
else
  echo " 有失败,见上 ❌"
  echo "========================================"
  exit 1
fi
