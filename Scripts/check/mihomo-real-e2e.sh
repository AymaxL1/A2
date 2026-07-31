# --- Pinned real mihomo kernel E2E. Localhost only; never changes system proxy. ---
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
