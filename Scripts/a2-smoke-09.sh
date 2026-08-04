#!/bin/bash
# 09 票 —— Swift 客户端 × 真 a2 内核的活体烟测(**门禁之外**的独立脚本)。
#
# 为什么不在 `Scripts/check/` 下、也不进 `swift test`:
#   09 票是 expand 半步 —— **`check.sh` 的行为一行不改**。把"起一个真 a2 daemon"塞进门禁,
#   既改了门禁的行为,又给它加了一条 bun/内核产物的依赖。门禁跑的是 Swift 侧的静态对照
#   (金标 + 协议逻辑),活体这一关由本脚本按需跑,结果写进票面与 nightlog。
#
# 它证明什么:手写镜像 + UDS 客户端对着**真内核**跑得通一整条确认链 ——
#   连接 → 注册 confirm-agent(同一次往返拿全量快照)→ 触发真 dangerous 调用 →
#   收 confirmation 推送 → 回 approve/deny → 发起方拿到对应收场(0 / 2)。
#
# 红线(逐条落实在下面):
#   * 一切落在临时 A2_HOME(`/tmp/a2sm-*`),真实 `~/.a2` 绝不出现;
#   * daemon 用完杀净(trap 兜底,只杀本次起的那个 pid);
#   * **绝不碰用户自己的 mihomo**:扫描面、控制端口、入站端口全部注入到沙盒值,
#     PATH 只有假 supervisor,`A2_NETWORKSETUP` 指向"一执行就大声失败"的假件;
#   * 不 launchctl 任何真 unit(HOME 也被换成临时目录,`~/Library/LaunchAgents` 是空的)。
#
# 用法:
#   bash Scripts/a2-smoke-09.sh            # 用 kernel/dist/a2(没有就回落到 bun 跑源码入口)
#   A2_BIN=/path/to/a2 bash Scripts/a2-smoke-09.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
note() { echo "  $*"; }
ok()   { echo "PASS: $*"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

# ---- ① Swift 工具链(与 Scripts/check/bootstrap.sh 同一套候选顺序与判据)----------------
SWIFT_BIN=""
for cand in "${AA_SWIFT:-}" "$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift" swift; do
  [ -z "$cand" ] && continue
  if ! command -v "$cand" >/dev/null 2>&1 && [ ! -x "$cand" ]; then continue; fi
  if "$cand" package dump-package --scratch-path "$ROOT/.build/a2-smoke-probe" >/dev/null 2>&1; then
    SWIFT_BIN="$cand"; break
  fi
done
if [ -z "$SWIFT_BIN" ]; then
  echo "FAIL: 找不到 SPM 可用的 swift(判据同 bootstrap.sh:swift package dump-package rc=0)"
  exit 1
fi

# ---- ② a2 内核的可执行形态 ------------------------------------------------------------
# 优先级:A2_BIN > kernel/dist/a2(bun compile 的单文件产物)> bun 跑源码入口。
# **本脚本绝不构建 kernel/**(那会写 kernel/dist,而 kernel/ 归别的票施工)——产物不在就走源码入口。
# `A2_SOURCE=1` 强制走源码入口 —— 当 `kernel/dist/a2` 可能比 `kernel/src/` 旧时(内核那侧刚提交、
#   还没重新 compile),用它才验得到**当下的**契约。
A2_CMD=()
if [ -n "${A2_BIN:-}" ]; then
  A2_CMD=("$A2_BIN")
elif [ -x "$ROOT/kernel/dist/a2" ] && [ -z "${A2_SOURCE:-}" ]; then
  A2_CMD=("$ROOT/kernel/dist/a2")
else
  BUN_BIN="$(command -v bun 2>/dev/null)"
  [ -z "$BUN_BIN" ] && [ -x "$HOME/.bun/bin/bun" ] && BUN_BIN="$HOME/.bun/bin/bun"
  if [ -z "$BUN_BIN" ]; then
    echo "FAIL: 既没有 kernel/dist/a2,也找不到 bun —— 无法起真内核"
    echo "      修法:在 kernel/ 下跑 \`bun run build\` 出单文件产物,或把 bun 放进 PATH"
    exit 1
  fi
  A2_CMD=("$BUN_BIN" run "$ROOT/kernel/src/cli/main.ts")
fi
echo "a2 = ${A2_CMD[*]}"

# ---- ③ 沙盒(每一处能碰到真机的地方都注入假件;口径抄 kernel/test/support/proxy-sandbox.ts)----
BOX="$(mktemp -d /tmp/a2sm-XXXXXX)"
A2HOME="$BOX/a2home"
FAKE_SUPERVISOR="$ROOT/kernel/test/support/fake-supervisor"
FORBIDDEN_NETSETUP="$ROOT/kernel/test/support/fake-networksetup/networksetup-forbidden"
mkdir -p "$A2HOME" "$BOX/emptybin" "$BOX/xdg" "$BOX/state"
SOCK="$A2HOME/run/kernel.sock"
DAEMON_PID=""

# 控制端口/入站端口取空闲值 —— **绝不用默认值**,免得撞上用户自己那份 mihomo。
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
CTRL_PORT="$(free_port)"
MIXED_PORT="$(free_port)"

cleanup() {
  if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$DAEMON_PID" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$DAEMON_PID" 2>/dev/null
  fi
  rm -rf "$BOX" 2>/dev/null
}
trap cleanup EXIT

# ---- ④ 构建烟测驱动 --------------------------------------------------------------------
# `--product` 而不是 `--target`:后者只编模块、**不链接可执行**(可执行是产物层的事)。
#   本 target 刻意没在 `products` 里露面(门禁内部工具),但 SPM 会给 executableTarget
#   自动建一个同名隐式产物 —— 按名字要它即可,不必为了跑一次烟测把整棵 AA* 树也编一遍。
echo "-- swift build a2-smoke"
"$SWIFT_BIN" build --scratch-path "$ROOT/.build/a2-smoke" --product a2-smoke >"$BOX/build.log" 2>&1
if [ $? -ne 0 ]; then
  echo "FAIL: a2-smoke 构建失败,日志:$BOX/build.log"; tail -20 "$BOX/build.log"; exit 1
fi
SMOKE_BIN="$("$SWIFT_BIN" build --scratch-path "$ROOT/.build/a2-smoke" --show-bin-path 2>/dev/null)/a2-smoke"
[ -x "$SMOKE_BIN" ] || { echo "FAIL: 取不到 a2-smoke 可执行($SMOKE_BIN)"; exit 1; }

# ---- ⑤ 起真 daemon(前台模式,后台跑,pid 归本脚本)-------------------------------------
echo "-- a2 daemon run(临时 A2_HOME=$A2HOME)"
env -i \
  PATH="$FAKE_SUPERVISOR" \
  HOME="$BOX" \
  XDG_CONFIG_HOME="$BOX/xdg" \
  A2_HOME="$A2HOME" \
  A2_NETWORKSETUP="$FORBIDDEN_NETSETUP" \
  A2_MIHOMO_BIN_DIRS="$BOX/emptybin" \
  A2_MIHOMO_CONFIG_FILES="$BOX/emptybin/config.yaml" \
  A2_MIHOMO_CONTROLLER_PORT="$CTRL_PORT" \
  A2_MIHOMO_MIXED_PORT="$MIXED_PORT" \
  A2_PROXY_WATCH_INTERVAL_MS="500" \
  A2_FAKE_STATE_DIR="$BOX/state" \
  A2_FAKE_LOG="$BOX/supervisor.log" \
  "${A2_CMD[@]}" daemon run >"$BOX/daemon.log" 2>&1 &
DAEMON_PID=$!

for _ in $(seq 1 100); do
  [ -S "$SOCK" ] && break
  sleep 0.1
done
if [ ! -S "$SOCK" ]; then
  echo "FAIL: daemon 没在 10 秒内把 socket 建起来($SOCK)"; tail -20 "$BOX/daemon.log"; exit 1
fi
note "daemon pid=$DAEMON_PID socket=$SOCK"

# ---- ⑥ 两条链:批准放行 / 拒绝挡住 ------------------------------------------------------
run_case() {
  local decision="$1" expect="$2"
  echo "-- 场景:确认器 $decision"
  # **沙盒环境要一并喂给 a2-smoke**:它会 fork 出那条真 CLI 调用,而子进程继承的是它的环境 ——
  #   不喂 `A2_HOME`,那条 `a2 capabilities call` 就会去连真实 `~/.a2`(连不上,退出码 4),
  #   而烟测会表现成"没等到确认推送",查半天发现是环境没传下去。
  env \
    PATH="$FAKE_SUPERVISOR" \
    HOME="$BOX" \
    XDG_CONFIG_HOME="$BOX/xdg" \
    A2_HOME="$A2HOME" \
    A2_NETWORKSETUP="$FORBIDDEN_NETSETUP" \
    A2_MIHOMO_BIN_DIRS="$BOX/emptybin" \
    A2_MIHOMO_CONFIG_FILES="$BOX/emptybin/config.yaml" \
    A2_MIHOMO_CONTROLLER_PORT="$CTRL_PORT" \
    A2_MIHOMO_MIXED_PORT="$MIXED_PORT" \
    "$SMOKE_BIN" --socket "$SOCK" --capability demo.wipe --decision "$decision" --timeout 20 \
    -- "${A2_CMD[@]}" 2>&1 | sed 's/^/    /'
  local rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    ok "Swift 客户端全链跑通($decision → 发起方收 $expect)"
  else
    bad "Swift 客户端全链失败($decision,rc=$rc)"
  fi
}

run_case approve "退出码 0"
run_case deny "退出码 2(confirmation_denied + 指引)"

# ---- ⑦ 红线自查 ------------------------------------------------------------------------
echo "-- 红线自查"
if [ -e "$HOME/.a2" ]; then
  bad "真实 ~/.a2 出现了 —— 本脚本只该往临时目录写"
else
  ok "真实 ~/.a2 仍不存在"
fi
if grep -q "33888" "$BOX/daemon.log" 2>/dev/null; then
  bad "daemon 日志里出现了 33888(用户 mihomo 的端口)"
else
  ok "daemon 日志里没有 33888(没碰用户的 mihomo)"
fi

echo
echo "========== a2-smoke-09 ==========="
echo " PASS=$PASS FAIL=$FAIL"
echo " daemon 日志:$BOX/daemon.log(随本脚本退出一并清掉)"
echo "=================================="
[ "$FAIL" -eq 0 ] || exit 1
