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

SWIFTC_COMMON=(-swift-version 5 -vfsoverlay "$OVERLAY" -module-cache-path "$MCACHE")

# 超时 E2E 用的「只 accept 不回应」假监听器脚本(python3,绑定同一 socket 路径);清场按此模式兜底。
TIMEOUT_LISTENER="$BUILD/timeout_listener.py"

# 失败/成功任一路径都清场,杜绝僵尸宿主 / 残 socket / 残假监听器。
cleanup() {
  pkill -f "$KILLPAT" 2>/dev/null
  pkill -f "$KILLPAT_STUB" 2>/dev/null
  pkill -f "timeout_listener.py" 2>/dev/null
  pkill -f "raw_uds_client.py" 2>/dev/null
  rm -f "$SOCK" 2>/dev/null
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

# agent-delegation 01:AAAgentCore(「宿主调用本地 agent」适配层地基;只依赖 Contracts,与 16 票并行)。
#   放在 Contracts 之后即满足拓扑序;纯逻辑 + Port 协议 + 6 型消息,vfsoverlay 可验。
build_lib AAAgentCore

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

# agent-delegation 01:AAAgentTestKit(AAAgentCore 的独立测试基建:FakeAgentPort + 一致性测试;依赖 AAAgentCore + Contracts)。
#   刻意独立于 AAHostTestKit(避与 v1 施工撞车);在 AAAgentCore 编好后即可编,链接进下面的测试 runner。
build_lib AAAgentTestKit

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
// 门禁自动生成:纯逻辑测试的入口 shim(断言逻辑在 AAHostTestKit / AAAgentTestKit)。
// 06 票:除 RegistryConformanceTests 外,追加 ProxyConformanceTests(Port 假件 / RESTClient / proxy.status 域逻辑)。
// agent-delegation 01:再追加 AAAgentCoreConformanceTests(FakeAgentPort 主 seam + 6 型消息模型;独立 AgentTestReport)。
// agent-delegation 02:再追加 ClaudeAdapterTests(stream-json 归一化;喂 01 spike 落盘的真实 NDJSON 黄金样本,
//   样本目录经 AA_SPIKE_DIR 注入 —— 见下方 runner 调用行;缺失即 fail-closed 记 FAIL,不静默跳过)。
// agent-delegation 03:再追加 CodexAdapterTests(codex exec --json 归一化;喂 02 spike 落盘的真实 jsonl 黄金样本,
//   同一个 AA_SPIKE_DIR 注入点,子目录 spike-codex-exec/samples;同样 fail-closed)。
// agent-delegation 04:再追加 AgentTaskTests(任务状态机 + 工作区落盘;全程经 FakeFileSystem/FakeClock/FakeLiveness,
//   零真实文件系统、零真实时钟、零真实进程,故**不需要**任何样本目录或环境变量注入)。
// agent-delegation 05:再追加 AgentWatchdogTests(消息静默看门狗 + 取消/超时中断语义;时间由测试直接喂 epoch 秒、
//   进程由 FakeAgentPort 假冒 —— **零真实等待、零真进程**,同样不需要样本目录或环境变量注入)。
import AAHostTestKit
import AAAgentTestKit
import Foundation
let r1 = RegistryConformanceTests.run()
for line in r1.lines { print(line) }
let r2 = ProxyConformanceTests.run()
for line in r2.lines { print(line) }
let r3 = AAAgentCoreConformanceTests.run()
for line in r3.lines { print(line) }
let r4 = ClaudeAdapterTests.run()
for line in r4.lines { print(line) }
let r5 = CodexAdapterTests.run()
for line in r5.lines { print(line) }
let r6 = AgentTaskTests.run()
for line in r6.lines { print(line) }
let r7 = AgentWatchdogTests.run()
for line in r7.lines { print(line) }
print("REGISTRY_TESTS passed=\(r1.passed) failed=\(r1.failed)")
print("PROXY_TESTS passed=\(r2.passed) failed=\(r2.failed)")
print("AGENTCORE_TESTS passed=\(r3.passed) failed=\(r3.failed)")
print("CLAUDEADAPTER_TESTS passed=\(r4.passed) failed=\(r4.failed)")
print("CODEXADAPTER_TESTS passed=\(r5.passed) failed=\(r5.failed)")
print("AGENTTASK_TESTS passed=\(r6.passed) failed=\(r6.failed)")
print("WATCHDOG_TESTS passed=\(r7.passed) failed=\(r7.failed)")
let failed = r1.failed + r2.failed + r3.failed + r4.failed + r5.failed + r6.failed + r7.failed
print("ALL_UNIT passed=\(r1.passed + r2.passed + r3.passed + r4.passed + r5.passed + r6.passed + r7.passed) failed=\(failed)")
fflush(stdout)
exit(failed == 0 ? 0 : 1)
SWIFT
swiftc "${SWIFTC_COMMON[@]}" \
  -I "$MODULES" \
  -o "$TESTRUNNER" \
  "$OBJ/AAContracts.o" "$OBJ/AAHostRuntime.o" "$OBJ/AAHostTestKit.o" \
  "$OBJ/AAPluginSDK.o" "$OBJ/PluginProxy.o" "$OBJ/AAUISystem.o" \
  "$OBJ/AAAgentCore.o" "$OBJ/AAAgentTestKit.o" \
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

# --- 断言组 1:Registry 纯逻辑(经 AAHostTestKit 假件,不起真宿主 / 不碰 UDS)---
echo "--- 断言组 1:Registry 纯逻辑(AAHostTestKit.RegistryConformanceTests)---"
# AA_SPIKE_DIR:agent-delegation 两家 adapter 的黄金样本根目录(单一真相源,不复制成常量)。**两个消费方**:
#   * 02 的 ClaudeAdapterTests → 读 `$AA_SPIKE_DIR/spike-claude-headless/*.stdout.ndjson`(01 spike 落盘)
#   * 03 的 CodexAdapterTests  → 读 `$AA_SPIKE_DIR/spike-codex-exec/samples/*.stdout.jsonl`(02 spike 落盘)
#   改这一行会同时影响断言组 1d 与 1e —— 别以为「只为 Claude 挪样本」不波及 Codex。
#   样本目录缺失时两个套件各自 fail-closed 记 FAIL(不静默跳过),故这里只负责如实注入路径。
OUT="$(AA_SPIKE_DIR="$ROOT/.scratch/agent-delegation/research" "$TESTRUNNER" 2>&1)"; RC=$?
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

# agent-delegation 01 纯逻辑断言(同一 runner 输出;AAAgentCoreConformanceTests:FakeAgentPort 主 seam + 6 型消息模型)。
# 说明:PASS/FAIL 均含描述串,故这些 assert_contains 证明「断言确已运行(路径被跑到)」;
#       零失败由上面「registry-tests 全绿退出码」(runner 任一 r*.failed>0 即 exit 1)兜底保证。
echo "--- 断言组 1c:AAAgentCore 骨架纯逻辑(AAAgentCoreConformanceTests)---"
assert_contains "$OUT" "AGENTCORE_TESTS passed=" "agent-delegation 01 纯逻辑套件已运行(AAAgentCoreConformanceTests)"
assert_contains "$OUT" "假 AgentPort:launch 记录可执行路径" "①FakeAgentPort:launch 记录启动规格"
assert_contains "$OUT" "假 AgentPort:launch 记录 stdin 处置(writeThenKeepOpen)" "①FakeAgentPort:记录 stdin 处置策略"
assert_contains "$OUT" "假 AgentPort:nextEvent 依次弹出预置脚本第 1 行" "①FakeAgentPort:nextEvent 依次回放事件脚本"
assert_contains "$OUT" "假 AgentPort:脚本弹完后 nextEvent 返回 nil" "①FakeAgentPort:脚本弹完→nil"
assert_contains "$OUT" "假 AgentPort:进程中途死亡后 nextEvent 返回 nil(脚本未弹完亦然)" "①FakeAgentPort:中途死亡→nextEvent nil"
assert_contains "$OUT" "假 AgentPort:终止调用被记录(取消/反孤儿可核验)" "①FakeAgentPort:terminate 记录"
assert_contains "$OUT" "假 AgentPort:programNextLaunchToFail 后 launch 抛错" "①FakeAgentPort:编程 launch 失败"
assert_contains "$OUT" "AgentMessage.toolUse:kind/tool/callID/input 正确" "②AgentMessage:便利构造器 toolUse 关键字段"
assert_contains "$OUT" "AgentMessage:toolUse 的 callID 经 Codable round-trip 保留" "②AgentMessage:CallID round-trip 全链保留"
assert_contains "$OUT" "AgentMessage:text 消息编码后 JSON 不含 nil 键 tool(encodeIfPresent)" "②AgentMessage:nil 键省略(encodeIfPresent)"
assert_contains "$OUT" "AgentMessage:6 型样本经 JSONEncoder/Decoder round-trip 全等" "②AgentMessage:6 型 Codable round-trip 全等"

# agent-delegation 02 纯逻辑断言(同一 runner 输出;ClaudeAdapterTests:stream-json 归一化,喂 01 spike 的真实 NDJSON 黄金样本)。
# 口径同 1c:PASS/FAIL 均含描述串,故这些 assert_contains 证明「断言确已运行(样本被真读到、路径被跑到)」;
#   零失败由上面「registry-tests 全绿退出码」(runner 任一 r*.failed>0 即 exit 1)兜底保证。
# 样本目录经上面 runner 调用行的 AA_SPIKE_DIR 注入;缺失/不存在时套件自己记 FAIL(fail-closed,绝不静默跳过)。
echo "--- 断言组 1d:Claude adapter 归一化(ClaudeAdapterTests,黄金样本)---"
assert_contains "$OUT" "CLAUDEADAPTER_TESTS passed=" "agent-delegation 02 纯逻辑套件已运行(ClaudeAdapterTests)"
assert_contains "$OUT" "Claude adapter:spike 黄金样本目录存在(不存在即 fail-closed,绝不静默跳过)" "①黄金样本目录经 AA_SPIKE_DIR 真读到(fail-closed)"
assert_contains "$OUT" "Claude adapter:baseline 只读样本消息序列=[status,status,text](终局答复不重复产消息)" "②baseline:消息序列逐型钉死(终局答复不重复)"
assert_contains "$OUT" "Claude adapter:baseline 只读样本终态 finalText 与最后一条 text 消息逐字相同(挪位不丢信息)" "②baseline:终局答复挪进终态 finalText 且不丢"
assert_contains "$OUT" "Claude adapter:baseline 只读样本首条为 session-started 状态消息" "②baseline:system/init → session-started"
assert_contains "$OUT" "Claude adapter:baseline 只读样本终态=succeeded(reason=completed)" "②baseline:终态 succeeded"
assert_contains "$OUT" "Claude adapter:tool-use 样本 tool-use 与 tool-result 的 callID 相等(全链配对不丢)" "③tool-use:CallID 全链配对不丢(修 multica 有损点)"
assert_contains "$OUT" "Claude adapter:tool-use 样本工具名归一为 Write" "③tool-use:工具名归一"
assert_contains "$OUT" "Claude adapter:越界写样本(07)终态=succeeded(cwd 不是安全边界,归一化层面无差别)" "④越界写:归一化层面与正常写无差别"
assert_contains "$OUT" "Claude adapter:中断样本(04)终态=aborted(该样本 is_error 也为 true,判定顺序 aborted 在 failed 前)" "⑤中断:终态 aborted(判定顺序不可颠倒)"
assert_contains "$OUT" "Claude adapter:中断样本(04)额外产出 interrupted 状态消息(中断在消息流里也可见)" "⑤中断:产出 interrupted 状态消息"
assert_contains "$OUT" "Claude adapter:中断样本(04)中断提示绝不归一为 agent 的 text 输出(不混淆发言方)" "⑤中断:user 文本不混淆为 agent 发言"
assert_contains "$OUT" "Claude adapter:invalid-model 样本(05)终态=failed(is_error/api_error_status/terminal_reason 联合判定)" "⑥invalid-model:终态 failed(多字段联合)"
assert_contains "$OUT" "Claude adapter:invalid-model 样本(05)原生 subtype 字面仍是 success —— 终态判定绝不能只看 subtype" "⑥invalid-model:「不能只看 subtype」回归护栏"
assert_contains "$OUT" "Claude adapter:被拒样本(03)产出 permission-denied 状态消息(kind=status,保留工具名 Write)" "⑦被拒:permission_denials → 统一「操作被拒」status"
assert_contains "$OUT" "Claude adapter:被拒样本(03)permission-denied 的 callID 与 is_error=true 的 tool_result 对得上" "⑦被拒:被拒信号与 tool_result 全链对得上"
assert_contains "$OUT" "Claude adapter:被拒样本(03)终态=succeeded(被拒 ≠ 终态失败,不能靠终态判断有没有被拒)" "⑦被拒:被拒 ≠ 终态失败"
assert_contains "$OUT" "Claude adapter:control_request 归一为 status=unknown:control_request(未知双向消息不崩、不产终态)" "⑧兜底:control_request 记录不崩(V1 不应答)"
assert_contains "$OUT" "Claude adapter:非 JSON 垃圾行归一为 status=unparsed 且保留原始行(不崩不抛)" "⑧兜底:垃圾行 unparsed 不崩"
assert_contains "$OUT" "Claude adapter:空行产出 0 条消息(不报错)" "⑧兜底:空行 0 条消息"
# ⑨ CR 结论的回归护栏:八组黄金样本都覆盖不到这一支(样本里 error_during_execution 恒与 aborted_streaming 同现),
#    故用构造行钉死——非中断的执行期错误必须判 failed,且不得凭空注入 interrupted(失败被伪装成取消最难被发现)。
assert_contains "$OUT" "Claude adapter:非中断的 error_during_execution 判 failed(真失败绝不伪装成被取消)" "⑨回归:非中断 error_during_execution → failed"
assert_contains "$OUT" "Claude adapter:非中断的 error_during_execution 不注入 interrupted 消息(不无中生有)" "⑨回归:不无中生有 interrupted"

# agent-delegation 03 纯逻辑断言(同一 runner 输出;CodexAdapterTests:codex exec --json 归一化,喂 02 spike 的真实 jsonl 黄金样本)。
# 口径同 1d:PASS/FAIL 均含描述串,故这些 assert_contains 证明「断言确已运行(样本被真读到、路径被跑到)」;
#   零失败由上面「registry-tests 全绿退出码」(runner 任一 r*.failed>0 即 exit 1)兜底保证。
# 样本目录经上面 runner 调用行的 AA_SPIKE_DIR 注入(子目录 spike-codex-exec/samples);缺失/不存在时套件自己记 FAIL。
echo "--- 断言组 1e:Codex adapter 归一化(CodexAdapterTests,黄金样本)---"
assert_contains "$OUT" "CODEXADAPTER_TESTS passed=" "agent-delegation 03 纯逻辑套件已运行(CodexAdapterTests)"
assert_contains "$OUT" "Codex adapter:spike 黄金样本目录存在(不存在即 fail-closed,绝不静默跳过)" "①黄金样本目录经 AA_SPIKE_DIR 真读到(fail-closed)"
assert_contains "$OUT" "Codex adapter:baseline 样本(exec1)消息序列=[status,status,tool-use,tool-result,text,status]" "②baseline:消息序列逐型钉死"
assert_contains "$OUT" "Codex adapter:baseline 样本(exec1)sessionID 逐字取自首行 thread_id(不必等文件落盘)" "②baseline:thread_id → sessionID(首行直取)"
assert_contains "$OUT" "Codex adapter:baseline 样本(exec1)终态=succeeded(reason=turn.completed)" "②baseline:终态 succeeded"
assert_contains "$OUT" "Codex adapter:baseline 样本(exec1)终态 finalText 恒为 nil(Codex 原生无终局答复字段,04 退回取最后一条 text)" "②baseline:finalText 恒 nil(与 Claude 侧不对称)"
assert_contains "$OUT" "Codex adapter:写尝试样本(exec2)item.started 与 item.completed 同一个 item_1 归一为相等 callID(全链配对不丢)" "③写尝试:CallID 全链配对不丢(修 multica 有损点)"
assert_contains "$OUT" "Codex adapter:写尝试样本(exec2)工具失败但终态仍是 succeeded(工具失败不等于回合失败)" "③写尝试:工具失败 ≠ 回合失败"
# ④⑦ 本票最重要的两条:Codex 中断/硬超时时流里**根本没有终态行**,adapter 必须诚实交回 nil(终态由上层据退出码补)。
assert_contains "$OUT" "Codex adapter:硬超时样本(exec3)terminal 恒为 nil(流里没有终态行就绝不臆造,终态由上层据退出码补)" "④硬超时:terminal 恒为 nil(不臆造终态)"
assert_contains "$OUT" "Codex adapter:硬超时样本(exec3)逐行归一化没有任何一行产出终态(error 行绝不是失败判据)" "④硬超时:error 行绝不产终态(瞬态噪音)"
assert_contains "$OUT" "Codex adapter:中断样本(exec5)terminal 恒为 nil(Codex 被信号杀不补终态行,与 Claude 侧不对称)" "⑦中断:terminal 恒为 nil(与 Claude 侧不对称的回归护栏)"
# ⑤⑥ 静默空气墙:被拦的写连 item 都不出现,V1 诚实记录此限制、绝不合成拒绝消息。
assert_contains "$OUT" "Codex adapter:静默空气墙样本(exec3b)V1 绝不合成 permission-denied 消息(Codex 侧拒绝不可识别,不臆造)" "⑤静默空气墙:不合成拒绝消息(票面第 4 条)"
assert_contains "$OUT" "Codex adapter:沙箱边界样本(exec4)两次强制调用只有 cwd 内那次留下一对 item,越界那次归一化后同样零痕迹" "⑥沙箱边界:越界写零痕迹(不臆造第二对 item)"
# ⑧⑨ 双层编码错因:exec6 解出内层人话,exec7(纯文本)优雅退化为原串。
assert_contains "$OUT" "Codex adapter:invalid-model 样本(exec6)双层解码后 reason 是内层那句人话" "⑧invalid-model:双层解码取内层错因"
assert_contains "$OUT" "Codex adapter:invalid-model 样本(exec6)reason 不残留外层 JSON 字面(双层解码真解到了内层)" "⑧invalid-model:外层字面不残留"
assert_contains "$OUT" "Codex adapter:无鉴权样本(exec7)error.message 非 JSON 时 reason 逐字退化为原串(解不出不丢信息、不崩)" "⑨无鉴权:非 JSON 错因优雅退化"
assert_contains "$OUT" "Codex adapter:顶层 error 归一为 error 型消息且绝不产终态(瞬态重连噪音不是失败)" "⑩兜底:顶层 error 绝不产终态"
assert_contains "$OUT" "Codex adapter:未知 item 类型归一为 status=unknown-item:file_change 且保留 callID=item_9" "⑩兜底:未知 item 类型保真且保住 callID"
assert_contains "$OUT" "Codex adapter:非 JSON 垃圾行归一为 status=unparsed 且保留原始行、不产终态(不崩不抛)" "⑩兜底:垃圾行 unparsed 不崩且不产终态"
assert_contains "$OUT" "Codex adapter:空行产出 0 条消息(不报错)" "⑩兜底:空行 0 条消息"
# ⑪ 三支八样本都触发不到的降级(只能靠构造行,照 1d ⑨ 的先例):
#    stderr 噪音是票面「ERROR 字样不作失败判据」的**可测**落点——防的是将来某个真实现把 2>&1 合流后,
#    连成功调用也稳定打的 ERROR 噪音把任务误判成失败(02 spike:8/8 次 stderr 都有 ERROR)。
assert_contains "$OUT" "Codex adapter:stderr 的 ERROR 噪音行只走 unparsed 降级、绝不产终态(ERROR 字样不是失败判据)" "⑪回归:stderr ERROR 噪音不是失败判据"
assert_contains "$OUT" "Codex adapter:turn.failed 缺 error.message 时终态仍 failed、reason 如实留 nil(不臆造理由)" "⑪回归:turn.failed 缺错因不臆造"
assert_contains "$OUT" "Codex adapter:双层解码内层为空时退回外层原串(解得开也不交回空理由)" "⑪回归:双层解码内层为空退回原串"

# agent-delegation 04 纯逻辑断言(同一 runner 输出;AgentTaskTests:任务状态机 + 工作区落盘)。
# 口径同 1c/1d/1e:PASS/FAIL 均含描述串,故这些 assert_contains 证明「断言确已运行(路径被跑到)」;
#   零失败由上面「registry-tests 全绿退出码」(runner 任一 r*.failed>0 即 exit 1)兜底保证。
# 与 1d/1e 不同的是本组**不依赖任何样本目录 / 环境变量**:全程跑在 FakeFileSystem / FakeClock / FakeLiveness 上,
#   零真实文件系统(根目录是内存里的 /fake/agent-tasks 串)、零真实时钟、零真实进程 —— 门禁不会碰用户的 ~/.aa/。
echo "--- 断言组 1f:任务状态机 + 工作区落盘(AgentTaskTests,全假件)---"
assert_contains "$OUT" "AGENTTASK_TESTS passed=" "agent-delegation 04 纯逻辑套件已运行(AgentTaskTests)"
# ① 状态迁移逐条(合法/非法/终态不可复活)
assert_contains "$OUT" "任务状态机:pending 迁 running/failed/cancelled 三条全合法" "①迁移:pending 的三条合法出边"
assert_contains "$OUT" "任务状态机:running 迁 completed/failed/cancelled/timeout/orphaned 五条全合法" "①迁移:running 的五条合法出边"
assert_contains "$OUT" "任务状态机:pending 直接迁 completed 非法(没跑过就不可能完成)" "①迁移:pending→completed 非法"
assert_contains "$OUT" "任务状态机:orphaned 之外的四个终态迁向任何状态一律非法(含迁向自身)" "①迁移:证据终态零出边(含迁向自身)"
# ①b orphaned 是**猜**出来的终态,一手证据(run 进程的 finish)必须能纠正它 —— 且方向单向,证据终态绝不退回 orphaned。
assert_contains "$OUT" "任务状态机:orphaned 迁 completed/failed/cancelled/timeout 四条全合法(推测性终态可被一手证据纠正)" "①b迁移:orphaned 的四条证据升级出边"
assert_contains "$OUT" "任务状态机:四个证据终态一律不得退回 orphaned(证据升级是单向的)" "①b迁移:证据升级单向(不可退回 orphaned)"
assert_contains "$OUT" "任务状态机:orphaned 不可复活成 pending/running 也不可迁向自身(纠正不是复活)" "①b迁移:纠正不是复活"
# ② adapter 终态 → job 状态(含 terminal 缺失时按退出码收敛,02 spike 的 Codex 现实)
assert_contains "$OUT" "终态映射:adapter succeeded 映射为 job completed" "②映射:succeeded→completed"
assert_contains "$OUT" "终态映射:adapter failed 映射为 job failed" "②映射:failed→failed"
assert_contains "$OUT" "终态映射:adapter aborted 映射为 job cancelled" "②映射:aborted→cancelled"
assert_contains "$OUT" "终态收敛:terminal 缺失且退出码为负 判 cancelled(负值即被信号杀)" "②收敛:Codex 无终态行时按负退出码判 cancelled"
assert_contains "$OUT" "终态收敛:所有输入组合都收敛到终态,绝无把任务挂在 running 的路径" "②收敛:绝不把任务永远挂在 running"
# ③ task-id 生成(slug 规则含中文回退)
assert_contains "$OUT" "task-id:固定 stamp 与 suffix 下整体形如 stamp-slug-suffix" "③task-id:整体形状"
assert_contains "$OUT" "task-id:超长 prompt 的 slug 截到 24 字符以内" "③task-id:slug 截断到 24"
assert_contains "$OUT" "task-id:全中文 prompt 折不出字符时回退 task" "③task-id:中文回退 task"
# ③b task-id 形状校验:07 票 CLI 会把用户敲的 id 直接喂进读写路径,生产端口是真 FileManager —— 路径穿越必须拦在域逻辑里。
assert_contains "$OUT" "task-id 校验:空串被拒且磁盘零写入(空 id 会把工作区根目录本身当成一个任务)" "③b穿越:空串被拒且零写入"
assert_contains "$OUT" "task-id 校验:含两点的向上穿越串被拒且磁盘零写入(生产端口是真 FileManager,会越出 root 写文件)" "③b穿越:向上穿越被拒且零写入"
assert_contains "$OUT" "task-id 校验:含斜杠的 id 被拒且磁盘零写入(目录名即 task-id,只准一层扁平结构)" "③b穿越:含斜杠被拒且零写入"
assert_contains "$OUT" "task-id 校验:以点开头的 id 被拒且磁盘零写入(建得出却被 list 与 ls 藏起来的任务是坏证据)" "③b穿越:点开头被拒且零写入"
# ④ 工作区目录结构与 meta 字段(提案 §2/§3)
assert_contains "$OUT" "工作区:create 后任务目录恰是 meta.json/prompt.md/logs/work 四项" "④落盘:目录结构与提案一致"
assert_contains "$OUT" "工作区:logs 目录恰是 raw.ndjson 与 normalized.ndjson 与 stderr.log 三件套" "④落盘:三个日志文件"
assert_contains "$OUT" "工作区:meta.json 落盘含 schema_version 为 1" "④落盘:schema_version=1"
assert_contains "$OUT" "工作区:meta.json 落盘 state 为 pending" "④落盘:新建即 pending"
assert_contains "$OUT" "工作区:委托指定外部 workdir 时不建 work 目录" "④落盘:外部 workdir 不建 work/"
assert_contains "$OUT" "工作区:有副作用任务的 changes.md 经 writeChanges 落盘,且不牵动 meta.json" "④落盘:changes.md 按需产出"
# ④b 半截目录(建了目录但 meta 还没写就崩了)不得被静默复用覆盖 —— 它的 logs/ 可能是上次崩溃的唯一线索。
assert_contains "$OUT" "工作区:缺 meta.json 的半截目录也算已存在,create 抛错且其 logs 证据一字未动" "④b半截目录:create 不覆盖"
assert_contains "$OUT" "工作区:缺 meta.json 的半截目录对 list 不可见(已知限制:证据不销毁优先于自动清理)" "④b半截目录:对 list 不可见(已知限制)"
assert_contains "$OUT" "task-id:时间前缀经 ClockPort 注入而非读系统时钟(故可逐字断言)" "③task-id:时间经 ClockPort 注入可测"
# ⑤ raw 与 normalized 永不互写(提案 §2 的红线)
assert_contains "$OUT" "工作区:raw.ndjson 里不含归一化消息的任何一行(raw 与 normalized 永不互写)" "⑤红线:raw 不含 normalized"
assert_contains "$OUT" "工作区:normalized.ndjson 里不含任何一条原始行(两个文件内容互不含对方)" "⑤红线:normalized 不含 raw"
assert_contains "$OUT" "工作区:文件系统写入失败时如实抛出,不吞错" "⑤落盘:写入失败如实传播"
# CR 回填约束:Codex 的 item 事件不保证被 turn 包住,落盘不得拿 turn 当闸门
assert_contains "$OUT" "工作区:turn-started 之前到达的 item 消息照样全量落盘且次序不变(不拿 turn 边界当闸门)" "CR:pre-turn 的 item 不被丢弃"
# ⑥ meta 单写者 + session_id 立刻落盘
assert_contains "$OUT" "工作区:session_id 拿到即经 updateMeta 落盘(提案 §3 立刻落盘)" "⑥单写者:session_id 拿到即写"
assert_contains "$OUT" "工作区:非法迁移 pending 到 completed 时 updateMeta 抛错" "⑥单写者:非法迁移抛错"
assert_contains "$OUT" "工作区:非法迁移抛错时 meta.json 内容一字未改(绝不静默改写)" "⑥单写者:抛错时磁盘内容不变"
assert_contains "$OUT" "工作区:终态任务再迁向自身被拒且 updateMeta 抛错(终态元数据冻结)" "⑥单写者:终态 meta 冻结"
assert_contains "$OUT" "工作区:updateMeta 改 task_id 被拒并抛 taskIDImmutable(目录名即 id,不容第二个真相)" "⑥单写者:task_id 不可变"
assert_contains "$OUT" "工作区:updateMeta 改 schema_version 被拒并抛 schemaVersionImmutable(版本迁移不是普通更新)" "⑥单写者:schema_version 不可变"
# ⑦ 崩溃残留:标 orphaned 且不销毁证据(提案 §4)
assert_contains "$OUT" "残留扫描:崩溃残留任务的 meta 状态改为 orphaned" "⑦残留:running+pid 已死 → orphaned"
assert_contains "$OUT" "残留扫描:标 orphaned 后 logs 下的 raw.ndjson 一个字节都没动(证据不销毁)" "⑦残留:证据不销毁"
assert_contains "$OUT" "残留扫描:pid 仍存活的 running 任务不被误标" "⑦残留:活着的不误标"
assert_contains "$OUT" "残留扫描:state 为 running 但没记下 pid 的任务不被标 orphaned(没有判据就不判,不凭空断言它死了)" "⑦残留:无 pid 不猜死"
# ⑦b 本次修复的核心(两轴 CR 独立收敛到的同一条 🔴):agent 退出 → run 进程还在 drain → 另一终端扫描抢标 orphaned
#     → run 进程随后 finish。修之前这一步抛 illegalTransition:一次**成功**的任务被永久记成孤儿、报告缺失、无纠正路径。
assert_contains "$OUT" "孤儿纠正:先复现 drain 期间被扫描抢标的时序(任务此刻是 orphaned)" "⑦b孤儿:复现 drain 抢标时序"
assert_contains "$OUT" "孤儿纠正:被抢标 orphaned 后 run 进程的 finish 不再抛错(一手证据不该被推测挡住)" "⑦b孤儿:finish 不再被推测挡住"
assert_contains "$OUT" "孤儿纠正:纠正后 meta 的最终状态是 completed 而不是 orphaned(成功的任务不该被记成孤儿)" "⑦b孤儿:最终状态是 completed"
assert_contains "$OUT" "孤儿纠正:纠正后报告被补出来了(被记成孤儿的旧行为下这份报告永远缺失)" "⑦b孤儿:报告不再缺失"
assert_contains "$OUT" "孤儿纠正:orphaned 经 finish 迁到 timeout 成功落盘" "⑦b孤儿:四条出边逐条落盘(timeout 为例)"
assert_contains "$OUT" "孤儿纠正:已收好的 completed 再被标 orphaned 一律抛错(证据不可被推测覆盖)" "⑦b孤儿:反向仍非法(单向)"
# ⑦c finish 同态幂等 + 报告自愈(顺带钉死「一次 finish 只取一次现在」)
assert_contains "$OUT" "工作区:finish 同态幂等 —— 同一个终态再 finish 一次不抛(不撞终态冻结)" "⑦c幂等:同态重调不抛"
assert_contains "$OUT" "工作区:同态幂等的第二次 finish 不增加 meta.json 写入次数、内容一字未改" "⑦c幂等:第二次不写 meta"
assert_contains "$OUT" "工作区:report.html 缺失时重调同值 finish 把报告补了出来(meta 写成功但报告写失败的自愈路径)" "⑦c幂等:报告自愈"
assert_contains "$OUT" "工作区:同态幂等只认同一个终态,换成别的终态再 finish 一律抛错(终态不是可反复改写的字段)" "⑦c幂等:换终态仍被拒"
assert_contains "$OUT" "工作区:一次 finish 只取一次现在(finished_at 与报告页脚是同一个时刻,不制造两个现在)" "⑦c幂等:finish 只取一次现在"
# ⑦d error 与终态一次写盘(不留「error 已填但 state=running」的半截现场)
assert_contains "$OUT" "工作区:error 与 state 与 finished_at 与 exit_code 一次写盘(不留下 error 已填但仍是 running 的半截现场)" "⑦d收尾:error 与终态一次写盘"
assert_contains "$OUT" "工作区:成功任务的 error 为 nil 时整键省略,meta.json 不产 error 噪音键" "⑦d收尾:nil error 不产键"
# ⑧ HTML 报告(提案 §6:自产优先 + 兜底 + escape 顺序)
assert_contains "$OUT" "HTML 报告:先转 amp 再转其余 —— a and b less-than c 得到 amp 与 lt 各一次" "⑧报告:escape 先转 amp"
assert_contains "$OUT" "HTML 报告:绝不出现二次转义的 amp-lt(escape 顺序不可颠倒)" "⑧报告:无二次转义"
assert_contains "$OUT" "HTML 报告:五个危险字符逐个转义为 amp/lt/gt/quot/#39" "⑧报告:五个字符逐个转义"
assert_contains "$OUT" "HTML 报告:缺 report.html 时兜底生成,且页脚显式标注由文本兜底生成" "⑧报告:兜底生成并标注"
assert_contains "$OUT" "HTML 报告:已有 agent 自产的 report.html 时原样保留,绝不覆盖" "⑧报告:自产报告不覆盖"
# ⑧b Codex 的终态 finalText 恒为 nil(AgentTerminalStatus 与 CodexAdapter 两处文件头的承诺),04 必须退回取最后一条 text。
assert_contains "$OUT" "报告兜底:finalText 为 nil 时退回 normalized 里最后一条 text 消息(Codex 侧的唯一来源)" "⑧b兜底:退回 normalized 最后一条 text"
assert_contains "$OUT" "报告兜底:取的是最后一条 text 而不是第一条(后面的文本是对前面的收敛)" "⑧b兜底:取最后一条而非第一条"
assert_contains "$OUT" "报告兜底:只读 normalized.ndjson,绝不去 raw.ndjson 里取最终文本(提案 §2 的红线)" "⑧b兜底:只消费 normalized"
assert_contains "$OUT" "报告兜底:normalized 里一条 text 都没有时如实说没有最终文本(不硬造内容)" "⑧b兜底:没有 text 时如实说没有"
assert_contains "$OUT" "报告兜底:normalized.ndjson 读不出来时退回 nil 而不是抛错(兜底是尽力而为,不掀翻已写定的终态)" "⑧b兜底:读不出不抛错"
# ⑨ prune 永不删 running/pending(提案 §4)
assert_contains "$OUT" "prune:终态任务目录被删除" "⑨prune:终态被删"
assert_contains "$OUT" "prune:running 与 pending 哪怕被点名要删也跳过,并如实出现在 skipped" "⑨prune:活态永不删且如实报出"
assert_contains "$OUT" "prune:keepIDs 点名保留的终态任务不删" "⑨prune:点名保留生效"
# ⑩ 读侧容忍未知字段(演进规则:只增不改义、旧目录永不迁移)
assert_contains "$OUT" "读侧容忍:meta.json 多出未知键时仍能正常解出、不抛(演进规则 只增不改义)" "⑩演进:未知字段不打崩读侧"
# ⑩b 只「读得出」不算兼容:updateMeta 是读-改-写,写侧剥掉未知键就等于旧版本单方面抹掉新版本刚写下的字段。
assert_contains "$OUT" "写侧保留:updateMeta 读改写之后未知键 future_key 仍在 meta.json 里(不静默剥掉别人的字段)" "⑩b演进:写侧原样写回未知键"
assert_contains "$OUT" "写侧保留:保住未知键的同时本版本自己的字段照常更新(两件事互不牵连)" "⑩b演进:保留未知键不妨碍正常更新"

# agent-delegation 05 纯逻辑断言(同一 runner 输出;AgentWatchdogTests:消息静默看门狗 + 取消/超时中断语义)。
# 口径同 1c/1d/1e/1f:PASS/FAIL 均含描述串,故这些 assert_contains 证明「断言确已运行(路径被跑到)」;
#   零失败由上面「registry-tests 全绿退出码」(runner 任一 r*.failed>0 即 exit 1)兜底保证。
# 与 1f 一样**不依赖任何样本目录 / 环境变量**,且比 1f 更进一步:本组连假文件系统都不需要 ——
#   时间是测试直接喂进去的 epoch 秒(生产侧由 AgentClockPort 注入),进程是 FakeAgentPort。
#   **本组里若出现任何真实等待,门禁耗时会立刻暴涨** —— 看门狗默认阈值是 120/900 秒,真等一次就没法当门禁跑。
echo "--- 断言组 1g:静默看门狗 + 取消语义(AgentWatchdogTests,零真实等待/零真进程)---"
assert_contains "$OUT" "WATCHDOG_TESTS passed=" "agent-delegation 05 纯逻辑套件已运行(AgentWatchdogTests)"
# ① 默认阈值的实证依据(两处 spike 的数量级)+ 阈值可配(07 票 CLI 要能覆盖)
assert_contains "$OUT" "看门狗:默认 idle 阈值为 120 秒(覆盖 Codex exec3 实测 90 秒硬超时窗口,findings 意外发现 2 的 60-90 秒余量)" "①阈值:idle 默认 120 秒有实证依据"
assert_contains "$OUT" "看门狗:默认工具在途阈值为 900 秒(长跑工具 + Claude api_retry 指数退避都不误杀)" "①阈值:工具在途默认 900 秒有实证依据"
assert_contains "$OUT" "看门狗:自定义阈值原样生效(阈值可配,默认值不是写死的)" "①阈值:可配(票面明写,07 票 CLI 覆盖)"
# ①b 票面第 1 条明写「以 ClockPort 驱动」:补一条端到端经 AgentClockPort/FakeClock 的,证明生产接线形状成立。
assert_contains "$OUT" "看门狗:整条判决链路的时间全部取自 AgentClockPort(经 FakeClock 喂,零真实时钟、零真实等待)" "①b时钟:判决链路的时间来自 ClockPort(票面第 1 条)"
assert_contains "$OUT" "看门狗:时钟端口恰被取用三次(拉起/观察/判决各一次,看门狗自己一个字都不读系统时钟)" "①b时钟:看门狗自己绝不读系统时钟"
# ② 静默超时触发 + 边界严格大于(边界松一秒就是误杀)
assert_contains "$OUT" "看门狗:静默 119 秒(差 1 秒到阈值)仍判 healthy(边界不能松)" "②静默:差 1 秒仍 healthy"
assert_contains "$OUT" "看门狗:静默恰好等于阈值 120 秒仍判 healthy(判据是严格大于,边界上少杀一秒没人受伤)" "②静默:恰好等于阈值仍 healthy(严格大于)"
assert_contains "$OUT" "看门狗:静默 121 秒超过 idle 阈值判 stalled(silentSeconds=121、toolInFlight=false,诊断信息不丢)" "②静默:超阈判 stalled 且带诊断信息"
assert_contains "$OUT" "看门狗:最后活动时刻的初值是拉起时刻(拉起后一条消息都不吐同样会被判卡死)" "②静默:起算点是拉起时刻"
# ③ 工具在途放宽不误杀(票面第 2 条:须容忍 Codex 40+s 网络重连)
assert_contains "$OUT" "看门狗:有未闭合工具时生效阈值放宽到 900 秒(idle 档 120 秒不再适用)" "③在途:阈值放宽到在途档"
assert_contains "$OUT" "看门狗:工具在途静默 45 秒仍判 healthy(Codex 两级传输各 5 次重连实测 40+ 秒,不误杀)" "③在途:Codex 40+ 秒重连不误杀(票面第 2 条)"
assert_contains "$OUT" "看门狗:工具在途静默 901 秒判 stalled(toolInFlight=true,卡死时有工具在途这条现场信息保住了)" "③在途:超放宽档仍判 stalled 且现场信息不丢"
# ④ 放宽必须是**动态**的:工具一闭合就退回 idle 档,不是一旦有过工具就永久放宽(那等于把看门狗关掉)
assert_contains "$OUT" "看门狗:工具闭合后阈值退回 idle 档 120 秒(放宽是动态的,不是一旦有过工具就永久放宽)" "④收回:阈值动态退回 idle 档"
assert_contains "$OUT" "看门狗:工具闭合后静默 121 秒即判 stalled(闭合前同样的 121 秒还是 healthy)" "④收回:同样 121 秒闭合前后判决相反"
assert_contains "$OUT" "看门狗:两个工具在途时闭合其一仍剩 1 个未闭合,阈值保持在途档(不提前收回预算)" "④收回:并发工具闭合其一不提前收回"
# ⑤ 畸形消息(agent 的流本来就可能被截断,一条脏数据不该让在途状态错乱)
assert_contains "$OUT" "看门狗:callID 为 nil 的畸形 tool-use 不进在途集合(空 id 会让所有畸形调用互相顶掉)" "⑤畸形:nil callID 的 tool-use 不进集合"
assert_contains "$OUT" "看门狗:没配上的 tool-result 被忽略,在途计数不减到负数(agent 流可能被截断)" "⑤畸形:孤儿 tool-result 不减到负数"
assert_contains "$OUT" "看门狗:error 型重连心跳刷新最后活动时刻(还在重试不是卡死,02 spike 建议 4)" "⑤心跳:Reconnecting 事件算存活判据"
assert_contains "$OUT" "看门狗:墙钟回拨时静默时长钳到 0 而不是负数(NTP 回拨不误杀)" "⑤回拨:静默时长钳到 0"
# ⑥ 取消:迁移 + 终止调用(票面第 3 条,经 Fake Port 断言收到终止调用)
assert_contains "$OUT" "取消:running 任务被取消后状态迁到 cancelled" "⑥取消:running → cancelled"
assert_contains "$OUT" "取消:终止意图确实发给了那个句柄(FakeAgentPort.terminateCalls 恰记到这一次)" "⑥取消:终止调用被 Fake Port 记到(票面第 3 条)"
# ⑥b 最要害的一条:对非 running 取消必须抛错,且**绝不**已经把进程杀了
assert_contains "$OUT" "取消:pending 与五个终态共六个非 running 状态逐个取消全部抛错(只有 running 可取消)" "⑥b非法取消:六个非 running 状态全抛错"
assert_contains "$OUT" "取消:非 running 取消抛错时 terminateCalls 保持为空(绝不既报错又已经把进程杀了)" "⑥b非法取消:抛错时绝不已经杀进程"
# ⑦ 看门狗判卡死 → 迁 timeout + 终止(票面第 1 条的完整链路;落点是 timeout 而非 cancelled)
assert_contains "$OUT" "超时终止:看门狗判 stalled 后任务状态迁到 timeout(不是 cancelled —— 平台判的与用户点的要分得清)" "⑦超时链路:判卡死 → 迁 timeout"
assert_contains "$OUT" "超时终止:判卡死后终止意图确实发给了那个句柄,并交回该 vendor 的 drain 姿态" "⑦超时链路:触发终止 + 交回 drain 姿态"
assert_contains "$OUT" "超时终止:对非 running 任务判超时同样抛错且 terminateCalls 保持为空" "⑦超时链路:非 running 同样不许杀"
# ⑧ 两家中断差异收敛为域逻辑(票面第 4 条:此差异在状态机/drain 逻辑层显式处理)
assert_contains "$OUT" "中断收敛:Claude 侧姿态是 drainToEOF(01 spike:信号后先补 Request interrupted 再落 aborted_streaming 终态,弃管道就丢终态)" "⑧收敛:Claude → drain 读到底(01 spike)"
assert_contains "$OUT" "中断收敛:Codex 侧姿态是 markAbortedAtSignal(02 spike exec5:被 SIGTERM 杀时流里根本没有终态行,再读也读不出)" "⑧收敛:Codex → 发信号那刻自标 aborted(02 spike)"
assert_contains "$OUT" "中断收敛:两家 drain 姿态互不相等(不对称是实证结论,不是可以抹平的实现细节)" "⑧收敛:不对称是实证结论"
# ⑨ 终态收敛顺序(复用 04 的 resolve,不写第二个)+ timeout 合流点
assert_contains "$OUT" "终态收敛:terminal 优先于取消记账 —— 信号落地前正好正常完成时报 completed(不丢一份有效结果)" "⑨顺序:terminal 优先于取消记账"
assert_contains "$OUT" "终态收敛:Codex 中断现场(terminal 为 nil + 退出码 -15 + 有取消记账)判 cancelled" "⑨顺序:Codex 中断现场判 cancelled"
assert_contains "$OUT" "超时合流:timedOut 与 cancelRequested 同时为真判 timeout(顺序不可颠倒 —— 平台判的卡死不能记成用户取消)" "⑨合流:timeout 压过 cancel(顺序不可颠倒)"
assert_contains "$OUT" "超时合流:Claude 读到底拿回的 aborted 只是我们那一刀的回声,timedOut 时仍判 timeout 而不是 cancelled" "⑨合流:aborted 回声不覆盖 timeout"
assert_contains "$OUT" "超时合流:竞态里 agent 已交出成功终态时报 completed 而不是 timeout(不丢有效产出,与 04 的 terminal 优先同款理由)" "⑨合流:成功产出不被 timeout 丢掉"
assert_contains "$OUT" "超时合流:timedOut 的豁免集恰为 {succeeded} —— failed / aborted 一律仍判 timeout(防豁免集被悄悄放大)" "⑨合流:豁免集恰为 {succeeded}(防被悄悄放大)"
assert_contains "$OUT" "超时合流:timedOut 为假时 32 组输入与 AgentTaskState.resolve 逐值相同(薄壳不产生第二套判定)" "⑨合流:薄壳不产生第二个 resolve"
assert_contains "$OUT" "超时合流:全部输入组合(含 timedOut 为真)都收敛到终态,绝无把任务挂在 running 的路径" "⑨合流:绝不把任务挂在 running"

# --- 断言组 2:list 纵切 E2E(aa capabilities list ⇄ 宿主 UDS)---
echo "--- 断言组 2:list E2E(起真宿主)---"
# 先清场:确保无旧宿主 / 旧 socket(与 trap 双保险)
pkill -f "$KILLPAT" 2>/dev/null
sleep 1
rm -f "$SOCK"

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

# poll 等 socket 出现(上限 20s,别死等);若宿主中途退出即报错
SOCK_UP=0
for _ in $(seq 1 100); do
  [ -S "$SOCK" ] && { SOCK_UP=1; break; }
  kill -0 "$HOST_PID" 2>/dev/null || break
  sleep 0.2
done

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

# 清场:杀宿主 + 删 socket(trap 亦会兜底)
pkill -f "$KILLPAT" 2>/dev/null
sleep 1
rm -f "$SOCK"

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
start_host_confirm() {
  local mode="$1"
  pkill -f "$KILLPAT" 2>/dev/null
  sleep 1
  rm -f "$SOCK"
  AA_CONFIRM_AUTO="$mode" "$HOST_BIN" > "$HOSTLOG" 2>&1 &
  HOST_PID=$!
  disown "$HOST_PID" 2>/dev/null || true
  SOCK_UP=0
  for _ in $(seq 1 100); do
    [ -S "$SOCK" ] && { SOCK_UP=1; break; }
    kill -0 "$HOST_PID" 2>/dev/null || break
    sleep 0.2
  done
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

# 清场:杀宿主 + 删 socket(trap 亦兜底)
pkill -f "$KILLPAT" 2>/dev/null
pkill -f "raw_uds_client.py" 2>/dev/null
sleep 1
rm -f "$SOCK"

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
sleep 1
rm -f "$SOCK"

# --- 断言组 P:proxy.status 内核生命周期 E2E(06 票主体:真子进程 fake mihomo stub + 真 localhost REST)---
echo "--- 断言组 P:proxy.status 内核生命周期 E2E(06 票)---"
chmod +x "$STUB" 2>/dev/null
# 由 OS 分配一个空闲高位端口(避开常用端口 / 撞端口),交给内核 stub 监听、RESTClient 连接。
MIHOMO_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null)"
[ -z "$MIHOMO_PORT" ] && MIHOMO_PORT=48123
echo "    fake mihomo 控制端口 = $MIHOMO_PORT"

# 起宿主并注入内核 env:AA_MIHOMO_KERNEL_PATH → stub;AA_MIHOMO_CONTROL_PORT → 空闲端口。置全局 HOST_PID/SOCK_UP。
start_host_kernel() {
  pkill -f "$KILLPAT" 2>/dev/null
  pkill -f "$KILLPAT_STUB" 2>/dev/null
  sleep 1
  rm -f "$SOCK"
  AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT" "$HOST_BIN" > "$HOSTLOG" 2>&1 &
  HOST_PID=$!
  disown "$HOST_PID" 2>/dev/null || true
  SOCK_UP=0
  for _ in $(seq 1 100); do
    [ -S "$SOCK" ] && { SOCK_UP=1; break; }
    kill -0 "$HOST_PID" 2>/dev/null || break
    sleep 0.2
  done
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

# 清场:杀宿主 + stub(trap 亦兜底)
pkill -f "$KILLPAT" 2>/dev/null
pkill -f "$KILLPAT_STUB" 2>/dev/null
sleep 1
rm -f "$SOCK"

# —— 场景 C:SIGTERM-忽略型内核经 terminate 仍被 SIGKILL 兜底回收(暴露"发完 SIGTERM 立刻 unrecord"的孤儿洞)——
# 内核以 --ignore-sigterm 运行(装 handler 吞掉 SIGTERM);宿主收 SIGUSR1 → 优雅退出 → reclaimKernel →
# ProcessPort.terminate:SIGTERM 被忽略 → 有界等待后 SIGKILL 兜底 → 内核被回收。旧 bug(发完 SIGTERM 立刻 unrecord)
# 会让该内核既不被 terminate 的 SIGKILL 兜到(未升级)、又从缓冲摘除(退出钩子够不着)→ 孤儿。修后必被回收、无孤儿。
echo "--- 断言组 P-C:SIGTERM-忽略型内核的 terminate SIGKILL 兜底 ---"
pkill -f "$KILLPAT" 2>/dev/null; pkill -f "$KILLPAT_STUB" 2>/dev/null; sleep 1; rm -f "$SOCK"
AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT" AA_MIHOMO_KERNEL_EXTRA_ARGS="--ignore-sigterm" \
  "$HOST_BIN" > "$HOSTLOG" 2>&1 &
HOST_PID=$!
disown "$HOST_PID" 2>/dev/null || true
SOCK_UP=0
for _ in $(seq 1 100); do
  [ -S "$SOCK" ] && { SOCK_UP=1; break; }
  kill -0 "$HOST_PID" 2>/dev/null || break
  sleep 0.2
done
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

# 清场:杀宿主 + stub(trap 亦兜底)
pkill -f "$KILLPAT" 2>/dev/null
pkill -f "$KILLPAT_STUB" 2>/dev/null
sleep 1
rm -f "$SOCK"

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

# (3d) agent-delegation 01 铁律:AAAgentCore 不 import 任何 Host* / AAPluginSDK / PluginProxy
#      (与 PluginProxy 同级把关,照 3a 的 grep 模式)。
#      **红线的全文就是 `AgentTaskPorts.swift` / `AgentPort.swift` 注释里那句「绝不 AAPluginSDK/PluginProxy」** ——
#      故正则在 3a 的 Host* 之外一并覆盖 AAPluginSDK 与 PluginProxy:注释宣称门禁把关,门禁就得真把这两个也拦住,
#      否则那句注释是空头支票(修 grep 而不是弱化注释)。
#      显式判 grep 退出码:rc==1 无匹配(好)/ rc==0 命中禁止 import(坏)/ rc>=2 grep 自身出错(绝不算过)。
AC_GREP_HITS="$(grep -REn 'import[[:space:]]+([a-z]+[[:space:]]+)?(AAHost(Runtime|MacOS|TestKit)|AAPluginSDK|PluginProxy)' Sources/AAAgentCore/)"
AC_GREP_RC=$?
if [ "$AC_GREP_RC" -eq 1 ]; then
  echo "PASS: AAAgentCore 源码不含 import Host*/AAPluginSDK/PluginProxy(AAHostRuntime|AAHostMacOS|AAHostTestKit|AAPluginSDK|PluginProxy)"; PASS=$((PASS+1))
elif [ "$AC_GREP_RC" -eq 0 ]; then
  echo "FAIL: AAAgentCore 源码出现被禁的 import(Host*/AAPluginSDK/PluginProxy):"; printf '%s\n' "$AC_GREP_HITS"; FAIL=$((FAIL+1))
else
  echo "FAIL: grep 守卫自身出错(rc=$AC_GREP_RC),无法核验 AAAgentCore 边界 —— 绝不算过"; FAIL=$((FAIL+1))
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
