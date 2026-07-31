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
