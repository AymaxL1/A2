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
