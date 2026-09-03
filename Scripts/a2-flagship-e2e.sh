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
# 十幕(①–⑥ 由 10 票立;⑦–⑩ 是 url-router 施工 06 票接上去的)
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
#   ⑦ URL 分流的分流正确性(url-router spec §13.2):未命中 → 兜底浏览器;命中分流域名 + 本机没跑 Roxy
#      → `roxy-launcher`;真 `route` 交给假 `open` 的是 **URL 原文、独立 argv、`#` 之后一个字节都不少**;
#   ⑧ `url-router status` 两格:配置健康(现写的配置文件真的被读到)与 handler **未能判定**(不猜);
#   ⑨ 接管的两条可自动化路(spec §13.1):执行器不在场 → 拉一把壳、等不到 → `confirmation_unavailable`;
#      壳带着机械执行器上岗 → **真指令帧往返**(内核推帧 → 壳逐 scheme 调系统 API 替身 → 回执)→
#      退出码 0;再跑一次 → `already: true` 幂等直通,壳一帧都没再收到;
#   ⑩ 卸载前置⓪e(spec §13.4 的 CLI 野路径那一半):默认 handler 还挂在 com.a2.panel 上时
#      `service uninstall --purge` 结构化拒绝且**零删除**;设回兜底浏览器后同一条命令放行。
#
# ============================================================================
# 红线(逐条落实在下面)
# ============================================================================
#   * **绝不碰用户自己的 mihomo**:扫描面/控制端口/入站端口全部注入沙盒值,
#     `mihomo` 一律是 `kernel/test/support/fake-mihomo`(假件),`33888` 在本文件里零出现;
#   * 一切落在临时 `A2_HOME`(`/tmp/a2fs-*`),真实 `~/.a2` 绝不出现;
#   * 不 launchctl 任何真 unit(`PATH` 只有假 supervisor,`HOME` 也换成临时目录);
#   * `networksetup` 走 `A2_NETWORKSETUP` 覆写到假件,真系统代理一个字节都不动;
#   * **绝不真开浏览器、绝不真改默认 handler、绝不去读真 LaunchServices**(⑦–⑩):url-router 那四个
#     外部程序(`open` / `ps` / `lsof` / `defaults` / `mdfind`)全部经 `A2_URL_ROUTER_*` 打到
#     `kernel/test/support/fake-url-router/` 的行为假件上;壳那侧的系统 API 也是替身
#     (`a2-panel-probe --executor`,见它的 `ScriptedHandlerSetter`);
#   * 起的真 daemon 与假 mihomo 用完杀净(trap 兜底,只杀本次沙盒路径下的进程)。
#
# 用法:
#   bash Scripts/a2-flagship-e2e.sh              # 用 kernel/dist/a2,没有就回落 bun 跑源码入口
#   A2_BIN=/path/to/a2 bash Scripts/a2-flagship-e2e.sh
#   A2_SOURCE=1 bash Scripts/a2-flagship-e2e.sh  # 强制走源码入口(产物可能比源码旧时)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 构建日志往 `.build/` 里写,而在一份**刚 checkout 出来的工作树**里它还不存在
# (`swift package dump-package` 不替我们建它)。少这一句,脚本会死在那次重定向上,
# 而报出来的样子是「a2-panel-probe 构建失败」—— 一条把人引向错误方向的假象。
mkdir -p "$ROOT/.build"

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

# 真实 `~/.a2` 的**本轮基线**(红线自查 R-1 用)。
#
# 原判据是「`~/.a2` 不存在」—— 那条在开发机上成立,但用户**真的把 a2 装到自己机器上**之后
# 就永远红了(2026-08-12 实测:真机验收装出的 ~/.a2 让门禁两条 e2e 齐红)。红线的本意从来不是
# 「这台机器不许有 a2」,而是**「门禁不许碰用户那一份」**。所以改成基线比对:落一个时间戳标记,
# 跑完用 `find -newer` 看真实 home 里有没有任何文件被本轮写过。它同时更严 —— 原判据对
# 「home 本来就在、被门禁改了」是完全看不见的。
REAL_A2_MARKER="$BOX/.real-a2-marker"
: > "$REAL_A2_MARKER"

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

# url-router(幕⑦–⑩)那五个外部程序的行为假件 + 两份落盘物。
#
#   * `open` 只把 argv 记进 `$OPEN_LOG`、**什么都不开** —— 「交出去的是 URL 原文」这条判据靠它;
#   * `ps` 吐空表(= 这台机器上没有任何 Roxy 在跑),`lsof` 复用同一份假件(同样吐空 = 没有 CDP 端口);
#   * `defaults` 把 `$LS_FIXTURE` 原样吐出来 —— 那就是这一幕眼里的「LaunchServices 现状」。
#     **一开始有意让它不存在**:文件不在 → 假件非零退出 → handler「未能判定」,那正是幕⑧要验的一格,
#     也是一台从没换过默认浏览器的机器上的真实形状;
#   * `mdfind` 按白名单回答"这个 bundle id 装着吗"(悬空诊断用)。白名单里放上对照探询要用的
#     `com.apple.finder` 与接管目标本身 —— 于是接管之后 `status` 不会把它误报成悬空。
URL_FAKES="$SUPPORT/fake-url-router"
OPEN_LOG="$BOX/url-open.log"
LS_FIXTURE="$BOX/launch-services.plist"
: > "$OPEN_LOG"

# 假 mihomo 直接放到 a2 自管落点(14 票:embedded 一律锁定版;版本=锁定版 → enable 不走下载)。
# "别人的 bin 目录"留空 —— 外来检测面在本场景里不该有戏份。
mkdir -p "$A2HOME/mihomo/bin"
cp "$FAKE_MIHOMO_SH" "$A2HOME/mihomo/bin/mihomo"
chmod 755 "$A2HOME/mihomo/bin/mihomo"

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
  # ---- url-router(幕⑦–⑩)。**daemon 也吃这一份**:这几条能力跑在 daemon 进程里,
  #      只喂给 CLI 那次调用等于没喂。
  A2_URL_ROUTER_OPEN="$URL_FAKES/open"
  A2_URL_ROUTER_PS="$URL_FAKES/ps"
  A2_URL_ROUTER_LSOF="$URL_FAKES/ps"
  A2_URL_ROUTER_DEFAULTS="$URL_FAKES/defaults"
  A2_URL_ROUTER_MDFIND="$URL_FAKES/mdfind"
  A2_URL_ROUTER_OPEN_LOG="$OPEN_LOG"
  A2_URL_ROUTER_DEFAULTS_FIXTURE="$LS_FIXTURE"
  A2_URL_ROUTER_MDFIND_PRESENT="com.apple.finder,com.a2.panel"
  # 拉起壳之后等它注册的窗(缺省 10s)压到 0.8s:幕⑨第一格等的那个壳**在门禁里永远不会来**
  #   (假 `open` 什么都不开),没必要真站十秒。
  A2_URL_ROUTER_EXECUTOR_WAIT_MS="800"
  # 等系统弹框的窗(缺省 120s)压到 20s:验的是"往返走不走得通",不是"能不能等两分钟";
  #   真探针几毫秒就回话,这个数只是万一它挂了时的止损。
  A2_URL_ROUTER_EXECUTION_TIMEOUT_MS="20000"
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
echo "-- 幕 0:mihomo 就位(embedded)与 daemon 起来"
ENABLE_OUT="$(a2 mihomo enable --mode=embedded --json 2>&1)"
ENABLE_RC=$?
assert_eq "$ENABLE_RC" "0" "0-1 a2 mihomo enable --mode=embedded 成功(模式落盘;二进制已就位故零下载)"
[ "$ENABLE_RC" -eq 0 ] || { echo "$ENABLE_OUT" | head -20; }

env "${BOX_ENV[@]}" "${A2_CMD[@]}" daemon run >"$BOX/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 150); do [ -S "$SOCK" ] && break; sleep 0.1; done
if [ ! -S "$SOCK" ]; then
  bad "0-2 daemon 没在 15 秒内建起 socket"; tail -30 "$BOX/daemon.log"; echo " PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "0-2 daemon 起来了(临时 A2_HOME,socket=$SOCK)"

# 14 票:mihomo 是 daemon 的**子进程**,唯一真相源是认尸文件 `<home>/mihomo/child.json`。
# daemon 启动后异步拉起,等到 status 报 running 为止。
CHILD_JSON="$A2HOME/mihomo/child.json"
MIHOMO_PID_BEFORE=""
for _ in $(seq 1 150); do
  ST="$(a2 mihomo status --json 2>/dev/null)"
  if [ "$(printf '%s' "$ST" | json_get result.embedded.state)" = "running" ] &&      [ "$(printf '%s' "$ST" | json_get result.embedded.controllerReachable)" = "true" ]; then
    MIHOMO_PID_BEFORE="$(printf '%s' "$ST" | json_get result.embedded.pid)"
    break
  fi
  sleep 0.1
done
if [ -n "$MIHOMO_PID_BEFORE" ]; then
  ok "0-3 内嵌 mihomo 由 daemon 拉起为**子进程**(pid=$MIHOMO_PID_BEFORE,认尸文件 $CHILD_JSON)"
else
  bad "0-3 内嵌 mihomo 没在 15 秒内 running(status: $(printf '%s' "$ST" | head -c 300))"
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

# 2026-08-12 用户裁定:**restful 控制 mihomo 的写面整体停用**(切模式 / 选节点 / 测速 / 改可调项 /
# 订阅五条),只留读。它们的能力没有注册,于是**别名层就不存在** —— 这里正面验一次,
# 免得"敲了没反应"被当成回归。恢复注册即恢复这些子命令(见 capability/proxy.ts 的 DISABLED_CAPABILITY_IDS)。
for disabled_cmd in "mode --mode global" "node --group PROXY --node A2" "ping --group PROXY" \
                    "config set --logLevel debug" "subscription list"; do
  # shellcheck disable=SC2086
  DIS_OUT="$(a2 proxy $disabled_cmd --json 2>&1)"; DIS_RC=$?
  assert_eq "$DIS_RC" "1" "1-4 停用的写面子命令「proxy ${disabled_cmd}」不存在(用法错)"
  assert_contains "$DIS_OUT" "usage" "1-5 拒因是用法错而不是业务失败(能力没注册 → 别名不存在)"
done

# 读面照旧 —— 这就是「读一下 mihomo 状态就够了」那半句的活体证据。
assert_eq "$(a2 proxy mode get --json >/dev/null 2>&1; echo $?)" "0" "1-6 读面还在:proxy mode get"
assert_eq "$(a2 proxy groups --json >/dev/null 2>&1; echo $?)" "0" "1-7 读面还在:proxy groups"

# dangerous 档的活体样本改用 demo.wipe(handler 不做任何实际动作,但**风险档与仲裁路径与真能力完全一样**)。
# 原先骑在 `proxy.subscription.add` 上 —— 那条随订阅一并停用了;恢复订阅时把下面三处换回去即可。
DANGEROUS_ID="demo.wipe"
DANGEROUS_INPUT='{"target":"/dev/disk9"}'
ADD_OUT="$(a2 capabilities call "$DANGEROUS_ID" --input "$DANGEROUS_INPUT" --json 2>&1)"
ADD_RC=$?
assert_eq "$ADD_RC" "0" "2-1 dangerous 经确认器批准后放行(退出码 0)"

# 壳的菜单**跟着变**了没有:等投影落定。
sleep 1.5
MENU_LOG="$(grep '^PANEL_MENU:' "$BOX/probe-approve.log")"
MENU_LAST="$(printf '%s' "$MENU_LOG" | tail -1)"
note "壳菜单末态:$MENU_LAST"
# 模式/节点断言比的是**整条时间线**而不是末态:激活订阅会把 a2 自管配置整份重渲染,
#   模式随之回到配置里的默认值(内核的真实行为,不是壳的缺陷)。要验的是「切模式那一刻
#   菜单跟着变了」,所以判据是「这条时间线上出现过 mode=global」。
# 写面停用后,菜单里能被这条链改变的只剩系统代理接管态 —— 那正是它现在唯一的"开关"。
assert_contains "$MENU_LAST" "systemProxy=on" "1-9 壳菜单显示系统代理已接管"
MENU_COUNT="$(grep -c '^PANEL_MENU:' "$BOX/probe-approve.log")"
if [ "$MENU_COUNT" -ge 3 ]; then
  ok "1-11 壳菜单在链条推进中多次更新($MENU_COUNT 次,状态变化真的被投影出来了)"
else
  bad "1-11 壳菜单更新次数太少($MENU_COUNT)"
fi

# 零打断:整条链里只有换源那一次确认(其余全是 safe/normal)。
CONFIRM_COUNT="$(grep -c '^PANEL_CONFIRM:' "$BOX/probe-approve.log")"
assert_eq "$CONFIRM_COUNT" "1" "1-12 零 GUI 打断:旗舰链里只有 dangerous 那一次弹到确认器"

# 确认内容原样呈现(防「agent 替用户点确认」的社工话术)。
CONFIRM_LINE="$(grep -m1 '^PANEL_CONFIRM:' "$BOX/probe-approve.log")"
assert_contains "$CONFIRM_LINE" "capability=$DANGEROUS_ID" "2-2 确认请求带着能力坐标"
assert_contains "$CONFIRM_LINE" "target: /dev/disk9" "2-3 确认器原样呈现入参 target"
assert_contains "$(grep -m1 '^PANEL_DECIDED:' "$BOX/probe-approve.log")" "decision=approve" "2-5 决定经协议回传(批准)"

# handler 的回执原样进 result —— 「批准了就真的执行了」不能只看退出码(那也可能是被静默跳过)。
assert_contains "$ADD_OUT" "/dev/disk9" "2-6 批准之后 handler 真的被调到了(回执带着入参进了 result)"

# 对账:壳与真内核的能力面(菜单覆盖面/可追溯性/反向核对全在探针里逐条判)。
MANIFEST_LINE="$(grep -m1 '^PANEL_MANIFEST:' "$BOX/probe-approve.log")"
note "$MANIFEST_LINE"
assert_contains "$MANIFEST_LINE" "ok=1" \
  "5-1 壳装置里的能力清单与**真内核快照**逐条一致(risk / cliAlias / 必填参数 / 取值域)"
COVERAGE_LINE="$(grep -m1 '^PANEL_COVERAGE:' "$BOX/probe-approve.log")"
assert_contains "$COVERAGE_LINE" "ok=1" "5-2 菜单覆盖面 + 每项落到真内核登记过的能力 + 反向核对无漏(含「能力停用则不许还露着」)"
# 分母跟着**当前真注册的能力**走:2026-08-12 写面九条停用后,六项承诺里只剩两项还有能力兜底
# (系统代理开关 / 基础状态)。恢复注册时这个数会自己涨回去 —— 它是实况,不是硬编码的期望。
assert_contains "$COVERAGE_LINE" "actions=2/2" "5-3 仍有能力兜底的用户操作逐项落到真实能力的菜单项"

# ---- ⑥ 幕③:拒绝分支 --------------------------------------------------------------------
echo
echo "-- 幕 3:dangerous · 拒绝"
kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null; PROBE_PID=""
sleep 0.8

env "${BOX_ENV[@]}" "$PROBE_BIN" --socket "$SOCK" --role confirm-agent --decision deny \
  --duration 60 --expect-confirmations 1 --quit-after-decisions 1 >"$BOX/probe-deny.log" 2>&1 &
PROBE_PID=$!
for _ in $(seq 1 200); do grep -q "PANEL_READY" "$BOX/probe-deny.log" 2>/dev/null && break; sleep 0.1; done

DENY_OUT="$(a2 capabilities call "$DANGEROUS_ID" --input '{"target":"/dev/disk8"}' --json 2>&1)"
DENY_RC=$?
assert_eq "$DENY_RC" "2" "3-1 确认器拒绝 → 退出码 2"
assert_contains "$DENY_OUT" "confirmation_denied" "3-2 拒因是「有人看了,他不同意」(不是「没人能确认」)"
assert_not_contains "$DENY_OUT" '"ok": true' "3-3 被拒之后 handler 一次都没被调到(不留痕)"
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

UNAVAIL_OUT="$(a2 capabilities call "$DANGEROUS_ID" --input '{"target":"/dev/disk7"}' --json 2>&1)"
UNAVAIL_RC=$?
assert_eq "$UNAVAIL_RC" "2" "4-2 无确认器 → dangerous 默拒(退出码 2)"
assert_contains "$UNAVAIL_OUT" "confirmation_unavailable" "4-3 默拒码是第①层的 confirmation_unavailable"
assert_contains "$UNAVAIL_OUT" "guidance" "4-4 拒绝即指引:报文自带「人类如何完成」"

# 代理照跑:壳走了,数据面与控制面都不受影响。
STATUS_JSON="$(a2 proxy status --json 2>&1)"
assert_eq "$?" "0" "4-5 壳缺席后 a2 proxy status 照常答话(代理照跑)"
assert_eq "$(printf '%s' "$STATUS_JSON" | json_get result.output.running)" "true" \
  "4-6 mihomo 仍在运行(壳退出 ≠ 关服务)"
MIHOMO_PID_AFTER="$(a2 mihomo status --json 2>/dev/null | json_get result.embedded.pid)"
assert_eq "${MIHOMO_PID_AFTER:-取不到}" "${MIHOMO_PID_BEFORE:-取不到}" \
  "4-7 mihomo 的 pid 全程没变(壳退出只是断连 —— 孩子是 daemon 的,不是壳的)"
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

# ---- ⑨ 幕⑦:URL 分流的分流正确性(url-router spec §13.2)-------------------------------
echo
echo "-- 幕 7:URL 分流(未命中 / 命中 / fragment 不截断)"

# 配置**现写**(daemon 已经在跑):url-router 的配置没有监视器、也没有缓存,每次调用现读 ——
#   于是这一份既验了「配置真的从这个沙盒 A2_HOME 读」,也顺带验了「daemon 起来之后写的照样算数」。
#   两个值都换成沙盒专用的:缺省域名表里没有 roxy-only.example,缺省兜底也绝不是
#   com.example.e2e-fallback —— 下面的断言还能绿,就只可能是这份文件真的生效了。
cat > "$A2HOME/url-router.json" <<'JSON'
{
  "fallbackBrowserBundleID": "com.example.e2e-fallback",
  "routedDomains": ["roxy-only.example"],
  "roxyApplicationPath": "/Applications/E2E-Roxy.app"
}
JSON

# 未命中的那条 URL 带着 query 与 **fragment**,fragment 里还塞了一个问号与非 ASCII ——
#   02 票踩过的坑正是「把 # 之后当成可以丢掉的东西」。它必须逐字节原样到达 open。
MISS_URL='https://plain.example/a?q=hello world&x=1#片段?y=2'

DRY_MISS="$(a2 url-router route "$MISS_URL" --dry-run --json 2>&1)"
assert_eq "$?" "0" "7-1 url-router route --dry-run 成功(只判不开)"
assert_eq "$(printf '%s' "$DRY_MISS" | json_get result.output.decision)" "fallback-browser" \
  "7-2 未命中分流域名 → 决策是 fallback-browser"
assert_eq "$(cat "$OPEN_LOG")" "" "7-3 --dry-run 一趟 open 都没发生(「只判不开」的字面意思)"

DRY_HIT="$(a2 url-router route "https://sub.roxy-only.example/chat" --dry-run --json 2>&1)"
assert_eq "$(printf '%s' "$DRY_HIT" | json_get result.output.decision)" "roxy-launcher" \
  "7-4 命中分流域名(还是子域名)+ 本机没跑 Roxy(假 ps 空表)+ API 三件套没配 → 降到 roxy-launcher"

ROUTE_OUT="$(a2 url-router route "$MISS_URL" --json 2>&1)"
assert_eq "$?" "0" "7-5 真 route(非 dry-run)成功"
assert_eq "$(printf '%s' "$ROUTE_OUT" | json_get result.output.action)" "fallback-browser" \
  "7-6 未命中的那条真的从兜底浏览器那一级出去了"
# 假 open 的落盘记录:每趟一组 argv、以 -- 收尾。这里做**逐字节**比对 —— 「URL 原样交出去」
#   这条判据要的正是字节级相等(spec §13.2 的「带 fragment 的 URL 不截断」)。
assert_eq "$(cat "$OPEN_LOG")" "$(printf -- '-b\ncom.example.e2e-fallback\n%s\n--' "$MISS_URL")" \
  "7-7 open 收到的是 -b <配置里的兜底浏览器> <URL 原文>:URL 是独立 argv,# 之后一个字节都没少"
assert_eq "$(printf '%s' "$ROUTE_OUT" | json_get result.output.url)" \
  "https://plain.example/a?redacted#redacted" \
  "7-8 报文里那份是脱敏的(query/fragment 换成 redacted)—— 开给用户的是原文,进机读面的是这份"
assert_not_contains "$ROUTE_OUT" "hello world" "7-9 stdout 里没有 query 原文(脱敏纪律的活体证据)"

# ---- ⑩ 幕⑧:url-router status 的两格 ---------------------------------------------------
echo
echo "-- 幕 8:url-router status(配置健康 + handler 未能判定)"
STATUS_OUT="$(a2 url-router status --json 2>&1)"
assert_eq "$?" "0" "8-1 url-router status 成功"
assert_eq "$(printf '%s' "$STATUS_OUT" | json_get result.output.configSource)" "file" \
  "8-2 配置健康:这份生效配置来自文件(合契约,已与缺省逐字段合并)"
assert_eq "$(printf '%s' "$STATUS_OUT" | json_get result.output.config.fallbackBrowserBundleID)" \
  "com.example.e2e-fallback" "8-3 生效配置里的兜底浏览器就是文件里写的那个"
assert_eq "$(printf '%s' "$STATUS_OUT" | json_get result.output.config.routedDomains)" \
  '["roxy-only.example"]' "8-4 分流域名表整份来自文件(缺省那三条一个都没掺进来)"
# 假 defaults 此刻没有 fixture 可吐 → 非零退出 → 内核如实报「未能判定」,**不猜**。
#   这正是一台从没换过默认浏览器的机器上的真实形状(LaunchServices 里根本没有对应条目)。
assert_eq "$(printf '%s' "$STATUS_OUT" | json_get result.output.handler.matchesTarget)" "" \
  "8-5 handler 读不出来时 matchesTarget 是 null(而不是猜一个「大概是 Safari」)"
assert_contains "$STATUS_OUT" "未能判定" "8-6 而且说清了为什么(没换过就不会有登记项 —— 这不是故障)"

# ---- ⑪ 幕⑨:接管的两条可自动化路(url-router spec §13.1)-------------------------------
echo
echo "-- 幕 9:接管(执行器不在场 → 默拒;执行器在场 → 真指令帧往返 + 幂等复跑)"
: > "$OPEN_LOG"

# ① 此刻一个壳都没在跑(幕④之后探针就退场了)。内核会先 open -b com.a2.panel 拉一把 ——
#    假 open「成功」了(它什么都不开),于是这条路准确地落在「拉起过了,但没人注册上来」那一格。
TAKEOVER_OUT="$(a2 url-router takeover --json 2>&1)"
TAKEOVER_RC=$?
assert_eq "$TAKEOVER_RC" "2" "9-1 执行器不在场 → 退出码 2(dangerous 一步都没往下走)"
assert_contains "$TAKEOVER_OUT" "confirmation_unavailable" \
  "9-2 拒因是第①层的「没人能替你确认」—— 确认换了个地方(系统弹框),词表一个新词都没造"
assert_contains "$TAKEOVER_OUT" "系统设置" "9-3 拒绝即指引:连「不装壳也能干成」的那条路都给了"
assert_eq "$(cat "$OPEN_LOG")" "$(printf -- '-b\ncom.a2.panel\n--')" \
  "9-4 这条路上恰好一趟 open -b com.a2.panel(拉壳是显式变更里的一步),没有开任何 URL"

# ② 壳带着机械执行器上岗。**装配与真壳逐字同形**(A2PanelSession 的 executor 参数),
#    只有最末那次系统调用换成了替身 —— 见 a2-panel-probe 的 ScriptedHandlerSetter。
: > "$OPEN_LOG"
env "${BOX_ENV[@]}" "$PROBE_BIN" --socket "$SOCK" --role confirm-agent --executor \
  --duration 60 >"$BOX/probe-executor.log" 2>&1 &
PROBE_PID=$!
for _ in $(seq 1 200); do
  grep -q "已注册 url-router-executor" "$BOX/probe-executor.log" 2>/dev/null && break
  sleep 0.1
done
if grep -q "已注册 url-router-executor" "$BOX/probe-executor.log" 2>/dev/null; then
  ok "9-5 壳在**同一条连接**上注册了第二个角色 url-router-executor(装了执行器才举手)"
else
  bad "9-5 壳没能在 20 秒内注册成 url-router-executor"; sed 's/^/    /' "$BOX/probe-executor.log"
fi

TAKEOVER2_OUT="$(a2 url-router takeover --json 2>&1)"
TAKEOVER2_RC=$?
assert_eq "$TAKEOVER2_RC" "0" "9-6 执行器在场 → 一趟真的指令帧往返之后退出码 0"
assert_eq "$(printf '%s' "$TAKEOVER2_OUT" | json_get result.output.outcome)" "confirmed" \
  "9-7 收场是 confirmed(内核按 perScheme 那份逐条事实判的,不是听壳一句概括)"
PER_SCHEME="$(printf '%s' "$TAKEOVER2_OUT" | json_get result.output.perScheme.http.ok)/$(printf '%s' "$TAKEOVER2_OUT" | json_get result.output.perScheme.https.ok)"
assert_eq "$PER_SCHEME" "true/true" "9-8 两个 scheme 逐条都成了(http 与 https 是两次独立的系统弹框)"
assert_eq "$(grep -c '^PANEL_EXECUTE_SET:' "$BOX/probe-executor.log")" "2" \
  "9-9 壳收到帧之后**逐 scheme**各调了一次系统 API(账本收齐了才回执,而且只回一次)"
assert_contains "$(cat "$BOX/probe-executor.log")" "PANEL_EXECUTE_LOCATE: bundleID=com.a2.panel" \
  "9-10 帧上的 bundleID 原样到了壳手里 —— 壳自己不认得任何 bundle id,是内核算好了写在帧上的"
assert_eq "$(cat "$OPEN_LOG")" "" "9-11 执行器已经在场 → 一趟 open 都没有(拉壳只发生在它不在的时候)"

# 假件不会真改这台机器的默认浏览器(红线),所以这里**把 LaunchServices 那份投影换成「接管之后」** ——
#   幂等判据读的正是它。这不是绕过判据,而是给它喂上真机上本来就会读到的下一帧。
cat > "$LS_FIXTURE" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>LSHandlers</key>
  <array>
    <dict>
      <key>LSHandlerRoleAll</key>
      <string>com.a2.panel</string>
      <key>LSHandlerURLScheme</key>
      <string>http</string>
    </dict>
    <dict>
      <key>LSHandlerRoleAll</key>
      <string>com.a2.panel</string>
      <key>LSHandlerURLScheme</key>
      <string>https</string>
    </dict>
  </array>
</dict>
</plist>
PLIST
STATUS_TAKEN="$(a2 url-router status --json 2>&1)"
assert_eq "$(printf '%s' "$STATUS_TAKEN" | json_get result.output.handler.matchesTarget)" "true" \
  "9-12 status 现读:两个 scheme 的默认 handler 都是 com.a2.panel"
assert_eq "$(printf '%s' "$STATUS_TAKEN" | json_get result.output.handler.dangling)" "" \
  "9-13 且不报悬空(假 mdfind 答得上话,而且这个 bundle id 在它的白名单里「装着」)"

AGAIN_OUT="$(a2 url-router takeover --json 2>&1)"
assert_eq "$?" "0" "9-14 复跑 takeover 退出码 0"
assert_eq "$(printf '%s' "$AGAIN_OUT" | json_get result.output.already)" "true" \
  "9-15 幂等直通:已经是目标了就 already: true"
assert_eq "$(grep -c '^PANEL_EXECUTE_LOCATE:' "$BOX/probe-executor.log")" "1" \
  "9-16 幂等那一趟壳一帧都没收到(不弹框 —— 幂等的调用不该打扰任何人)"
assert_eq "$(cat "$OPEN_LOG")" "" "9-17 幂等那一趟也没拉起任何东西"

kill "$PROBE_PID" 2>/dev/null; wait "$PROBE_PID" 2>/dev/null; PROBE_PID=""

# ---- ⑫ 幕⑩:卸载前置⓪e(url-router spec §13.4 的 CLI 野路径那一半)---------------------
echo
echo "-- 幕 10:还挂着默认 handler 就拒绝 --purge(拒绝即指引 + 零删除)"

# 这一幕**另起一个沙盒 home**,绝不碰上面那个正跑着 daemon 的:--purge 会把整个 $A2_HOME 删掉,
#   而 18 票的白名单又规定它**只对缺省 ~/.a2 放行** —— 于是这里把 HOME 指到一个新的临时目录,
#   它下面那个 .a2 就是被测进程眼里的「缺省 home」。真实家目录一个字节都不会被碰(R-1 盯着)。
#   假 supervisor 的状态目录也单开一份:这一幕会对 com.a2.* 的 unit 说话,不该搅到主沙盒的账。
PURGE_ROOT="$BOX/purgebox"
PURGE_HOME="$PURGE_ROOT/.a2"
mkdir -p "$PURGE_HOME" "$PURGE_ROOT/xdg" "$BOX/purge-state"
: > "$PURGE_HOME/marker"
PURGE_ENV=(
  PATH="$FAKE_SUPERVISOR:/usr/bin:/bin"
  HOME="$PURGE_ROOT"
  XDG_CONFIG_HOME="$PURGE_ROOT/xdg"
  A2_HOME="$PURGE_HOME"
  A2_SERVICE_SUPERVISOR="launchd"
  A2_FAKE_STATE_DIR="$BOX/purge-state"
  A2_FAKE_LOG="$BOX/supervisor-calls.log"
  A2_NETWORKSETUP="$FAKE_NETSETUP_SH"
  A2_URL_ROUTER_DEFAULTS="$URL_FAKES/defaults"
  A2_URL_ROUTER_DEFAULTS_FIXTURE="$LS_FIXTURE"
)
purge_a2() { env "${PURGE_ENV[@]}" "${A2_CMD[@]}" "$@"; }

# fixture 此刻还是幕⑨末尾那份(两个 scheme 都是 com.a2.panel)= 还接管着。
PURGE_OUT="$(purge_a2 service uninstall --purge --json 2>&1)"
PURGE_RC=$?
assert_eq "$PURGE_RC" "1" "10-1 com.a2.panel 仍是默认 handler → --purge 被拒(退出码 1:命令没错,状态不对)"
assert_contains "$PURGE_OUT" "service_purge_url_handler_taken" "10-2 拒因指名道姓(不与别的 purge 拒绝混为一谈)"
assert_contains "$PURGE_OUT" "a2 url-router restore --json" \
  "10-3 拒绝即指引:先跑还原(那条命令就住在这次要删掉的 bin 里),再来 purge"
if [ -f "$PURGE_HOME/marker" ]; then
  ok "10-4 拒绝时**零删除**(那个 home 一个文件都没少)"
else
  bad "10-4 被拒的这一趟居然动了数据"
fi

# 用户跑过一次 restore 之后的现状:两个 scheme 都设回兜底浏览器 —— 这道门自然让开。
cat > "$LS_FIXTURE" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>LSHandlers</key>
  <array>
    <dict>
      <key>LSHandlerRoleAll</key>
      <string>com.example.e2e-fallback</string>
      <key>LSHandlerURLScheme</key>
      <string>http</string>
    </dict>
    <dict>
      <key>LSHandlerRoleAll</key>
      <string>com.example.e2e-fallback</string>
      <key>LSHandlerURLScheme</key>
      <string>https</string>
    </dict>
  </array>
</dict>
</plist>
PLIST
PURGE_OK_OUT="$(purge_a2 service uninstall --purge --json 2>&1)"
PURGE_OK_RC=$?
assert_eq "$PURGE_OK_RC" "0" "10-5 设回兜底浏览器之后,**同一条命令**放行"
assert_contains "$PURGE_OK_OUT" "$PURGE_HOME" "10-6 报文如实说清删掉的是哪个 home"
if [ -e "$PURGE_HOME" ]; then
  bad "10-7 放行了却没真删($PURGE_HOME 还在)"
else
  ok "10-7 那个沙盒 home 真的清干净了"
fi

# ---- ⑬ 红线自查 -------------------------------------------------------------------------
echo
echo "-- 红线自查"
if [ ! -e "$HOME/.a2" ]; then
  ok "R-1 真实 ~/.a2 仍不存在"
elif [ -z "$(find "$HOME/.a2" -newer "$REAL_A2_MARKER" 2>/dev/null | head -1)" ]; then
  ok "R-1 真实 ~/.a2 存在(用户自己装的),但本轮一个字节都没被碰"
else
  bad "R-1 真实 ~/.a2 在本轮被写过:$(find "$HOME/.a2" -newer "$REAL_A2_MARKER" 2>/dev/null | head -3 | tr '\n' ' ')"
fi
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

# R-4:url-router 那五个外部程序**必须全部**打在假件上。
#
# 为什么值得一条自查:它们在生产实现里走的是**绝对路径**(/usr/bin/open、/bin/ps……),
# 「PATH 只有假 supervisor」那道防线对它们完全无效。哪天有人手滑删掉 BOX_ENV 里的一行,
# 门禁就会真在跑测试的人脸上弹出一个浏览器窗口、真去读这台机器的 LaunchServices ——
# 而且多半还是绿的(那些断言照样成立)。所以这里正面核一次:五个都在,且都指向假件目录。
URL_ROUTER_INJECTED=0
URL_ROUTER_LEAKS=""
for pair in "${BOX_ENV[@]}"; do
  case "$pair" in
    A2_URL_ROUTER_PS=*|A2_URL_ROUTER_LSOF=*|A2_URL_ROUTER_OPEN=*|A2_URL_ROUTER_DEFAULTS=*|A2_URL_ROUTER_MDFIND=*)
      URL_ROUTER_INJECTED=$((URL_ROUTER_INJECTED+1))
      case "${pair#*=}" in "$URL_FAKES"/*) ;; *) URL_ROUTER_LEAKS="$URL_ROUTER_LEAKS $pair" ;; esac ;;
  esac
done
if [ "$URL_ROUTER_INJECTED" -eq 5 ] && [ -z "$URL_ROUTER_LEAKS" ]; then
  ok "R-4 url-router 的五个外部程序全部打在行为假件上(绝不真开浏览器、不读真 LaunchServices/Spotlight)"
else
  bad "R-4 url-router 假件注入有缺口(注入了 $URL_ROUTER_INJECTED/5;漏网:${URL_ROUTER_LEAKS:-无})"
fi

echo
echo "========================================"
echo " 旗舰 e2e 结果: PASS=$PASS FAIL=$FAIL"
echo "========================================"
[ "$FAIL" -eq 0 ] || exit 1
