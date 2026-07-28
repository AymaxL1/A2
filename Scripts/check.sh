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

SWIFTC_COMMON=(-swift-version 5 -vfsoverlay "$OVERLAY" -module-cache-path "$MCACHE")

# 超时 E2E 用的「只 accept 不回应」假监听器脚本(python3,绑定同一 socket 路径);清场按此模式兜底。
TIMEOUT_LISTENER="$BUILD/timeout_listener.py"

# 失败/成功任一路径都清场,杜绝僵尸宿主 / 残 socket / 残假监听器。
cleanup() {
  pkill -f "$KILLPAT" 2>/dev/null
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

# ② 只依赖 Contracts
build_lib AAPluginSDK
build_lib AAHostRuntime   # 含 Registry(纯逻辑)
build_lib AAUISystem

# ③ 假件(库)+ 宿主(库,但门禁单独把它编成可执行做冒烟;@main 是过桥,终态是 12 票 XcodeGen app 壳)
build_lib AAHostTestKit
echo "-- 编译可执行 target: AAHostMacOS(库→冒烟可执行;AppKit,首次编译约 30s)"
swiftc "${SWIFTC_COMMON[@]}" \
  -parse-as-library \
  -I "$MODULES" \
  -o "$HOST_BIN" \
  "$OBJ/AAContracts.o" "$OBJ/AAHostRuntime.o" \
  Sources/AAHostMacOS/*.swift \
  || { echo "FAIL: 编译 AAHostMacOS 失败"; exit 1; }

# ③ PluginProxy —— 受限搜索路径:只放 SDK/Contracts/UISystem,故意不放任何 Host* 模块。
#    若它能在这条受限 -I 下编过,即从编译期证明「PluginProxy 不需要 Host*」(01 票铁律)。
echo "-- 编译库 target: PluginProxy(受限 -I:仅 SDK/Contracts/UISystem,无 Host*)"
cp "$MODULES/AAContracts.swiftmodule" "$MODULES/AAPluginSDK.swiftmodule" "$MODULES/AAUISystem.swiftmodule" "$PPMODS/" \
  || { echo "FAIL: 准备 PluginProxy 受限模块目录失败"; exit 1; }
swiftc "${SWIFTC_COMMON[@]}" \
  -emit-module -emit-module-path "$MODULES/PluginProxy.swiftmodule" \
  -module-name PluginProxy \
  -I "$PPMODS" \
  Sources/PluginProxy/*.swift \
  || { echo "FAIL: 编译 PluginProxy(受限 -I)失败 —— 它可能意外依赖了 Host* 或其它未提供模块"; exit 1; }

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
// 门禁自动生成:Registry 纯逻辑测试的入口 shim(断言逻辑在 AAHostTestKit)。
import AAHostTestKit
import Foundation
let report = RegistryConformanceTests.run()
for line in report.lines { print(line) }
print("REGISTRY_TESTS passed=\(report.passed) failed=\(report.failed)")
fflush(stdout)
exit(report.failed == 0 ? 0 : 1)
SWIFT
swiftc "${SWIFTC_COMMON[@]}" \
  -I "$MODULES" \
  -o "$TESTRUNNER" \
  "$OBJ/AAContracts.o" "$OBJ/AAHostRuntime.o" "$OBJ/AAHostTestKit.o" \
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
OUT="$("$TESTRUNNER" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/    /'
assert_exit 0 $RC "registry-tests 全绿退出码"
assert_contains "$OUT" "demo.echo" "纯逻辑测试覆盖 demo.echo"
# 04 票安全核三分支(纯逻辑,假件驱动,不起宿主):
assert_contains "$OUT" "假 confirm=true 时 handler 恰执行一次" "纯逻辑:dangerous+confirm=true → 执行 handler"
assert_contains "$OUT" "假 confirm=false → denied" "纯逻辑:dangerous+confirm=false → denied"
assert_contains "$OUT" "handler 绝不执行(fail-closed 保底)" "纯逻辑:confirm=nil → fail-closed 绝不执行(安全保底)"
assert_contains "$OUT" "failed=0" "纯逻辑测试无失败项"

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
