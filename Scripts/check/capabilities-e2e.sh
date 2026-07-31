# --- 断言组 2:list 纵切 E2E(aa capabilities list ⇄ 宿主 UDS)---
echo "--- 断言组 2:list E2E(起真宿主)---"
# 先清场:确保无旧宿主 / 旧 socket(轮询等真死 + 删残留,取代盲 sleep)
teardown_hosts

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

# 就绪等待(窗口 40s;区分启动即死 vs 起得慢,失败自带日志 dump)
wait_host_ready "$HOST_PID"

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

# 清场:杀宿主 + 删 socket(轮询等真死;trap 亦会兜底)
teardown_hosts

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
# 无内核/无接管:teardown_hosts 已清默认标记 → 启动自愈恒 clean → 快速就绪(dangerous E2E 不涉及接管)。
start_host_confirm() {
  local mode="$1"
  teardown_hosts
  AA_CONFIRM_AUTO="$mode" "$HOST_BIN" > "$HOSTLOG" 2>&1 &
  HOST_PID=$!
  disown "$HOST_PID" 2>/dev/null || true
  wait_host_ready "$HOST_PID"
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

# 清场:杀宿主 + 删 socket(轮询等真死;trap 亦兜底)
pkill -f "raw_uds_client.py" 2>/dev/null
teardown_hosts

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
teardown_hosts
