#!/bin/bash
# 插件宿主端到端验收(11 票)——**真 `a2` bin + agent 现场写的插件 + 壳的真代码路径当确认器**。
#
# ============================================================================
# 它验的是北极星那条路
# ============================================================================
# 「agent 现场写插件」(ADR 0010/0011)。所以本脚本**自己就是那个 agent**:
# 它在临时目录里现写一个零依赖单文件 `.ts`,`a2 plugin add` 装上,然后完全经 CLI 把它调通 ——
# 全程没有任何构建步骤、没有 `bun install`、没有配置文件、没有装载审批。
#
# 六幕:
#   ① 现场写 → add(**零闸**:一个确认器都没有也照样装上)→ 能力面立刻能看见 → 调通;
#   ② dangerous 声明的工具:无确认器时默拒(退出码 2 + 指引);确认器上岗后批准 → 照常执行;
#   ③ **红线**:插件在进程外(pid ≠ 内核 pid)、能力只经协议白名单(拿不到一个 `A2_*`)、
#      工件只在登记区(源文件删掉照跑);
#   ④ 卸载:能力当场消失,再调就是 unknown_capability;
#   ⑤ 留痕:装/卸都进 NDJSON 审计日志,`a2 arbitration status` 查得到(装载零闸下唯一的可审计物);
#   ⑥ **依赖流(12 票)**:带 npm 依赖的**目录插件** add 时由内核自己 install+bundle 成单文件,
#      删掉整个源目录后照常可调(离线证明);打不进的怪包(native addon)当场结构化拒绝。
#
# 12 票的两条口径:**不出网**(依赖是本脚本现打的本地 npm tarball,走 `file:` 依赖)、
# **不写用户的 `~/.bun/install/cache`**(`BUN_INSTALL_CACHE_DIR` 钉在沙盒里)。
#
# ============================================================================
# 红线(逐条落实在下面)
# ============================================================================
#   * **绝不碰用户自己的 mihomo**:mihomo 的扫描面/控制端口全部注入沙盒值(空目录 + 临时端口),
#     `33888` 在本文件里零出现;本脚本压根不装、不起任何 mihomo;
#   * 一切落在临时 `A2_HOME`(`/tmp/a2pe-*`),真实 `~/.a2` 绝不出现;
#   * 不 launchctl 任何真 unit(`PATH` 只有假 supervisor,`HOME` 也换成临时目录);
#   * `networksetup` 走 `A2_NETWORKSETUP` 覆写到"一执行就大声失败"的假件,真系统代理一个字节都不动;
#   * 起的真 daemon 与插件子进程用完杀净(trap 兜底,只杀本次沙盒路径下的进程)。
#
# 用法:
#   bash Scripts/a2-plugin-e2e.sh              # 用 kernel/dist/a2,没有就回落 bun 跑源码入口
#   A2_BIN=/path/to/a2 bash Scripts/a2-plugin-e2e.sh
#   A2_SOURCE=1 bash Scripts/a2-plugin-e2e.sh  # 强制走源码入口
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
assert_not_contains() {
  case "$1" in *"$2"*) bad "$3(不该出现 '$2')" ;; *) ok "$3" ;; esac
}

# ---- ① 工具链 -------------------------------------------------------------------------
SWIFT_BIN=""
for cand in "${AA_SWIFT:-}" "$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift" swift; do
  [ -z "$cand" ] && continue
  if ! command -v "$cand" >/dev/null 2>&1 && [ ! -x "$cand" ]; then continue; fi
  if "$cand" package dump-package --scratch-path "$ROOT/.build/plugin-probe" >/dev/null 2>&1; then
    SWIFT_BIN="$cand"; break
  fi
done
[ -n "$SWIFT_BIN" ] || { echo "FAIL: 找不到 SPM 可用的 swift(判据同 check.sh)—— 确认器用的是壳的真代码路径"; exit 1; }

BUN_BIN="$(command -v bun 2>/dev/null)"
[ -z "$BUN_BIN" ] && [ -x "$HOME/.bun/bin/bun" ] && BUN_BIN="$HOME/.bun/bin/bun"
[ -n "$BUN_BIN" ] || { echo "FAIL: 找不到 bun"; exit 1; }

A2_CMD=()
if [ -n "${A2_BIN:-}" ]; then A2_CMD=("$A2_BIN")
elif [ -x "$ROOT/kernel/dist/a2" ] && [ -z "${A2_SOURCE:-}" ]; then A2_CMD=("$ROOT/kernel/dist/a2")
else A2_CMD=("$BUN_BIN" run "$ROOT/kernel/src/cli/main.ts"); fi

echo "==== 插件宿主 e2e(11 票)===="
echo " a2    = ${A2_CMD[*]}"

# ---- ② 壳的无头替身(确认器)-----------------------------------------------------------
"$SWIFT_BIN" build --scratch-path "$ROOT/.build/flagship" --product a2-panel-probe \
  >"$ROOT/.build/plugin-e2e-build.log" 2>&1
if [ $? -ne 0 ]; then
  echo "FAIL: a2-panel-probe 构建失败,日志尾部:"; tail -20 "$ROOT/.build/plugin-e2e-build.log"; exit 1
fi
PROBE_BIN="$("$SWIFT_BIN" build --scratch-path "$ROOT/.build/flagship" --show-bin-path 2>/dev/null)/a2-panel-probe"
[ -x "$PROBE_BIN" ] || { echo "FAIL: 取不到 a2-panel-probe($PROBE_BIN)"; exit 1; }

# ---- ③ 沙盒 ---------------------------------------------------------------------------
BOX="$(mktemp -d /tmp/a2pe-XXXXXX)"
A2HOME="$BOX/a2home"
WORKSPACE="$BOX/agent-workspace"     # agent 写插件的地方(**不是** A2_HOME)
SUPPORT="$ROOT/kernel/test/support"
mkdir -p "$A2HOME" "$WORKSPACE" "$BOX/xdg" "$BOX/state" "$BOX/emptybin" "$BOX/emptyconf" "$BOX/bun-cache"
SOCK="$A2HOME/run/kernel.sock"
DAEMON_PID=""
PROBE_PID=""

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
CTRL_PORT="$(free_port)"

BOX_ENV=(
  PATH="$SUPPORT/fake-supervisor:/usr/bin:/bin"
  HOME="$BOX"
  XDG_CONFIG_HOME="$BOX/xdg"
  A2_HOME="$A2HOME"
  A2_SERVICE_SUPERVISOR="launchd"
  A2_FAKE_STATE_DIR="$BOX/state"
  A2_FAKE_LOG="$BOX/supervisor-calls.log"
  A2_NETWORKSETUP="$SUPPORT/fake-networksetup/networksetup-forbidden"
  # mihomo 面全部指向**空的**沙盒目录:本票不碰数据面,更不许去读用户的配置或探他的控制端口。
  A2_MIHOMO_BIN_DIRS="$BOX/emptybin"
  A2_MIHOMO_CONFIG_FILES="$BOX/emptyconf/config.yaml"
  A2_MIHOMO_CONTROLLER_PORT="$CTRL_PORT"
  A2_PROXY_WATCH_INTERVAL_MS="2000"
  A2_PLUGIN_TIMEOUT_MS="20000"
  # 12 票:装依赖的包缓存钉死在沙盒里 —— 门禁跑一万遍,用户的 ~/.bun/install/cache 一个字节都不变。
  BUN_INSTALL_CACHE_DIR="$BOX/bun-cache"
)

cleanup() {
  # `wait` 是为了让 bash 自己把这个作业收掉 —— 否则收尸时它会往 stderr 打一行 "Terminated: 15",
  # 在门禁日志里看起来像是出了事(其实是我们自己按预期杀的)。
  if [ -n "$PROBE_PID" ]; then
    kill "$PROBE_PID" 2>/dev/null
    wait "$PROBE_PID" 2>/dev/null
  fi
  if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$DAEMON_PID" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$DAEMON_PID" 2>/dev/null
  fi
  # 兜底:沙盒根是本次独有的临时路径,按它精确回收(插件子进程的 argv 里带着这条路径)。
  pkill -9 -f "$BOX" 2>/dev/null
  rm -rf "$BOX" 2>/dev/null
}
trap cleanup EXIT

a2() { env "${BOX_ENV[@]}" "${A2_CMD[@]}" "$@"; }
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

# ---- ④ daemon 起来 --------------------------------------------------------------------
echo
echo "-- 幕 0:daemon 起来(不装 mihomo、不碰系统代理)"
env "${BOX_ENV[@]}" "${A2_CMD[@]}" daemon run >"$BOX/daemon.log" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 1 150); do [ -S "$SOCK" ] && break; sleep 0.1; done
if [ ! -S "$SOCK" ]; then
  bad "0-1 daemon 没在 15 秒内建起 socket"; tail -30 "$BOX/daemon.log"; echo " PASS=$PASS FAIL=$FAIL"; exit 1
fi
ok "0-1 daemon 起来了(临时 A2_HOME,socket=$SOCK)"
KERNEL_PID="$(a2 status --json | json_get result.pid)"
note "内核 daemon pid = $KERNEL_PID"

# ---- ⑤ 幕①:agent 现场写插件 → 零闸装上 → 当场调通 -------------------------------------
echo
echo "-- 幕 1:agent 现场写一个零依赖单文件插件 → add(零闸)→ 经 CLI 调通"

# 这就是"现场写"的全部仪式:一个文件,没有 package.json,没有 install,没有 build。
cat > "$WORKSPACE/notes.ts" <<'TS'
const TOOLS = [
  { name: "shout", summary: "把一句话喊出来", dangerous: false,
    parameters: [{ name: "text", type: "string", required: true, description: "要喊的话" }] },
  { name: "burn", summary: "假装烧掉点什么(dangerous 声明)", dangerous: true,
    parameters: [{ name: "what", type: "string", required: true, description: "假想目标" }] },
];
const mode = process.argv[2];
if (mode === "describe") {
  console.log(JSON.stringify({ protocol: 1, name: "notes", tools: TOOLS }));
  process.exit(0);
}
if (mode === "call") {
  const req = JSON.parse(await Bun.stdin.text());
  if (req.tool === "shout") {
    console.error("插件的调试信息走 stderr,绝不该混进 stdout");
    console.log(JSON.stringify({ ok: true, output: {
      shouted: String(req.input.text).toUpperCase(),
      pid: process.pid,
      a2env: Object.keys(process.env).filter((k) => k.startsWith("A2_")),
    } }));
    process.exit(0);
  }
  if (req.tool === "burn") {
    console.log(JSON.stringify({ ok: true, output: { burned: req.input.what } }));
    process.exit(0);
  }
  console.log(JSON.stringify({ ok: false, error: { message: "未知工具" } }));
  process.exit(4);
}
process.exit(2);
TS

# **装载零闸**:此刻一个确认器都没有(下一幕才起),照样装得上。
ADD_OUT="$(a2 plugin add "$WORKSPACE/notes.ts" --json 2>&1)"
ADD_RC=$?
assert_eq "$ADD_RC" "0" "1-1 一个确认器都没有,插件照样当场装上(装载零闸,ADR 0011)"
[ "$ADD_RC" -eq 0 ] || { echo "$ADD_OUT" | head -20; }
ARTIFACT="$(printf '%s' "$ADD_OUT" | json_get result.plugin.artifact)"
assert_eq "$ARTIFACT" "$A2HOME/plugins/notes.ts" "1-2 工件被复制进登记区(源文件从此与内核无关)"

CAPS="$(a2 capabilities list --json 2>&1)"
assert_contains "$CAPS" "plugin.notes.shout" "1-3 插件工具立刻出现在**统一能力面**上(与内置能力同一张表)"
assert_eq "$(printf '%s' "$ADD_OUT" | json_get result.added.0.risk)" "normal" \
  "1-4 没声明 dangerous 的工具登记为 normal(内核不替插件猜它是不是只读)"
assert_eq "$(printf '%s' "$ADD_OUT" | json_get result.added.1.risk)" "dangerous" \
  "1-5 声明了 dangerous 的工具登记为 dangerous 档"

CALL_OUT="$(a2 capabilities call plugin.notes.shout --input '{"text":"hello a2"}' --json 2>&1)"
CALL_RC=$?
assert_eq "$CALL_RC" "0" "1-6 agent 经 CLI 全链路调用插件工具成功(safe/normal 直通,零打断)"
assert_eq "$(printf '%s' "$CALL_OUT" | json_get result.output.shouted)" "HELLO A2" \
  "1-7 结果原样回到 stdout 的 JSON 包封里(stdin JSON 进、stdout JSON 出)"

# ---- ⑥ 幕②:dangerous 声明的工具走三层仲裁 ---------------------------------------------
echo
echo "-- 幕 2:dangerous 插件工具 —— 无确认器默拒 / 确认器批准放行"

DENIED_OUT="$(a2 capabilities call plugin.notes.burn --input '{"what":"沙盒"}' --json 2>&1)"
DENIED_RC=$?
assert_eq "$DENIED_RC" "2" "2-1 无确认器时 dangerous 插件工具被默拒(退出码 2,与内置 dangerous 一致)"
assert_contains "$DENIED_OUT" "confirmation_unavailable" "2-2 拒因是第①层的 confirmation_unavailable"
assert_contains "$DENIED_OUT" "guidance" "2-3 拒绝即指引:报文自带「人类如何完成」"
assert_not_contains "$DENIED_OUT" "burned" "2-4 被拒时插件**一次都没被拉起**(响应里没有它的产物)"

# 确认器上岗 —— 用的是壳的真代码路径(a2-panel-probe 复用 A2Panel 全套)。
env "${BOX_ENV[@]}" "$PROBE_BIN" --socket "$SOCK" --role confirm-agent --decision approve \
  --duration 60 --expect-confirmations 1 --quit-after-decisions 1 >"$BOX/probe.log" 2>&1 &
PROBE_PID=$!
for _ in $(seq 1 200); do grep -q "PANEL_READY" "$BOX/probe.log" 2>/dev/null && break; sleep 0.1; done
if grep -q "PANEL_READY" "$BOX/probe.log" 2>/dev/null; then
  ok "2-5 确认器(壳的真代码路径)注册成 confirm-agent"
else
  bad "2-5 确认器没能在 20 秒内注册"; sed 's/^/    /' "$BOX/probe.log"
fi

APPROVED_OUT="$(a2 capabilities call plugin.notes.burn --input '{"what":"沙盒"}' --json 2>&1)"
APPROVED_RC=$?
assert_eq "$APPROVED_RC" "0" "2-6 确认器批准后 dangerous 插件工具照常执行(退出码 0)"
assert_eq "$(printf '%s' "$APPROVED_OUT" | json_get result.output.burned)" "沙盒" \
  "2-7 执行结果来自插件本身"
CONFIRM_LINE="$(grep -m1 '^PANEL_CONFIRM:' "$BOX/probe.log")"
assert_contains "$CONFIRM_LINE" "capability=plugin.notes.burn" "2-8 确认请求带着插件工具的能力坐标"
assert_contains "$CONFIRM_LINE" "what: 沙盒" "2-9 确认器**原样呈现**入参(插件工具与内置能力一视同仁)"

# ---- ⑦ 幕③:红线 —— 进程外 + 协议白名单 ------------------------------------------------
echo
echo "-- 幕 3:红线(旧「PluginProxy 不 import Host*」在新架构下的等价物 = 进程边界)"

PLUGIN_PID="$(printf '%s' "$CALL_OUT" | json_get result.output.pid)"
if [ -n "$PLUGIN_PID" ] && [ "$PLUGIN_PID" != "$KERNEL_PID" ]; then
  ok "3-1 插件是**进程外**子进程(插件 pid=$PLUGIN_PID ≠ 内核 pid=$KERNEL_PID)"
else
  bad "3-1 插件 pid($PLUGIN_PID)与内核 pid($KERNEL_PID)没能分开"
fi
assert_eq "$(printf '%s' "$CALL_OUT" | json_get result.output.a2env)" "[]" \
  "3-2 能力只经协议白名单:内核一个 A2_* 都没递给插件(它连 socket 在哪都不知道)"

# 源文件删掉照跑 —— 登记的是登记区里那份工件。
rm -f "$WORKSPACE/notes.ts"
AFTER_RM="$(a2 capabilities call plugin.notes.shout --input '{"text":"still here"}' --json 2>&1)"
assert_eq "$?" "0" "3-3 删掉源文件后插件照常工作(登记的是工件快照,不是那个路径)"
assert_eq "$(printf '%s' "$AFTER_RM" | json_get result.output.shouted)" "STILL HERE" "3-4 而且行为一字不变"

# ---- ⑧ 幕④:卸载 ----------------------------------------------------------------------
echo
echo "-- 幕 4:卸载 —— 能力当场消失"
REMOVE_OUT="$(a2 plugin remove notes --json 2>&1)"
assert_eq "$?" "0" "4-1 a2 plugin remove 成功"
assert_not_contains "$(a2 capabilities list --json 2>&1)" "plugin.notes.shout" "4-2 能力从统一调用面消失"
GONE_OUT="$(a2 capabilities call plugin.notes.shout --input '{"text":"x"}' --json 2>&1)"
assert_eq "$?" "6" "4-3 再调就是协议错(退出码 6)"
assert_contains "$GONE_OUT" "unknown_capability" "4-4 拒因是 unknown_capability(带「先列一下有什么」的指引)"
if [ -f "$A2HOME/plugins/notes.ts" ]; then
  bad "4-5 工件还留在登记区"
else
  ok "4-5 工件已从登记区删除"
fi

# ---- ⑨ 幕⑤:留痕(装载零闸下唯一的可审计物)-------------------------------------------
echo
echo "-- 幕 5:留痕 —— 装/卸都进 NDJSON 审计日志且 CLI 查得到"
AUDIT_LOG="$A2HOME/log/arbitration.log"
if [ -s "$AUDIT_LOG" ]; then ok "5-1 审计日志非空($AUDIT_LOG)"; else bad "5-1 审计日志为空"; fi
assert_contains "$(cat "$AUDIT_LOG")" "plugin_added" "5-2 装插件这件事本身留了痕(NDJSON)"
assert_contains "$(cat "$AUDIT_LOG")" "plugin_removed" "5-3 卸插件同样留痕"
ARB_JSON="$(a2 arbitration status --json 2>&1)"
assert_contains "$ARB_JSON" "plugin_added" "5-4 经 a2 arbitration status 查得到(壳缺席时也查得到)"
assert_contains "$ARB_JSON" "装载零闸" "5-5 留痕里写明了「这次没有经过任何确认」"

# ---- ⑨b 幕⑥:依赖流 —— 目录插件装载期 install+bundle,删源目录仍可调(12 票)-----------
echo
echo "-- 幕 6:带 npm 依赖的目录插件 —— add 时 install+bundle 成单文件,删掉源目录照跑"

# 依赖包:现打一个**真 npm tarball**(package/ 根 + package.json,与 registry 上的包同形状),
# 经 file: 声明装进去 —— 走 bun install 的真实代码路径,但**不出网**。
# 它自己也声明 lifecycle scripts:一旦被执行就会留下 DEP_*_RAN 标记(下面断言它们不存在)。
DEPSRC="$BOX/dep-src"
mkdir -p "$DEPSRC/package"
cat > "$DEPSRC/package/package.json" <<'JSON'
{ "name": "a2-e2e-dep", "version": "1.0.0", "main": "index.js",
  "scripts": { "preinstall": "echo ran > DEP_PREINSTALL_RAN", "postinstall": "echo ran > DEP_POSTINSTALL_RAN" } }
JSON
cat > "$DEPSRC/package/index.js" <<'JS'
module.exports = { stamp: () => "a2-e2e-dep@1.0.0" };
JS

PLUGDIR="$WORKSPACE/reporter"
mkdir -p "$PLUGDIR"
tar -czf "$PLUGDIR/a2-e2e-dep-1.0.0.tgz" -C "$DEPSRC" package

# 插件目录自己的 package.json 也声明 lifecycle scripts —— 没有 --ignore-scripts 它们会在
# add 那一刻以用户身份执行(02 票 spike 实测的安全发现)。ROOT_*_RAN 标记即判据。
cat > "$PLUGDIR/package.json" <<'JSON'
{ "name": "reporter", "version": "1.0.0", "private": true, "type": "module",
  "scripts": { "preinstall": "echo ran > ROOT_PREINSTALL_RAN", "postinstall": "echo ran > ROOT_POSTINSTALL_RAN" },
  "dependencies": { "a2-e2e-dep": "file:./a2-e2e-dep-1.0.0.tgz" } }
JSON
cat > "$PLUGDIR/index.ts" <<'TS'
import dep from "a2-e2e-dep";
const TOOLS = [
  { name: "stamp", summary: "回报打进工件的依赖版本", dangerous: false,
    parameters: [{ name: "note", type: "string", required: false, description: "随手记" }] },
];
const mode = process.argv[2];
if (mode === "describe") {
  console.log(JSON.stringify({ protocol: 1, name: "reporter", tools: TOOLS }));
  process.exit(0);
}
if (mode === "call") {
  const req = JSON.parse(await Bun.stdin.text());
  console.log(JSON.stringify({ ok: true, output: {
    stamp: dep.stamp(),
    note: req.input.note ?? null,
    pid: process.pid,
    a2env: Object.keys(process.env).filter((k) => k.startsWith("A2_")),
  } }));
  process.exit(0);
}
process.exit(2);
TS

DEP_ADD_OUT="$(a2 plugin add "$PLUGDIR" --json 2>&1)"
DEP_ADD_RC=$?
assert_eq "$DEP_ADD_RC" "0" "6-1 目录插件 add 成功(内核自己 install + bundle,用户没跑过一条构建命令)"
[ "$DEP_ADD_RC" -eq 0 ] || { echo "$DEP_ADD_OUT" | head -20; }
DEP_ARTIFACT="$(printf '%s' "$DEP_ADD_OUT" | json_get result.plugin.artifact)"
assert_eq "$DEP_ARTIFACT" "$A2HOME/plugins/reporter.js" "6-2 登记的是**打出来的单文件 .js**(源目录入口是 .ts)"

# 登记区里只该有工件与清单:没有 node_modules、没有 lockfile、没有暂存件。
# 幕④ 已经把 notes 卸掉了,所以此刻登记区里应当只剩清单与刚打出来的这个工件。
REG_ENTRIES="$(ls -A "$A2HOME/plugins" | sort | tr '\n' ' ')"
assert_eq "$REG_ENTRIES" "plugins.json reporter.js " \
  "6-3 登记区里只有单文件工件与清单 —— 没有 node_modules、没有 lockfile、没有暂存件"

# 源目录一个字节都没被写:没有 node_modules,也没有 lifecycle 脚本留下的标记。
if [ -d "$PLUGDIR/node_modules" ]; then
  bad "6-4 内核往用户的源目录里装了 node_modules"
else
  ok "6-4 源目录没被写(装依赖全程在内核自己的临时工作区里)"
fi
RAN_MARKERS="$(ls -A "$PLUGDIR" | grep '_RAN$' | tr '\n' ' ')"
assert_eq "$RAN_MARKERS" "" "6-5 install 带 --ignore-scripts:插件目录**自己**的 preinstall/postinstall 一次都没跑"

DEP_CALL_OUT="$(a2 capabilities call plugin.reporter.stamp --input '{"note":"打进去了吗"}' --json 2>&1)"
assert_eq "$?" "0" "6-6 目录插件的工具经统一调用面调通"
assert_eq "$(printf '%s' "$DEP_CALL_OUT" | json_get result.output.stamp)" "a2-e2e-dep@1.0.0" \
  "6-7 依赖真的被内联进工件(结果里带着依赖自报的版本)"
assert_eq "$(printf '%s' "$DEP_CALL_OUT" | json_get result.output.a2env)" "[]" \
  "6-8 运行期无差别:与零依赖插件同一条路(照样一个 A2_* 都拿不到)"

# **离线证明**:源目录连同 tarball 整个删掉,再调一次。
rm -rf "$PLUGDIR"
OFFLINE_OUT="$(a2 capabilities call plugin.reporter.stamp --json 2>&1)"
assert_eq "$?" "0" "6-9 删掉整个源目录(含依赖 tarball)后照常可调 —— 运行期只依赖登记的那一个文件"
assert_eq "$(printf '%s' "$OFFLINE_OUT" | json_get result.output.stamp)" "a2-e2e-dep@1.0.0" \
  "6-10 而且行为一字不变"

# 审计:依赖清单与"脚本被拦"进了 plugin_added 事件(装载零闸下唯一的可审计物)。
assert_contains "$(cat "$AUDIT_LOG")" "a2-e2e-dep" "6-11 依赖清单进了审计事件"
assert_contains "$(cat "$AUDIT_LOG")" "--ignore-scripts" "6-12 「lifecycle scripts 被跳过」也留了痕"

# 打不进的怪包:native addon —— 产物不止一个文件即拒绝(判据是文件数,不是退出码)。
NATIVEDIR="$WORKSPACE/nativeplug"
mkdir -p "$NATIVEDIR"
echo 'NOT-A-REAL-NATIVE-ADDON —— 只为触发 bundler 对 .node 的处理路径。' > "$NATIVEDIR/fake.node"
cat > "$NATIVEDIR/package.json" <<'JSON'
{ "name": "nativeplug", "version": "1.0.0", "private": true, "type": "module" }
JSON
cat > "$NATIVEDIR/index.ts" <<'TS'
const addon = require("./fake.node");
console.log(JSON.stringify({ protocol: 1, tools: [
  { name: "x", summary: "x", dangerous: false, parameters: [] },
], addon: typeof addon }));
TS
NATIVE_OUT="$(a2 plugin add "$NATIVEDIR" --json 2>&1)"
assert_eq "$?" "5" "6-13 native addon 目录被拒(退出码 5)"
assert_contains "$NATIVE_OUT" "不是单文件插件" "6-14 拒因是「产物不止一个文件」(02 spike:.node 不会让 build 失败)"
assert_contains "$NATIVE_OUT" "native addon" "6-15 指引说清楚不支持什么、能怎么替代"
assert_not_contains "$(a2 capabilities list --json 2>&1)" "plugin.nativeplug" "6-16 被拒的插件一个字节都没登记"

# ---- ⑩ 红线自查 -----------------------------------------------------------------------
echo
echo "-- 红线自查"
if [ -e "$HOME/.a2" ]; then bad "R-1 真实 ~/.a2 出现了"; else ok "R-1 真实 ~/.a2 仍不存在"; fi
if grep -rq "33888" "$BOX/daemon.log" "$BOX/probe.log" 2>/dev/null; then
  bad "R-2 日志里出现了用户 mihomo 的端口"
else
  ok "R-2 全程没出现用户 mihomo 的端口(本票压根不碰数据面)"
fi
if [ -s "$BOX/supervisor-calls.log" ]; then
  FOREIGN_LABELS="$(grep -o 'com\.[a-z0-9.]*' "$BOX/supervisor-calls.log" 2>/dev/null | sort -u | grep -v '^com\.a2\.')"
  if [ -z "$FOREIGN_LABELS" ]; then
    ok "R-3 整场只对 com.a2.* 说过话"
  else
    bad "R-3 对非 com.a2.* 的 label 说过话:$FOREIGN_LABELS"
  fi
else
  ok "R-3 整场一次 supervisor 都没调用(本票不装任何服务)"
fi

echo
echo "========================================"
echo " 插件 e2e 结果: PASS=$PASS FAIL=$FAIL"
echo "========================================"
[ "$FAIL" -eq 0 ] || exit 1
