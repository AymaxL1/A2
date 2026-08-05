#!/bin/bash
# 旗舰场景端到端验收(10 票重写版)——**真 `a2` bin + 假 mihomo + 真菜单栏壳代码路径**。
#
# ============================================================================
# 它取代了什么
# ============================================================================
# 旧的 `Scripts/check/flagship-e2e.sh` 押在「一个 GUI 宿主实例 + 薄客户端 `aa`」这个拓扑上,
#   而那个拓扑本身正在被替换(路线图:原判据「agent-first 旗舰场景通过」作废)。
#   **验收精神继承下来**:全程只经 CLI、零 GUI 打断、dangerous 必经确认。
# 本脚本同时接手 09 票 `Scripts/a2-smoke-09.sh` 的活体确认链(那个脚本随本票退役)——
#   区别是这次跑在门禁里,而且被测体是**壳自己的代码**(`a2-panel-probe` 复用 A2Panel 全套)。
#
# ============================================================================
# 六幕
# ============================================================================
#   ① 旗舰链零打断:开代理 → 切模式 → 选节点 → 激活/更新订阅,全程 safe/normal,**一次确认都不弹**;
#      壳的菜单**逐幕跟着变**(零轮询:壳在这期间没有为了"看看变了没有"发过一条请求);
#   ② dangerous 换源 · 批准:确认器收到**原样的 input** → 批准 → 退出码 0 → 订阅真的进了清单;
#   ③ dangerous 换源 · 拒绝:同一条能力 → 拒绝 → 退出码 2 `confirmation_denied` → 清单没变;
#   ④ 壳缺席:确认器断连 → 下一条 dangerous 立刻回到第①层 `confirmation_unavailable`(退出码 2),
#      而**代理照跑**(mihomo pid 不变、`proxy status` 照答话),事件在内核侧入审计日志、CLI 可查;
#   ⑤ 壳与内核的能力面对账:菜单覆盖 04 票 In 清单、每项落到**真内核登记过**的能力、
#      真内核里每条可发起的 proxy 能力要么进菜单要么在豁免表里记账;
#   ⑥ 收场:显式 `a2 proxy off` 精确还原系统代理(「退出即还原」废除后唯一的还原入口)。
#
# ============================================================================
# 红线(逐条落实在下面)
# ============================================================================
#   * **绝不碰用户自己的 mihomo**:扫描面/控制端口/入站端口全部注入沙盒值,
#     `mihomo` 一律是 `kernel/test/support/fake-mihomo`(假件),`33888` 在本文件里零出现;
#   * 一切落在临时 `A2_HOME`(`/tmp/a2fs-*`),真实 `~/.a2` 绝不出现;
#   * 不 launchctl 任何真 unit(`PATH` 只有假 supervisor,`HOME` 也换成临时目录);
#   * `networksetup` 走 `A2_NETWORKSETUP` 覆写到假件,真系统代理一个字节都不动;
#   * 起的真 daemon 与假 mihomo 用完杀净(trap 兜底,只杀本次沙盒路径下的进程)。
#
# 用法:
#   bash Scripts/a2-flagship-e2e.sh              # 用 kernel/dist/a2,没有就回落 bun 跑源码入口
#   A2_BIN=/path/to/a2 bash Scripts/a2-flagship-e2e.sh
#   A2_SOURCE=1 bash Scripts/a2-flagship-e2e.sh  # 强制走源码入口(产物可能比源码旧时)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
note(){ echo "  $*"; }

assert_eq() {  # $1=实际 $2=期望 $3=描述
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3(期望 '$2',实际 '$1')"; fi
}
assert_contains() {  # $1=文本 $2=子串 $3=描述
  case "$1" in *"$2"*) ok "$3" ;; *) bad "$3(找不到 '$2')" ;; esac
}
assert_not_contains() {  # $1=文本 $2=子串 $3=描述
  case "$1" in *"$2"*) bad "$3(不该出现 '$2')" ;; *) ok "$3" ;; esac
}

# ---- ① 工具链 -------------------------------------------------------------------------
SWIFT_BIN=""
for cand in "${AA_SWIFT:-}" "$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift" swift; do
  [ -z "$cand" ] && continue
  if ! command -v "$cand" >/dev/null 2>&1 && [ ! -x "$cand" ]; then continue; fi
  if "$cand" package dump-package --scratch-path "$ROOT/.build/flagship-probe" >/dev/null 2>&1; then
    SWIFT_BIN="$cand"; break
  fi
done
[ -n "$SWIFT_BIN" ] || { echo "FAIL: 找不到 SPM 可用的 swift(判据同 check.sh)"; exit 1; }

BUN_BIN="$(command -v bun 2>/dev/null)"
[ -z "$BUN_BIN" ] && [ -x "$HOME/.bun/bin/bun" ] && BUN_BIN="$HOME/.bun/bin/bun"
[ -n "$BUN_BIN" ] || { echo "FAIL: 找不到 bun —— 假 mihomo 是 TS 写的,没有它跑不了"; exit 1; }

# a2 的可执行形态:A2_BIN > kernel/dist/a2 > bun 跑源码入口。
A2_CMD=()
if [ -n "${A2_BIN:-}" ]; then A2_CMD=("$A2_BIN")
elif [ -x "$ROOT/kernel/dist/a2" ] && [ -z "${A2_SOURCE:-}" ]; then A2_CMD=("$ROOT/kernel/dist/a2")
else A2_CMD=("$BUN_BIN" run "$ROOT/kernel/src/cli/main.ts"); fi

echo "==== 旗舰 e2e(10 票重写版)===="
echo " a2    = ${A2_CMD[*]}"
echo " swift = $SWIFT_BIN"

# ---- ② 构建壳的无头替身 ----------------------------------------------------------------
# `--product` 而不是 `--target`:后者只编模块、不链接可执行。
"$SWIFT_BIN" build --scratch-path "$ROOT/.build/flagship" --product a2-panel-probe \
  >"$ROOT/.build/flagship-build.log" 2>&1
if [ $? -ne 0 ]; then
  echo "FAIL: a2-panel-probe 构建失败,日志尾部:"; tail -20 "$ROOT/.build/flagship-build.log"; exit 1
fi
PROBE_BIN="$("$SWIFT_BIN" build --scratch-path "$ROOT/.build/flagship" --show-bin-path 2>/dev/null)/a2-panel-probe"
[ -x "$PROBE_BIN" ] || { echo "FAIL: 取不到 a2-panel-probe($PROBE_BIN)"; exit 1; }

# ---- ③ 沙盒(口径抄 kernel/test/support/proxy-sandbox.ts)-------------------------------
BOX="$(mktemp -d /tmp/a2fs-XXXXXX)"
A2HOME="$BOX/a2home"
SUPPORT="$ROOT/kernel/test/support"
FAKE_SUPERVISOR="$SUPPORT/fake-supervisor"
FAKE_MIHOMO_SH="$SUPPORT/fake-mihomo/mihomo"
FAKE_MIHOMO_TS="$SUPPORT/fake-mihomo/fake-mihomo.ts"
FAKE_NETSETUP_SH="$SUPPORT/fake-networksetup/networksetup"
FAKE_NETSETUP_TS="$SUPPORT/fake-networksetup/fake-networksetup.ts"
mkdir -p "$A2HOME" "$BOX/foreignbin" "$BOX/foreignconf" "$BOX/xdg" "$BOX/state" "$BOX/subs"
SOCK="$A2HOME/run/kernel.sock"
DAEMON_PID=""
PROBE_PID=""

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
CTRL_PORT="$(free_port)"
MIXED_PORT="$(free_port)"

# 假 networksetup 的初始状态,**逐字沿用旧门禁那份 fixture**:Wi-Fi 全关;
#   Ethernet 原本就有第三方代理 203.0.113.9:8080 —— 「还原 = 精确复原,不是一律关闭」全靠它才证得出来。
cat > "$BOX/netfake-state.json" <<'JSON'
{
  "services": [
    { "service": "Wi-Fi",
      "http": { "enabled": false, "host": "", "port": 0 },
      "https": { "enabled": false, "host": "", "port": 0 },
      "socks": { "enabled": false, "host": "", "port": 0 } },
    { "service": "Ethernet",
      "http": { "enabled": true, "host": "203.0.113.9", "port": 8080 },
      "https": { "enabled": true, "host": "203.0.113.9", "port": 8080 },
      "socks": { "enabled": false, "host": "", "port": 0 } }
  ]
}
JSON
cp "$BOX/netfake-state.json" "$BOX/netfake-before.json"
: > "$BOX/netfake-calls.log"
: > "$BOX/supervisor-calls.log"

# 假 mihomo 进"别人的 bin 目录"→ `a2 mihomo install` 走**复用档**(落点是符号链接,真身零改动)。
cp "$FAKE_MIHOMO_SH" "$BOX/foreignbin/mihomo"
chmod 755 "$BOX/foreignbin/mihomo"

# 订阅源:**回环文件源**(file://),不出网。正文里的 `# fake-groups:` 决定假 mihomo 重载后的分组。
cat > "$BOX/subs/airline-a.yaml" <<'YAML'
# fake-groups: PROXY=A1,A2;GLOBAL=PROXY,DIRECT
# fake-delays: A1=120;A2=300
proxies: []
YAML
cat > "$BOX/subs/airline-b.yaml" <<'YAML'
# fake-groups: PROXY=B1,B2;GLOBAL=PROXY,DIRECT
proxies: []
YAML

BOX_ENV=(
  PATH="$FAKE_SUPERVISOR:/usr/bin:/bin"
  HOME="$BOX"
  XDG_CONFIG_HOME="$BOX/xdg"
  A2_HOME="$A2HOME"
  A2_SERVICE_SUPERVISOR="launchd"
  A2_FAKE_STATE_DIR="$BOX/state"
  A2_FAKE_LOG="$BOX/supervisor-calls.log"
  A2_FAKE_BUN="$BUN_BIN"
  A2_FAKE_MIHOMO_TS="$FAKE_MIHOMO_TS"
  A2_FAKE_MIHOMO_VERSION="v1.19.28"
  A2_FAKE_MIHOMO_GROUPS="PROXY=A1,A2;GLOBAL=PROXY,DIRECT"
  A2_FAKE_MIHOMO_DELAYS="A1=120;A2=300"
  A2_FAKE_NETSETUP_TS="$FAKE_NETSETUP_TS"
  A2_FAKE_NETSETUP_STATE="$BOX/netfake-state.json"
  A2_FAKE_NETSETUP_LOG="$BOX/netfake-calls.log"
  A2_NETWORKSETUP="$FAKE_NETSETUP_SH"
  A2_MIHOMO_BIN_DIRS="$BOX/foreignbin"
  A2_MIHOMO_CONFIG_FILES="$BOX/foreignconf/config.yaml"
  A2_MIHOMO_CONTROLLER_PORT="$CTRL_PORT"
  A2_MIHOMO_MIXED_PORT="$MIXED_PORT"
  A2_PROXY_WATCH_INTERVAL_MS="200"
)

cleanup() {
  [ -n "$PROBE_PID" ] && kill "$PROBE_PID" 2>/dev/null
  if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$DAEMON_PID" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$DAEMON_PID" 2>/dev/null
  fi
  # 兜底:沙盒根是本次独有的临时路径,按它精确回收 —— 不可能误伤别的进程(尤其用户自己的 mihomo)。
  pkill -9 -f "$BOX" 2>/dev/null
  rm -rf "$BOX" 2>/dev/null
}
trap cleanup EXIT

a2() { env "${BOX_ENV[@]}" "${A2_CMD[@]}" "$@"; }
# JSON 取值:点分路径。**布尔一律输出 true/false**(不是 Python 的 True/False),
#   免得断言写成一个只在 python 下成立的字面量。
json_get() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    if k=="": continue
    if d is None: break
    d=d[int(k)] if isinstance(d,list) else d.get(k)
if d is None: print("")
elif isinstance(d,bool): print("true" if d else "false")
elif isinstance(d,(dict,list)): print(json.dumps(d,ensure_ascii=False))
else: print(d)' "$1"; }

# ---- ④ mihomo 就位 + daemon 起来 --------------------------------------------------------
echo
echo "-- 幕 0:mihomo 就位(复用档)与 daemon 起来"
INSTALL_OUT="$(a2 mihomo install --json 2>&1)"
INSTALL_RC=$?
assert_eq "$INSTALL_RC" "0" "0-1 a2 mihomo install 成功(复用档:落点是符号链接,别人的二进制零改动)"
[ "$INSTALL_RC" -eq 0 ] || { echo "$INSTALL_OUT" | head -20; }

env "${BOX_ENV[@]}" "${A2_CMD[@]}" daemon run >"$BOX/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 150); do [ -S "$SOCK" ] && break; sleep 0.1; done
if [ ! -S "$SOCK" ]; then
  bad "0-2 daemon 没在 15 秒内建起 socket"; tail -30 "$BOX/daemon.log"; echo " PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "0-2 daemon 起来了(临时 A2_HOME,socket=$SOCK)"

# 假 supervisor 按 label 分开记状态:`<label>.pid` 存 pid(`<label>.args` 存 ProgramArguments,别拿错)。
MIHOMO_PIDFILE="$BOX/state/com.a2.mihomo.pid"
MIHOMO_PID_BEFORE="$(tr -dc '0-9' < "$MIHOMO_PIDFILE" 2>/dev/null)"
if [ -n "$MIHOMO_PID_BEFORE" ]; then
  ok "0-3 mihomo 由 com.a2.mihomo 这个**自己的** unit 托管(pid=$MIHOMO_PID_BEFORE)"
else
  bad "0-3 取不到 mihomo 的 pid($MIHOMO_PIDFILE)"
fi

# ---- ⑤ 幕①:旗舰链零打断 ----------------------------------------------------------------
echo
echo "-- 幕 1:旗舰链零打断(开代理 → 切模式 → 选节点 → 加/激活/更新订阅)"

# 确认器上岗(壳的真代码路径)。`--idle-probe 2` 就是零轮询的证据采集段。
env "${BOX_ENV[@]}" "$PROBE_BIN" --socket "$SOCK" --role confirm-agent --decision approve \
  --idle-probe 2 --duration 90 --expect-confirmations 1 >"$BOX/probe-approve.log" 2>&1 &
PROBE_PID=$!
for _ in $(seq 1 200); do grep -q "PANEL_READY" "$BOX/probe-approve.log" 2>/dev/null && break; sleep 0.1; done
if ! grep -q "PANEL_READY" "$BOX/probe-approve.log" 2>/dev/null; then
  bad "1-0 壳(a2-panel-probe)没能在 20 秒内注册成 confirm-agent"; sed 's/^/    /' "$BOX/probe-approve.log"
else
  ok "1-0 壳以对等客户端注册 confirm-agent 并拿到全量快照(注册即快照,一次往返)"
fi

# 零轮询:空闲两秒里请求数一条都不涨。
# **等那一行出现,而不是睡一个刚好够的时长**(13 票修的一处零余量竞态):壳先要"请求数连续 0.5 秒
# 没变"才开始计,再空转 2 秒才打印 —— 与原来那句 `sleep 2.5` 恰好等长,机器一忙就抓到空字符串,
# 于是一条真绿的断言被报成红。判据不变,只是把"睡够了吗"换成"它说了吗"。
for _ in $(seq 1 150); do
  grep -q '^PANEL_IDLE:' "$BOX/probe-approve.log" 2>/dev/null && break
  sleep 0.1
done
IDLE_LINE="$(grep -m1 '^PANEL_IDLE:' "$BOX/probe-approve.log" 2>/dev/null)"
IDLE_BEFORE="$(printf '%s' "$IDLE_LINE" | sed -n 's/.*before=\([0-9]*\).*/\1/p')"
IDLE_AFTER="$(printf '%s' "$IDLE_LINE" | sed -n 's/.*after=\([0-9]*\).*/\1/p')"
if [ -n "$IDLE_BEFORE" ] && [ "$IDLE_BEFORE" = "$IDLE_AFTER" ]; then
  ok "1-1 零轮询:空闲 2 秒里壳向内核发出的请求数不变($IDLE_BEFORE → $IDLE_AFTER)"
else
  bad "1-1 零轮询($IDLE_LINE)"
fi

PROXY_ON_OUT="$(a2 proxy on --json 2>&1)"; assert_eq "$?" "0" "1-2 a2 proxy on 成功(normal,零确认)"
NET_STATE="$(cat "$BOX/netfake-state.json")"
assert_contains "$NET_STATE" "\"port\": $MIXED_PORT" "1-3 系统代理已指向 mihomo 的混合入站端口(改的是假 networksetup)"

MODE_OUT="$(a2 proxy mode --mode global --json 2>&1)"; assert_eq "$?" "0" "1-4 a2 proxy mode --mode global 成功"
NODE_OUT="$(a2 proxy node --group PROXY --node A2 --json 2>&1)"; assert_eq "$?" "0" "1-5 a2 proxy node 选中 A2 成功"

# 换源是 dangerous —— 这一步就是幕②的批准分支(旗舰链里它必须经确认器)。
ADD_OUT="$(a2 proxy subscription add --name "机场 A" --source "file://$BOX/subs/airline-a.yaml" --json 2>&1)"
ADD_RC=$?
assert_eq "$ADD_RC" "0" "2-1 dangerous 换源经确认器批准后放行(退出码 0)"
SUB_ID="$(printf '%s' "$ADD_OUT" | json_get result.output.id 2>/dev/null)"
note "订阅 id = ${SUB_ID:-取不到}"

ACT_OUT="$(a2 proxy subscription activate --id "$SUB_ID" --json 2>&1)"; assert_eq "$?" "0" "1-6 激活订阅成功(normal)"
UPD_OUT="$(a2 proxy subscription update --id "$SUB_ID" --json 2>&1)"; assert_eq "$?" "0" "1-7 更新订阅成功(normal,零确认)"

# 壳的菜单**跟着变**了没有:等投影落定。
sleep 1.5
MENU_LOG="$(grep '^PANEL_MENU:' "$BOX/probe-approve.log")"
MENU_LAST="$(printf '%s' "$MENU_LOG" | tail -1)"
note "壳菜单末态:$MENU_LAST"
# 模式/节点断言比的是**整条时间线**而不是末态:激活订阅会把 a2 自管配置整份重渲染,
#   模式随之回到配置里的默认值(内核的真实行为,不是壳的缺陷)。要验的是「切模式那一刻
#   菜单跟着变了」,所以判据是「这条时间线上出现过 mode=global」。
assert_contains "$MENU_LOG" "mode=global" "1-8 切模式那一刻壳菜单勾选了 global(事件投影,零轮询)"
assert_contains "$MENU_LOG" "PROXY:A2"    "1-8b 选节点那一刻壳菜单在 PROXY 组里勾选了 A2"
assert_contains "$MENU_LAST" "systemProxy=on" "1-9 壳菜单显示系统代理已接管"
assert_contains "$MENU_LAST" "active=$SUB_ID" "1-10 壳菜单勾选了激活的那条订阅"
MENU_COUNT="$(grep -c '^PANEL_MENU:' "$BOX/probe-approve.log")"
if [ "$MENU_COUNT" -ge 3 ]; then
  ok "1-11 壳菜单在链条推进中多次更新($MENU_COUNT 次,状态变化真的被投影出来了)"
else
  bad "1-11 壳菜单更新次数太少($MENU_COUNT)"
fi

# 零打断:整条链里只有换源那一次确认(其余全是 safe/normal)。
CONFIRM_COUNT="$(grep -c '^PANEL_CONFIRM:' "$BOX/probe-approve.log")"
assert_eq "$CONFIRM_COUNT" "1" "1-12 零 GUI 打断:旗舰链里只有 dangerous 换源那一次弹到确认器"

# 确认内容原样呈现(防「agent 替用户点确认」的社工话术)。
CONFIRM_LINE="$(grep -m1 '^PANEL_CONFIRM:' "$BOX/probe-approve.log")"
assert_contains "$CONFIRM_LINE" "capability=proxy.subscription.add" "2-2 确认请求带着能力坐标"
assert_contains "$CONFIRM_LINE" "name: 机场 A" "2-3 确认器原样呈现入参 name"
assert_contains "$CONFIRM_LINE" "source: file://$BOX/subs/airline-a.yaml" "2-4 确认器原样呈现入参 source"
assert_contains "$(grep -m1 '^PANEL_DECIDED:' "$BOX/probe-approve.log")" "decision=approve" "2-5 决定经协议回传(批准)"

SUBS_JSON="$(a2 proxy subscription list --json 2>&1)"
assert_contains "$SUBS_JSON" "$SUB_ID" "2-6 批准之后订阅真的进了清单"

# 对账:壳与真内核的能力面(菜单覆盖面/可追溯性/反向核对全在探针里逐条判)。
MANIFEST_LINE="$(grep -m1 '^PANEL_MANIFEST:' "$BOX/probe-approve.log")"
note "$MANIFEST_LINE"
assert_contains "$MANIFEST_LINE" "ok=1" \
  "5-1 壳装置里的能力清单与**真内核快照**逐条一致(risk / cliAlias / 必填参数 / 取值域)"
COVERAGE_LINE="$(grep -m1 '^PANEL_COVERAGE:' "$BOX/probe-approve.log")"
assert_contains "$COVERAGE_LINE" "ok=1" "5-2 菜单覆盖 04 票 In 清单六项 + 每项落到真内核登记过的能力 + 反向核对无漏"
assert_contains "$COVERAGE_LINE" "actions=6/6" "5-3 六项用户操作逐项有落到真实能力的菜单项"

# ---- ⑥ 幕③:拒绝分支 --------------------------------------------------------------------
echo
echo "-- 幕 3:dangerous 换源 · 拒绝"
kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null; PROBE_PID=""
sleep 0.8

env "${BOX_ENV[@]}" "$PROBE_BIN" --socket "$SOCK" --role confirm-agent --decision deny \
  --duration 60 --expect-confirmations 1 --quit-after-decisions 1 >"$BOX/probe-deny.log" 2>&1 &
PROBE_PID=$!
for _ in $(seq 1 200); do grep -q "PANEL_READY" "$BOX/probe-deny.log" 2>/dev/null && break; sleep 0.1; done

DENY_OUT="$(a2 proxy subscription add --name "机场 B" --source "file://$BOX/subs/airline-b.yaml" --json 2>&1)"
DENY_RC=$?
assert_eq "$DENY_RC" "2" "3-1 确认器拒绝 → 退出码 2"
assert_contains "$DENY_OUT" "confirmation_denied" "3-2 拒因是「有人看了,他不同意」(不是「没人能确认」)"
SUBS_AFTER_DENY="$(a2 proxy subscription list --json 2>&1)"
assert_not_contains "$SUBS_AFTER_DENY" "机场 B" "3-3 被拒之后清单里没有那条订阅(不留痕)"
assert_contains "$(grep -m1 '^PANEL_DECIDED:' "$BOX/probe-deny.log")" "decision=deny" "3-4 决定经协议回传(拒绝)"

# ---- ⑦ 幕④:壳缺席 ----------------------------------------------------------------------
echo
echo "-- 幕 4:壳退出仅断连(代理照跑,dangerous 立即降回默拒)"
kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null; PROBE_PID=""
# 内核靠**断线**知道确认器走了(没有心跳、没有注销消息)。给它一点时间收到 EOF。
sleep 1.0

ARB_JSON="$(a2 arbitration status --json 2>&1)"
CONFIRMER_PRESENT="$(printf '%s' "$ARB_JSON" | json_get result.output.state.confirmerPresent 2>/dev/null)"
assert_eq "$CONFIRMER_PRESENT" "false" "4-1 壳一断连,内核当场判定确认器不在场"

UNAVAIL_OUT="$(a2 proxy subscription add --name "机场 C" --source "file://$BOX/subs/airline-b.yaml" --json 2>&1)"
UNAVAIL_RC=$?
assert_eq "$UNAVAIL_RC" "2" "4-2 无确认器 → dangerous 默拒(退出码 2)"
assert_contains "$UNAVAIL_OUT" "confirmation_unavailable" "4-3 默拒码是第①层的 confirmation_unavailable"
assert_contains "$UNAVAIL_OUT" "guidance" "4-4 拒绝即指引:报文自带「人类如何完成」"

# 代理照跑:壳走了,数据面与控制面都不受影响。
STATUS_JSON="$(a2 proxy status --json 2>&1)"
assert_eq "$?" "0" "4-5 壳缺席后 a2 proxy status 照常答话(代理照跑)"
assert_eq "$(printf '%s' "$STATUS_JSON" | json_get result.output.running)" "true" \
  "4-6 mihomo 仍在运行(壳退出 ≠ 关服务)"
MIHOMO_PID_AFTER="$(tr -dc '0-9' < "$MIHOMO_PIDFILE" 2>/dev/null)"
assert_eq "${MIHOMO_PID_AFTER:-取不到}" "${MIHOMO_PID_BEFORE:-取不到}" \
  "4-7 mihomo 的 pid 全程没变(数据面不随壳起落)"
if [ -n "$MIHOMO_PID_AFTER" ] && kill -0 "$MIHOMO_PID_AFTER" 2>/dev/null; then
  ok "4-7b 那个 pid 此刻真的还活着(不是只有记录还在)"
else
  bad "4-7b mihomo 进程 $MIHOMO_PID_AFTER 已经不在了"
fi

# 壳缺席时事件仍入日志、CLI 可查。
AUDIT_LOG="$A2HOME/log/arbitration.log"
if [ -s "$AUDIT_LOG" ]; then
  ok "4-8 壳缺席时事件仍落 NDJSON 审计日志($AUDIT_LOG)"
else
  bad "4-8 审计日志为空($AUDIT_LOG)"
fi
assert_contains "$(a2 arbitration status --json 2>&1)" "unavailable" "4-9 那次默拒经 CLI 查得到(a2 arbitration status)"
assert_contains "$(a2 arbitration status --json 2>&1)" "confirmer_left" "4-10 「确认器离场」也留了痕"

# ---- ⑧ 幕⑥:显式还原 --------------------------------------------------------------------
echo
echo "-- 幕 6:显式还原(「退出即还原」废除后唯一的还原入口)"
OFF_OUT="$(a2 proxy off --json 2>&1)"; assert_eq "$?" "0" "6-1 a2 proxy off 成功"
if python3 - "$BOX/netfake-state.json" "$BOX/netfake-before.json" <<'PY'
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
sys.exit(0 if a==b else 1)
PY
then
  ok "6-2 系统代理终态**逐字段等于**接管前(第三方 203.0.113.9:8080 精确复原,不是一律关闭)"
else
  bad "6-2 系统代理没能精确还原"
  diff <(python3 -m json.tool "$BOX/netfake-before.json") <(python3 -m json.tool "$BOX/netfake-state.json") | head -20
fi

# ---- ⑨ 红线自查 -------------------------------------------------------------------------
echo
echo "-- 红线自查"
if [ -e "$HOME/.a2" ]; then bad "R-1 真实 ~/.a2 出现了"; else ok "R-1 真实 ~/.a2 仍不存在"; fi
if grep -rq "33888" "$BOX/daemon.log" "$BOX/netfake-calls.log" "$BOX/supervisor-calls.log" 2>/dev/null; then
  bad "R-2 日志里出现了用户 mihomo 的端口"
else
  ok "R-2 全程没出现用户 mihomo 的端口(没碰用户的 mihomo)"
fi
FOREIGN_LABELS="$(grep -o 'com\.[a-z0-9.]*' "$BOX/supervisor-calls.log" 2>/dev/null | sort -u | grep -v '^com\.a2\.' )"
if [ -z "$FOREIGN_LABELS" ]; then
  ok "R-3 整场只对 com.a2.* 说过话(假 supervisor 调用日志逐条核对)"
else
  bad "R-3 对非 com.a2.* 的 label 说过话:$FOREIGN_LABELS"
fi

echo
echo "========================================"
echo " 旗舰 e2e 结果: PASS=$PASS FAIL=$FAIL"
echo "========================================"
[ "$FAIL" -eq 0 ] || exit 1
