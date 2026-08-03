# --- 锁版真 mihomo 内核 E2E：仅访问 localhost，绝不修改系统代理。---
echo "--- 断言组 MK:锁版真 mihomo 内核 E2E(仅 localhost,不碰系统代理)---"
REAL_KERNEL="$ROOT/Sources/PluginProxy/Resources/mihomo-darwin-arm64"
REAL_KERNEL_HOME="$BUILD/mihomo-real"
REAL_KERNEL_CONFIG="$REAL_KERNEL_HOME/config.yaml"
REAL_KERNEL_LOG="$REAL_KERNEL_HOME/kernel.log"
REAL_CONTROL_PORT=39090
REAL_MIXED_PORT=37890
mkdir -p "$REAL_KERNEL_HOME"

EXPECTED_SHA="55b7286331cb30a54b2564013b02b84a0c280e8b690bd1e5da4b9d4f4ca007ac"
ACTUAL_SHA="$(shasum -a 256 "$REAL_KERNEL" | awk '{print $1}')"
if [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ]; then
  echo "PASS: 锁版内核 SHA-256 与清单一致"; PASS=$((PASS+1))
else
  echo "FAIL: 锁版内核 SHA-256 不符(actual=$ACTUAL_SHA)"; FAIL=$((FAIL+1))
fi

cp "$ROOT/Sources/PluginProxy/Resources/default-config.yaml" "$REAL_KERNEL_CONFIG"
sed -i '' "s/mixed-port: 7890/mixed-port: $REAL_MIXED_PORT/" "$REAL_KERNEL_CONFIG"
sed -i '' "s/127.0.0.1:9090/127.0.0.1:$REAL_CONTROL_PORT/" "$REAL_KERNEL_CONFIG"

"$REAL_KERNEL" -t -d "$REAL_KERNEL_HOME" -f "$REAL_KERNEL_CONFIG" >"$REAL_KERNEL_LOG" 2>&1; RC=$?
assert_exit 0 "$RC" "锁版真 mihomo 接受最小配置"

"$REAL_KERNEL" -d "$REAL_KERNEL_HOME" -f "$REAL_KERNEL_CONFIG" >>"$REAL_KERNEL_LOG" 2>&1 &
REAL_KERNEL_PID=$!
REAL_READY=0
for _ in $(seq 1 100); do
  if ! kill -0 "$REAL_KERNEL_PID" 2>/dev/null; then break; fi
  VERSION_JSON="$(curl --silent --max-time 1 "http://127.0.0.1:$REAL_CONTROL_PORT/version" 2>/dev/null)"
  if printf '%s' "$VERSION_JSON" | grep -q 'version'; then REAL_READY=1; break; fi
  sleep 0.1
done
if [ "$REAL_READY" -eq 1 ]; then
  echo "PASS: 锁版真 mihomo 已启动且 REST /version 可达"; PASS=$((PASS+1))
  assert_contains "$VERSION_JSON" "1.19.28" "真内核报告锁定版本 1.19.28"
  CONFIG_JSON="$(curl --silent --max-time 1 "http://127.0.0.1:$REAL_CONTROL_PORT/configs" 2>/dev/null)"
  assert_contains "$CONFIG_JSON" "$REAL_MIXED_PORT" "真内核 /configs 报告预期 mixed-port"
else
  echo "FAIL: 锁版真 mihomo 未在时限内就绪"; FAIL=$((FAIL+1))
  sed 's/^/    /' "$REAL_KERNEL_LOG"
fi
kill "$REAL_KERNEL_PID" 2>/dev/null
wait "$REAL_KERNEL_PID" 2>/dev/null
if kill -0 "$REAL_KERNEL_PID" 2>/dev/null; then
  echo "FAIL: 锁版真 mihomo E2E 留下孤儿进程"; FAIL=$((FAIL+1))
else
  echo "PASS: 锁版真 mihomo E2E 已回收进程"; PASS=$((PASS+1))
fi

# 生产宿主全链：SystemProcessPort → 锁版资源 → REST → Registry → UDS → aa。
echo "--- 断言组 MK2:生产宿主 + 锁版真 mihomo 全链 E2E ---"
teardown_hosts also-stub
pkill -f "$PROD_HOST_BIN" 2>/dev/null
PROD_NET="$BUILD/mihomo-prod-netfake.json"
PROD_NET_BEFORE="$BUILD/mihomo-prod-netfake-before.json"
cp "$BUILD/netfake-initial.json" "$PROD_NET"
cp "$PROD_NET" "$PROD_NET_BEFORE"
PROD_DATA="$BUILD/mihomo-prod-data"
PROD_STATE="$BUILD/mihomo-prod-takeover.json"
PROD_SUBS="$BUILD/mihomo-prod-subs"
AA_MIHOMO_CONTROL_PORT=39092 \
AA_MIHOMO_DATA_DIR="$PROD_DATA" \
AA_NETWORKSETUP_FAKE_STATE="$PROD_NET" \
AA_TAKEOVER_STATE_PATH="$PROD_STATE" \
AA_SUBSCRIPTION_DIR="$PROD_SUBS" \
AA_CONFIRM_AUTO=approve \
"$PROD_HOST_BIN" >"$HOSTLOG" 2>&1 &
HOST_PID=$!
if wait_host_ready "$HOST_PID"; then
  # 就绪判据必须是 **apiReachable**,不能是 running —— 后者只说明「进程还活着」,内核拉起的那一刻就为真,
  #   于是下面三条断言会在内核 REST 起来之前就读到 {"apiReachable":false,"running":true} 而误判。
  # 11 票换 SPM 后这条竞态才暴露出来:此前生产宿主经 `#filePath` 直接跑 Sources/PluginProxy/Resources/ 里那份内核,
  #   而同一脚本上一段(锁版真内核 E2E)刚跑过它 —— 页缓存与首次执行校验都是热的,REST 几乎瞬时可达。
  #   现在跑的是 SPM 打进 PROJECT_AA_PluginProxy.bundle 的**新拷贝**(43MB,每轮门禁重建),冷启动实测约 0.4s,
  #   刚好落在旧判据的窗口外。窗口给到 30s(冷盘/高负载留余量),仍只是等待,不新增断言。
  PROD_STATUS=""
  for _ in $(seq 1 300); do
    PROD_STATUS="$("$BIN/aa" proxy status --json 2>/dev/null)"
    printf '%s' "$PROD_STATUS" | grep -q '"apiReachable":true' && break
    sleep 0.1
  done
  assert_contains "$PROD_STATUS" '"running":true' "生产宿主经 ProcessPort 拉起锁版真内核"
  assert_contains "$PROD_STATUS" '1.19.28' "aa proxy status 经 UDS/Registry 报告真内核版本"
  assert_contains "$PROD_STATUS" '"mixedPort":7890' "aa proxy status 报告真内核 mixed-port"
  assert_contains "$(cat "$HOSTLOG")" '生产构建不读取 AA_CONFIRM_AUTO' "生产宿主忽略 AA_CONFIRM_AUTO=approve"
  if cmp -s "$PROD_NET" "$PROD_NET_BEFORE"; then
    echo "PASS: 真核状态 E2E 未修改文件型系统代理后端"; PASS=$((PASS+1))
  else
    echo "FAIL: 真核状态 E2E 意外修改了系统代理 fake"; FAIL=$((FAIL+1))
  fi
  kill -USR1 "$HOST_PID" 2>/dev/null
  for _ in $(seq 1 100); do kill -0 "$HOST_PID" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$HOST_PID" 2>/dev/null; then
    echo "FAIL: 生产宿主未优雅退出"; FAIL=$((FAIL+1)); kill -TERM "$HOST_PID" 2>/dev/null
  else
    echo "PASS: 生产宿主已优雅退出"; PASS=$((PASS+1))
  fi
  if pgrep -f "$REAL_KERNEL" >/dev/null 2>&1; then
    echo "FAIL: 生产宿主退出后锁版真内核成为孤儿"; FAIL=$((FAIL+1)); pkill -TERM -f "$REAL_KERNEL" 2>/dev/null
  else
    echo "PASS: 生产宿主退出后锁版真内核已回收"; PASS=$((PASS+1))
  fi
else
  echo "FAIL: 生产宿主真核 E2E 未就绪"; FAIL=$((FAIL+1))
fi
