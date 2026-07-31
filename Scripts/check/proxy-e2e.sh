# --- 断言组 P:proxy.status 内核生命周期 E2E(06 票主体:真子进程 fake mihomo stub + 真 localhost REST)---
echo "--- 断言组 P:proxy.status 内核生命周期 E2E(06 票)---"
chmod +x "$STUB" 2>/dev/null
# 由 OS 分配一个空闲高位端口(避开常用端口 / 撞端口),交给内核 stub 监听、RESTClient 连接。
MIHOMO_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null)"
[ -z "$MIHOMO_PORT" ] && MIHOMO_PORT=48123
echo "    fake mihomo 控制端口 = $MIHOMO_PORT"

# 起宿主并注入内核 env:AA_MIHOMO_KERNEL_PATH → stub;AA_MIHOMO_CONTROL_PORT → 空闲端口。置全局 HOST_PID/SOCK_UP。
# teardown_hosts also-stub 已清默认标记 → 启动自愈恒 clean → 快速就绪(P/CP 场景不预置接管态)。
start_host_kernel() {
  teardown_hosts also-stub
  AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT" "$HOST_BIN" > "$HOSTLOG" 2>&1 &
  HOST_PID=$!
  disown "$HOST_PID" 2>/dev/null || true
  wait_host_ready "$HOST_PID"
}

# —— 场景 A:健康检查 + status 真实呈现(内核存活→反映真实;内核死亡→如实未运行且退出码 0)——
start_host_kernel
if [ "$SOCK_UP" -eq 1 ]; then
  # 等内核 REST 就绪(宿主拉起 stub、stub 绑定端口需一瞬):poll 直到 running:true(上限 ~10s)
  READY=0
  for _ in $(seq 1 50); do
    # 等 REST 真就绪(apiReachable:true),而非仅进程存活(running:true 在拉起瞬间即真、但 stub 尚未绑定端口)。
    if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then READY=1; break; fi
    sleep 0.2
  done
  if [ "$READY" -eq 1 ]; then
    echo "PASS: 宿主经 ProcessPort 拉起 fake mihomo,REST 就绪(随宿主启停)"; PASS=$((PASS+1))
  else
    echo "FAIL: 内核 REST 未在时限内就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
  fi

  # (P1) aa proxy status --json:退出 0 + 真实(stub)状态(running/端口/mode/节点),经真 localhost REST 读取
  SP="$("$BIN/aa" proxy status --json 2>/dev/null)"; PRC=$?
  echo "    aa proxy status(内核存活)输出: $SP"
  assert_exit 0 $PRC "aa proxy status --json(内核存活)退出码=0"
  assert_contains "$SP" '"running":true' "proxy status 反映内核存活(running=true)"
  assert_contains "$SP" '"mode":"rule"' "proxy status 经真 REST 反映真实模式(mode=rule)"
  assert_contains "$SP" '"mixedPort":7890' "proxy status 反映监听端口(mixedPort=7890)"
  assert_contains "$SP" '"node":"STUB-NODE"' "proxy status 反映当前节点(node=STUB-NODE)"

  # (P1b) 域子命令 ≡ capabilities call 底座:两种入口结果一致
  CP="$("$BIN/aa" capabilities call proxy.status --json 2>/dev/null)"; CPRC=$?
  assert_exit 0 $CPRC "capabilities call proxy.status --json 退出码=0"
  if [ "$SP" = "$CP" ] && [ -n "$SP" ]; then
    echo "PASS: 域子命令 aa proxy status ≡ capabilities call proxy.status 逐字节一致"; PASS=$((PASS+1))
  else
    echo "FAIL: proxy 域子命令与 call 底座输出不一致(域='$SP' vs call='$CP')"; FAIL=$((FAIL+1))
  fi

  # (P2) 健康检查:杀内核(stub)但宿主仍活 → 死亡可检测 → status 如实未运行、退出码 0(非报错)
  pkill -f "$KILLPAT_STUB" 2>/dev/null
  sleep 2
  SD="$("$BIN/aa" proxy status --json 2>/dev/null)"; DRC=$?
  echo "    aa proxy status(内核已死)输出: $SD"
  assert_exit 0 $DRC "内核死亡后 aa proxy status --json 退出码=0(如实呈现,非报错/非零)"
  assert_contains "$SD" '"running":false' "健康检查:内核死亡可检测,status 反映真实存活(running=false)"
else
  echo "FAIL: proxy 场景A 宿主未就绪(socket_up=$SOCK_UP)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# —— 场景 B:反孤儿(宿主退出必回收内核,零孤儿 stub)——
start_host_kernel
if [ "$SOCK_UP" -eq 1 ]; then
  READY=0
  for _ in $(seq 1 50); do
    # 等 REST 真就绪(apiReachable:true),而非仅进程存活(running:true 在拉起瞬间即真、但 stub 尚未绑定端口)。
    if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then READY=1; break; fi
    sleep 0.2
  done
  STUB_PIDS="$(pgrep -f "$KILLPAT_STUB")"
  echo "    场景B:宿主拉起的 fake mihomo pid(s)=[$STUB_PIDS]"
  if [ -n "$STUB_PIDS" ]; then
    echo "PASS: 宿主经 ProcessPort 拉起了 fake mihomo 子进程(pid: $STUB_PIDS)"; PASS=$((PASS+1))
  else
    echo "FAIL: 宿主未拉起 fake mihomo 子进程。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
  fi
  # 只杀宿主(SIGTERM,模拟宿主退出)——绝不直接碰 stub;stub 应被宿主退出钩子(atexit/信号)回收。
  pkill -f "$KILLPAT" 2>/dev/null
  sleep 2
  LEFT="$(pgrep -f "$KILLPAT_STUB")"
  if [ -z "$LEFT" ]; then
    echo "PASS: 宿主退出后无孤儿 fake mihomo 进程(反孤儿回收生效,零孤儿)"; PASS=$((PASS+1))
  else
    echo "FAIL: 宿主退出后仍有孤儿 stub 进程: $LEFT"; FAIL=$((FAIL+1)); pkill -9 -f "$KILLPAT_STUB" 2>/dev/null
  fi
else
  echo "FAIL: proxy 场景B 宿主未就绪(socket_up=$SOCK_UP)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# 清场:杀宿主 + stub(轮询等真死;trap 亦兜底)
teardown_hosts also-stub

# —— 场景 C:SIGTERM-忽略型内核经 terminate 仍被 SIGKILL 兜底回收(暴露"发完 SIGTERM 立刻 unrecord"的孤儿洞)——
# 内核以 --ignore-sigterm 运行(装 handler 吞掉 SIGTERM);宿主收 SIGUSR1 → 优雅退出 → reclaimKernel →
# ProcessPort.terminate:SIGTERM 被忽略 → 有界等待后 SIGKILL 兜底 → 内核被回收。旧 bug(发完 SIGTERM 立刻 unrecord)
# 会让该内核既不被 terminate 的 SIGKILL 兜到(未升级)、又从缓冲摘除(退出钩子够不着)→ 孤儿。修后必被回收、无孤儿。
echo "--- 断言组 P-C:SIGTERM-忽略型内核的 terminate SIGKILL 兜底 ---"
teardown_hosts also-stub
AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT" AA_MIHOMO_KERNEL_EXTRA_ARGS="--ignore-sigterm" \
  "$HOST_BIN" > "$HOSTLOG" 2>&1 &
HOST_PID=$!
disown "$HOST_PID" 2>/dev/null || true
wait_host_ready "$HOST_PID"
if [ "$SOCK_UP" -eq 1 ]; then
  READY=0
  for _ in $(seq 1 50); do
    if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then READY=1; break; fi
    sleep 0.2
  done
  STUB_PIDS="$(pgrep -f "$KILLPAT_STUB")"
  echo "    场景C:SIGTERM-忽略型内核 pid(s)=[$STUB_PIDS]"
  if [ -n "$STUB_PIDS" ]; then
    echo "PASS: 宿主拉起 SIGTERM-忽略型 fake mihomo(REST 就绪)"; PASS=$((PASS+1))
  else
    echo "FAIL: 未拉起 SIGTERM-忽略型 stub。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
  fi
  # 触发宿主优雅退出(SIGUSR1)→ 走 applicationWillTerminate → reclaimKernel → ProcessPort.terminate 完整回收路径。
  kill -USR1 "$HOST_PID" 2>/dev/null
  # terminate:SIGTERM(被忽略)→ ~1.5s 有界等待 → SIGKILL 兜底 → 回收;再加宿主退出时间。给足 6s。
  sleep 6
  LEFTC="$(pgrep -f "$KILLPAT_STUB")"
  if [ -z "$LEFTC" ]; then
    echo "PASS: SIGTERM-忽略型内核经 terminate 被 SIGKILL 兜底回收,无孤儿(反孤儿兜底真生效)"; PASS=$((PASS+1))
  else
    echo "FAIL: SIGTERM-忽略型内核成孤儿(terminate 兜底失效): $LEFTC"; FAIL=$((FAIL+1)); pkill -9 -f "$KILLPAT_STUB" 2>/dev/null
  fi
  if kill -0 "$HOST_PID" 2>/dev/null; then
    echo "FAIL: 宿主收 SIGUSR1 后未退出"; FAIL=$((FAIL+1)); pkill -f "$KILLPAT" 2>/dev/null
  else
    echo "PASS: 宿主经 SIGUSR1 优雅退出(走完 terminate 回收路径)"; PASS=$((PASS+1))
  fi
else
  echo "FAIL: proxy 场景C 宿主未就绪(socket_up=$SOCK_UP)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# 清场:杀宿主 + stub(轮询等真死;trap 亦兜底)
teardown_hosts also-stub

# --- 断言组 CP:控制面能力包 E2E(09 票主体:有状态 fake stub「改后读回」+ 逐节点测速 + normal 零 GUI + number 强转)---
# 姿态:start_host_kernel 起「宿主 + 有状态 fake mihomo stub」;**不设 AA_CONFIRM_AUTO**——mode.set/node.select 为 normal,
#   若误走 dangerous 确认会在 headless 挂起(→ 客户端超时退出码3);它们快速退出码0 即证明「normal 零 GUI 确认」。
#   CP 四能力只经 RESTClient 读/写内核,绝不触达 networksetup(真件被注入但从不被调用),不碰真系统。
echo "--- 断言组 CP:控制面能力包 E2E(09 票:模式/节点/组/测速,改后读回)---"
start_host_kernel
if [ "$SOCK_UP" -eq 1 ]; then
  READY=0
  for _ in $(seq 1 50); do
    if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then READY=1; break; fi
    sleep 0.2
  done
  if [ "$READY" -eq 1 ]; then echo "PASS: CP 内核 REST 就绪(控制面可读写)"; PASS=$((PASS+1)); else echo "FAIL: CP 内核 REST 未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1)); fi

  # (CP0) 元数据:四能力风险级 + cliAlias + allowedValues(经 wire 下发,读=safe / 改状态=normal)。
  DGL="$("$BIN/aa" capabilities describe proxy.groups.list --json 2>/dev/null)"
  assert_contains "$DGL" '"risk":"safe"' "CP0 proxy.groups.list 风险档=safe(只读)"
  assert_contains "$DGL" '"cliAlias":["proxy","groups"]' "CP0 proxy.groups.list cliAlias=[proxy,groups]"
  DLT="$("$BIN/aa" capabilities describe proxy.latency.test --json 2>/dev/null)"
  assert_contains "$DLT" '"risk":"safe"' "CP0 proxy.latency.test 风险档=safe(只读)"
  assert_contains "$DLT" '"cliAlias":["proxy","ping"]' "CP0 proxy.latency.test cliAlias=[proxy,ping]"
  assert_contains "$DLT" '"name":"timeout"' "CP0 proxy.latency.test 声明 timeout 参数(number 强转基石)"
  DMS="$("$BIN/aa" capabilities describe proxy.mode.set --json 2>/dev/null)"
  assert_contains "$DMS" '"risk":"normal"' "CP0 proxy.mode.set 风险档=normal(改状态,零 GUI 确认)"
  assert_contains "$DMS" '"cliAlias":["proxy","mode"]' "CP0 proxy.mode.set cliAlias=[proxy,mode]"
  assert_contains "$DMS" '"allowedValues":["rule","global","direct"]' "CP0 proxy.mode.set 描述含 allowedValues(agent 可知合法取值)"
  DNS="$("$BIN/aa" capabilities describe proxy.node.select --json 2>/dev/null)"
  assert_contains "$DNS" '"risk":"normal"' "CP0 proxy.node.select 风险档=normal(改状态,零 GUI 确认)"
  assert_contains "$DNS" '"cliAlias":["proxy","node"]' "CP0 proxy.node.select cliAlias=[proxy,node]"

  # (CP1) aa proxy groups(别名→proxy.groups.list):列出组/候选/当前选中(now)。
  GRP="$("$BIN/aa" proxy groups --json 2>/dev/null)"; GRPRC=$?
  echo "    aa proxy groups 输出: $GRP"
  assert_exit 0 $GRPRC "aa proxy groups(safe)退出码=0"
  assert_contains "$GRP" '"name":"PROXY"' "CP1 groups 列出分组 PROXY"
  assert_contains "$GRP" '"now":"STUB-NODE"' "CP1 groups 反映当前选中 now=STUB-NODE(初始)"
  assert_contains "$GRP" '"all":["STUB-NODE","NODE-B","SLOW-NODE"]' "CP1 groups 列出该组候选节点"

  # (CP2) aa proxy mode --mode global(别名→proxy.mode.set,normal,不设 AA_CONFIRM_AUTO 仍不挂):退出0 → 经 status 读回 mode==global(生效)。
  MSET="$("$BIN/aa" proxy mode --mode global --json 2>/dev/null)"; MSRC=$?
  echo "    aa proxy mode --mode global 输出: $MSET"
  assert_exit 0 $MSRC "aa proxy mode --mode global(normal)退出码=0(零 GUI 确认,不阻塞/不超时)"
  assert_contains "$MSET" '"set":true' "CP2 mode.set 报告已切换(set=true)"
  MRB="$("$BIN/aa" proxy status --json 2>/dev/null)"
  echo "    切模式后 proxy status 读回: $MRB"
  assert_contains "$MRB" '"mode":"global"' "CP2 改后读回:proxy.status 反映 mode==global(经 REST 读回,生效)"

  # (CP2b) 取值域约束:aa proxy mode --mode bogus → invalid_params(退出码6);内核状态不被改动(仍 global)。
  MBAD="$("$BIN/aa" proxy mode --mode bogus --json 2>/dev/null)"; MBRC=$?
  echo "    aa proxy mode --mode bogus 输出: $MBAD"
  assert_exit 6 $MBRC "CP2b mode.set 非法取值(bogus,不在 allowedValues)→ 退出码=6"
  assert_contains "$MBAD" '"code":"invalid_params"' "CP2b 非法取值走统一错误信封 error.code=invalid_params"
  MRB2="$("$BIN/aa" proxy status --json 2>/dev/null)"
  assert_contains "$MRB2" '"mode":"global"' "CP2b 非法取值被校验层拦下,未触达内核(mode 仍 global)"

  # (CP3) aa proxy node --group PROXY --node NODE-B(别名→proxy.node.select,normal):退出0 → 经 groups/status 读回该组 now==NODE-B。
  NSEL="$("$BIN/aa" proxy node --group PROXY --node NODE-B --json 2>/dev/null)"; NSRC=$?
  echo "    aa proxy node --group PROXY --node NODE-B 输出: $NSEL"
  assert_exit 0 $NSRC "aa proxy node(normal)退出码=0(零 GUI 确认,不阻塞/不超时)"
  assert_contains "$NSEL" '"selected":true' "CP3 node.select 报告已选中(selected=true)"
  GRB="$("$BIN/aa" proxy groups --json 2>/dev/null)"
  echo "    选节点后 aa proxy groups 读回: $GRB"
  assert_contains "$GRB" '"now":"NODE-B"' "CP3 改后读回:proxy.groups.list 反映 PROXY now==NODE-B(生效)"
  SRB="$("$BIN/aa" proxy status --json 2>/dev/null)"
  assert_contains "$SRB" '"node":"NODE-B"' "CP3 改后读回:proxy.status 反映当前节点==NODE-B(经 REST 读回)"

  # (CP4) aa proxy ping --group PROXY(别名→proxy.latency.test,safe):返回逐节点延迟,超时节点如实标注。
  PING="$("$BIN/aa" proxy ping --group PROXY --json 2>/dev/null)"; PINGRC=$?
  echo "    aa proxy ping --group PROXY 输出: $PING"
  assert_exit 0 $PINGRC "aa proxy ping(safe)退出码=0"
  assert_contains "$PING" '"delayMs":120,"node":"STUB-NODE"' "CP4 测速:逐节点延迟(STUB-NODE=120ms)"
  assert_contains "$PING" '"node":"SLOW-NODE","timeout":true' "CP4 测速:超时节点如实标注(SLOW-NODE timeout=true)"
  assert_contains "$PING" '"delayMs":null,"node":"SLOW-NODE"' "CP4 测速:超时节点 delayMs=null(不臆造 0)"

  # (CP5) number 参数强转 E2E(补 05 缺口):--timeout 5000 正确强转为 number;--timeout inf/nan → 退出码1(isFinite 钳制首次真被行使)。
  PT="$("$BIN/aa" proxy ping --group PROXY --timeout 5000 --json 2>/dev/null)"; PTRC=$?
  assert_exit 0 $PTRC "CP5 aa proxy ping --timeout 5000(number 强转正确)退出码=0"
  assert_contains "$PT" '"node":"STUB-NODE"' "CP5 --timeout 5000 强转成功、正常返回测速结果"
  "$BIN/aa" proxy ping --group PROXY --timeout inf --json >/dev/null 2>&1; PIRC=$?
  assert_exit 1 $PIRC "CP5 aa proxy ping --timeout inf → 退出码=1(非有限 number 被 isFinite 钳制)"
  "$BIN/aa" proxy ping --group PROXY --timeout nan --json >/dev/null 2>&1; PNRC=$?
  assert_exit 1 $PNRC "CP5 aa proxy ping --timeout nan → 退出码=1(非有限 number 被 isFinite 钳制)"

  # (CP5b) 宿主侧越界防呆(修 Int(Double) trap DoS 洞):经 capabilities call --input 原样 JSON(绕过 CLI 强转,直击宿主 handler)
  #   传超大**有限** timeout=1e300(CLI 只钳 isFinite、不钳范围,故此洞在宿主侧)→ 宿主**不崩**、返回 invalid_params(退出码6)。
  OVF="$("$BIN/aa" capabilities call proxy.latency.test --input '{"group":"PROXY","timeout":1e300}' --json 2>/dev/null)"; OVFRC=$?
  echo "    超大 timeout(1e300)输出: $OVF"
  assert_exit 6 $OVFRC "CP5b 超大有限 timeout(1e300)→ 退出码=6(宿主侧越界防呆,非 Int(Double) trap 崩)"
  assert_contains "$OVF" '"code":"invalid_params"' "CP5b 越界 timeout 返回 invalid_params(而非崩宿主)"
  # 反证宿主仍活:随后再发正常请求应成功(证明宿主没被这次越界请求 DoS 崩)。
  ALIVE="$("$BIN/aa" proxy status --json 2>/dev/null)"; ALIVERC=$?
  assert_exit 0 $ALIVERC "CP5b 越界请求后宿主仍存活(status 退出码=0,未被 DoS 崩溃)"
  assert_contains "$ALIVE" '"running":true' "CP5b 越界请求后宿主仍正常服务(running=true)"

  # (CP6) 别名 ≡ call 底座:aa proxy groups ≡ capabilities call proxy.groups.list(同路由同输出)。
  CG="$("$BIN/aa" capabilities call proxy.groups.list --json 2>/dev/null)"; CGRC=$?
  assert_exit 0 $CGRC "CP6 capabilities call proxy.groups.list 退出码=0"
  if [ "$GRB" = "$CG" ] && [ -n "$CG" ]; then echo "PASS: CP6 aa proxy groups ≡ capabilities call proxy.groups.list 逐字节一致(别名同底座)"; PASS=$((PASS+1)); else echo "FAIL: CP6 别名与 call 输出不一致(alias='$GRB' vs call='$CG')"; FAIL=$((FAIL+1)); fi
else
  echo "FAIL: CP 宿主未就绪(socket_up=$SOCK_UP)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# 清场:杀宿主 + stub(轮询等真死;trap 亦兜底)
teardown_hosts also-stub

# --- 断言组 SP:系统代理接管/还原 E2E(07 票主体:文件后端假 NetworkConfigPort + fake mihomo stub,绝不碰真 networksetup)---
# 姿态:宿主经 env(AA_NETWORKSETUP_FAKE_STATE)注入文件后端假 NetworkConfigPort,读写 $BUILD 下的 JSON 状态文件;
#   check.sh 据该文件断言「接管指向内核 mixed-port / 精确还原(含原第三方代理)/ 宿主正常退出后复原」。
#   宿主**不设 AA_CONFIRM_AUTO**——enable/disable 为 normal,若误走 dangerous 确认会在 headless 挂起(超时退出码3);
#   它们快速退出码0 即证明 normal 零确认(不弹窗、不阻塞)。绝不设置真 networksetup。
echo "--- 断言组 SP:系统代理接管/还原 E2E(07 票)---"
teardown_hosts also-stub

# 假 networksetup 初始状态(接管前快照):Wi-Fi 全关;Ethernet 原本就有第三方代理(HTTP/HTTPS→203.0.113.9:8080,SOCKS 关)。
NETFAKE="$BUILD/netfake-state.json"
cat > "$NETFAKE" <<'JSON'
{"services":[
{"service":"Wi-Fi","http":{"enabled":false,"host":"","port":0},"https":{"enabled":false,"host":"","port":0},"socks":{"enabled":false,"host":"","port":0}},
{"service":"Ethernet","http":{"enabled":true,"host":"203.0.113.9","port":8080},"https":{"enabled":true,"host":"203.0.113.9","port":8080},"socks":{"enabled":false,"host":"","port":0}}
]}
JSON
# 留一份接管前初始快照的规整副本,供「终态=接管前快照」语义对比(经 python 归一,忽略键序/空白)。
python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2],"w"), sort_keys=True)' "$NETFAKE" "$BUILD/netfake-initial.json" 2>/dev/null

# 起宿主:内核 stub + 文件后端假 NetworkConfigPort(env 注入),不设 AA_CONFIRM_AUTO。
AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT" AA_NETWORKSETUP_FAKE_STATE="$NETFAKE" \
  "$HOST_BIN" > "$HOSTLOG" 2>&1 &
HOST_PID=$!
disown "$HOST_PID" 2>/dev/null || true
wait_host_ready "$HOST_PID"

# 语义对比助手:比较状态文件与接管前初始快照是否等价(python 归一)。
netfake_equals_initial() {
  python3 -c 'import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
sys.exit(0 if a==b else 1)' "$NETFAKE" "$BUILD/netfake-initial.json" 2>/dev/null
}

if [ "$SOCK_UP" -eq 1 ]; then
  # 等内核 REST 就绪(enable 要经 REST 读 mixed-port)。
  READY=0
  for _ in $(seq 1 50); do
    if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then READY=1; break; fi
    sleep 0.2
  done
  if [ "$READY" -eq 1 ]; then echo "PASS: SP 内核 REST 就绪(enable 可读 mixed-port)"; PASS=$((PASS+1)); else echo "FAIL: SP 内核 REST 未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1)); fi

  # (SP0) 元数据:enable/disable 为 normal(→零 GUI 确认)且各带 cliAlias(经 wire 下发,别名解析基石)。
  DEN="$("$BIN/aa" capabilities describe proxy.system.enable --json 2>/dev/null)"; DENRC=$?
  echo "    describe proxy.system.enable: $DEN"
  assert_exit 0 $DENRC "describe proxy.system.enable 退出码=0"
  assert_contains "$DEN" '"risk":"normal"' "proxy.system.enable 风险档=normal(→ 零 GUI 确认,safe/normal 直通)"
  assert_contains "$DEN" '"cliAlias":["proxy","on"]' "proxy.system.enable 声明 cliAlias=[proxy,on](经 wire 下发)"
  DDIS="$("$BIN/aa" capabilities describe proxy.system.disable --json 2>/dev/null)"
  assert_contains "$DDIS" '"risk":"normal"' "proxy.system.disable 风险档=normal(→ 零 GUI 确认)"
  assert_contains "$DDIS" '"cliAlias":["proxy","off"]' "proxy.system.disable 声明 cliAlias=[proxy,off]"

  # (SP1) aa proxy on(别名→proxy.system.enable):退出0(normal 零确认,未设 AA_CONFIRM_AUTO 仍不挂)+ 接管成功。
  ON1="$("$BIN/aa" proxy on --json 2>/dev/null)"; ONRC=$?
  echo "    aa proxy on 输出: $ON1"
  assert_exit 0 $ONRC "aa proxy on(别名→proxy.system.enable,normal)退出码=0(零 GUI 确认,不阻塞/不超时)"
  assert_contains "$ON1" '"enabled":true' "aa proxy on 结果 enabled=true(接管成功)"
  assert_contains "$ON1" '"port":7890' "aa proxy on 指向内核 mixed-port 7890(端口复用 06 RESTClient)"

  # (SP2) 断言假 networksetup 各服务 HTTP/HTTPS/SOCKS 均指向 127.0.0.1:7890(读状态文件,绝不碰真设置)。
  echo "    接管后假 networksetup: $(cat "$NETFAKE")"
  ON_COUNT="$(grep -o '"enabled":true,"host":"127.0.0.1","port":7890' "$NETFAKE" | wc -l | tr -d ' ')"
  if [ "$ON_COUNT" -eq 6 ]; then echo "PASS: 接管后 2 服务×3 类代理均指向 127.0.0.1:7890(6/6,含原关闭的 Wi-Fi/SOCKS)"; PASS=$((PASS+1)); else echo "FAIL: 接管后指向内核端口的项应为6,实际 $ON_COUNT。文件: $(cat "$NETFAKE")"; FAIL=$((FAIL+1)); fi
  if grep -qF '203.0.113.9' "$NETFAKE"; then echo "FAIL: 接管后仍残留第三方代理 203.0.113.9(未被接管覆盖)"; FAIL=$((FAIL+1)); else echo "PASS: 接管后原第三方代理被内核端口覆盖(接管彻底)"; PASS=$((PASS+1)); fi

  # (SP3) 别名 ≡ call:aa proxy on ≡ capabilities call proxy.system.enable(幂等 enable → 逐字节一致、同退出码0)。
  ON2="$("$BIN/aa" capabilities call proxy.system.enable --json 2>/dev/null)"; ON2RC=$?
  assert_exit 0 $ON2RC "capabilities call proxy.system.enable 退出码=0"
  if [ "$ON1" = "$ON2" ] && [ -n "$ON1" ]; then echo "PASS: aa proxy on ≡ capabilities call proxy.system.enable 逐字节一致(别名同路由同底座)"; PASS=$((PASS+1)); else echo "FAIL: 别名与 call 输出不一致(alias='$ON1' vs call='$ON2')"; FAIL=$((FAIL+1)); fi

  # (SP3b) 06 的 id 映射与 07 的别名共存:aa proxy status(id 映射)仍可用。
  SPST="$("$BIN/aa" proxy status --json 2>/dev/null)"; SPSTRC=$?
  assert_exit 0 $SPSTRC "aa proxy status(06 id 映射)仍退出码=0(与别名共存)"
  assert_contains "$SPST" '"running":true' "aa proxy status 仍反映内核存活(id 映射与 cliAlias 别名并存)"

  # (SP4) aa proxy off(别名→proxy.system.disable):退出0 + 精确还原(含原第三方代理)。
  OFF1="$("$BIN/aa" proxy off --json 2>/dev/null)"; OFFRC=$?
  echo "    aa proxy off 输出: $OFF1 | 还原后假 networksetup: $(cat "$NETFAKE")"
  assert_exit 0 $OFFRC "aa proxy off(别名→proxy.system.disable,normal)退出码=0(零 GUI 确认)"
  assert_contains "$OFF1" '"restored":true' "aa proxy off 报告已还原(restored=true)"
  if grep -qF '"enabled":true,"host":"203.0.113.9","port":8080' "$NETFAKE"; then echo "PASS: 还原后 Ethernet 精确回到第三方代理 203.0.113.9:8080(非一律关闭)"; PASS=$((PASS+1)); else echo "FAIL: 还原未精确回到第三方代理。文件: $(cat "$NETFAKE")"; FAIL=$((FAIL+1)); fi
  if grep -qF '127.0.0.1' "$NETFAKE"; then echo "FAIL: 还原后仍残留内核端口 127.0.0.1(接管痕迹未清)"; FAIL=$((FAIL+1)); else echo "PASS: 还原后无内核端口残留(接管痕迹已清)"; PASS=$((PASS+1)); fi
  if netfake_equals_initial; then echo "PASS: aa proxy off 后假 networksetup 终态=接管前快照(精确复原)"; PASS=$((PASS+1)); else echo "FAIL: aa proxy off 后终态≠接管前快照。终态: $(cat "$NETFAKE")"; FAIL=$((FAIL+1)); fi

  # (SP5) 宿主正常退出还原:重新接管 → SIGUSR1 优雅退出 → applicationWillTerminate 先还原代理再停内核。
  "$BIN/aa" proxy on --json >/dev/null 2>&1; RC=$?
  assert_exit 0 $RC "SP5 前置:重新 aa proxy on 退出码=0"
  if grep -qF '127.0.0.1' "$NETFAKE"; then echo "PASS: SP5 前置接管生效(文件含内核端口 127.0.0.1)"; PASS=$((PASS+1)); else echo "FAIL: SP5 前置接管未生效"; FAIL=$((FAIL+1)); fi
  STUB_BEFORE="$(pgrep -f "$KILLPAT_STUB")"
  echo "    SP5:退出前 fake mihomo pid(s)=[$STUB_BEFORE]"
  kill -USR1 "$HOST_PID" 2>/dev/null
  sleep 5
  # 退出后①:假 networksetup 终态=接管前初始快照(退出即复原,网络立即直连)。
  if netfake_equals_initial; then echo "PASS: 宿主正常退出后假 networksetup 终态=接管前快照(已复原,退出后直连)"; PASS=$((PASS+1)); else echo "FAIL: 宿主退出后假 networksetup 未复原到接管前快照。终态: $(cat "$NETFAKE")"; FAIL=$((FAIL+1)); fi
  # 退出后②:内核已停(先还原代理→再停内核 顺序生效),无孤儿 stub。
  LEFTSP="$(pgrep -f "$KILLPAT_STUB")"
  if [ -z "$LEFTSP" ]; then echo "PASS: 宿主正常退出后内核已停、无孤儿(还原代理→停内核 顺序生效)"; PASS=$((PASS+1)); else echo "FAIL: 宿主退出后仍有孤儿 stub: $LEFTSP"; FAIL=$((FAIL+1)); pkill -9 -f "$KILLPAT_STUB" 2>/dev/null; fi
  # 退出后③:宿主进程已退出。
  if kill -0 "$HOST_PID" 2>/dev/null; then echo "FAIL: 宿主收 SIGUSR1 后未退出"; FAIL=$((FAIL+1)); pkill -f "$KILLPAT" 2>/dev/null; else echo "PASS: 宿主经 SIGUSR1 优雅退出(走完 还原代理→停内核 路径)"; PASS=$((PASS+1)); fi
else
  echo "FAIL: SP 宿主未就绪(socket_up=$SOCK_UP)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi

# 清场:杀宿主 + stub(轮询等真死;trap 亦兜底)
teardown_hosts also-stub

# --- 断言组 SH:崩溃自愈 E2E(08 票主体:文件后端假 NetworkConfigPort + fake stub + 持久化临时区,kill -9 剧本,绝不碰真系统)---
# 姿态:整条剧本用 kill -9 强杀宿主(atexit/信号退出钩子**都不跑**)——留下「代理指向死端口 + 持久化接管态标记 + 孤儿内核」。
#   重启宿主 → 启动早期自愈跑一次:reap 上世代孤儿内核 → 恢复接管(重启内核+重指存活端口)或还原快照(降级直连)或
#   (用户改过)只清标记。**硬不变式**:任一自愈路径后系统代理都不指向死端口。持久化写 $BUILD 临时区(per-launch env),绝不碰真 AppSupport。
echo "--- 断言组 SH:崩溃自愈 E2E(08 票 kill -9 剧本)---"
teardown_hosts also-stub

SHNET="$BUILD/selfheal-netfake.json"
SHSTATE="$BUILD/selfheal-takeover.json"

# 接管前初始快照(Wi-Fi 全关;Ethernet 原第三方代理 203.0.113.9:8080,SOCKS 关)—— 证明还原精确、非一律关闭。
write_shnet_initial() {
cat > "$SHNET" <<'JSON'
{"services":[
{"service":"Wi-Fi","http":{"enabled":false,"host":"","port":0},"https":{"enabled":false,"host":"","port":0},"socks":{"enabled":false,"host":"","port":0}},
{"service":"Ethernet","http":{"enabled":true,"host":"203.0.113.9","port":8080},"https":{"enabled":true,"host":"203.0.113.9","port":8080},"socks":{"enabled":false,"host":"","port":0}}
]}
JSON
python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2],"w"), sort_keys=True)' "$SHNET" "$BUILD/selfheal-initial.json" 2>/dev/null
}
shnet_equals_initial() {
python3 -c 'import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
sys.exit(0 if a==b else 1)' "$SHNET" "$BUILD/selfheal-initial.json" 2>/dev/null
}

# 建立「一个崩溃世代」:起宿主(内核 stub + 假网络 + 独立持久化文件)→ 等 REST 就绪 → proxy on 接管 →
#   捕获内核 stub pid 为 $ORPHAN_PID → kill -9 宿主(退出钩子不跑)。留:代理指向死端口 + 持久化标记 + 孤儿内核。返回非 0 表示前置失败。
crash_generation() {
  teardown_hosts also-stub          # 轮询等上一剧本宿主真死 + 清默认标记(本剧本用独立 $SHSTATE,不受影响)
  write_shnet_initial
  rm -f "$SHSTATE"
  AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT" AA_NETWORKSETUP_FAKE_STATE="$SHNET" \
    AA_TAKEOVER_STATE_PATH="$SHSTATE" "$HOST_BIN" > "$HOSTLOG" 2>&1 &
  HOST_PID=$!
  disown "$HOST_PID" 2>/dev/null || true
  wait_host_ready "$HOST_PID" || true
  [ "$SOCK_UP" -eq 1 ] || return 1
  READY=0
  for _ in $(seq 1 50); do
    if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then READY=1; break; fi
    sleep 0.2
  done
  [ "$READY" -eq 1 ] || return 1
  "$BIN/aa" proxy on --json >/dev/null 2>&1 || return 1
  ORPHAN_PID="$(pgrep -f "$KILLPAT_STUB" | head -1)"
  kill -9 "$HOST_PID" 2>/dev/null   # SIGKILL:atexit/信号钩子都不跑 → 孤儿内核 stub 被 launchd 收养、仍存活
  sleep 2
  rm -f "$SOCK"                     # 清 kill -9 遗留的陈旧 socket 文件(避免下次启动的就绪探测假阳)
  return 0
}

# 起「重启后的新世代」宿主并等 socket 就绪。$1..= 额外 env 赋值(如 AA_MIHOMO_KERNEL_PATH=…)。
# 关键:先删被 kill -9 的上世代留下的**陈旧 socket 文件**(kill -9 不清 UDS 文件),否则「socket 存在」会假就绪——
#   自愈在 UDS server 启动**之前**同步跑完,故新 socket 出现 == 自愈已完成且开始服务(SOCK_UP 才是可靠就绪信号)。
start_restart_host() {
  rm -f "$SOCK"   # 只删陈旧 socket;**绝不 pkill**——上世代孤儿 stub 须存活,供本世代自愈 reap
  # 用 env 施加 env 变量:从 "$@" 展开来的 NAME=VALUE 无法被 bash 当赋值处理,必须交给 env 命令解析。
  env "$@" AA_NETWORKSETUP_FAKE_STATE="$SHNET" AA_TAKEOVER_STATE_PATH="$SHSTATE" "$HOST_BIN" > "$HOSTLOG" 2>&1 &
  HOST_PID=$!
  disown "$HOST_PID" 2>/dev/null || true
  wait_host_ready "$HOST_PID" || true
}

# —— 剧本 A:接管 → kill -9 → 重启(带内核)→ 恢复接管(reap 孤儿 + 重启内核 + 重指存活端口)——
if crash_generation; then
  echo "    剧本A:crash 后 orphan 内核 pid=$ORPHAN_PID"
  # 崩溃残留三件套:代理指向死端口 + 持久化标记(含 kernelPort/kernelPID/snapshot)+ 孤儿内核仍活。
  if grep -qF '"enabled":true,"host":"127.0.0.1","port":7890' "$SHNET"; then echo "PASS: 剧本A crash 后系统代理仍指向死端口 127.0.0.1:7890(断网态,待自愈)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A crash 后未见指向死端口的代理。文件: $(cat "$SHNET")"; FAIL=$((FAIL+1)); fi
  if [ -f "$SHSTATE" ] && grep -qF '"kernelPort":7890' "$SHSTATE" && grep -qF '"snapshot"' "$SHSTATE" && grep -qF '"kernelPID"' "$SHSTATE"; then echo "PASS: 剧本A crash 后持久化接管态清单在(含 snapshot/kernelPort/kernelPID)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A crash 后持久化清单缺失/不完整: $(cat "$SHSTATE" 2>/dev/null)"; FAIL=$((FAIL+1)); fi
  if [ -n "$ORPHAN_PID" ] && kill -0 "$ORPHAN_PID" 2>/dev/null; then echo "PASS: 剧本A crash 后孤儿内核仍存活(pid=$ORPHAN_PID;kill -9 宿主退出钩子没跑到)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A crash 后孤儿内核未存活(pid=$ORPHAN_PID)——无法验证跨世代 reap"; FAIL=$((FAIL+1)); fi

  start_restart_host AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT"
  if [ "$SOCK_UP" -eq 1 ]; then
    READY=0
    for _ in $(seq 1 60); do
      if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then READY=1; break; fi
      sleep 0.2
    done
    echo "    剧本A 重启+自愈日志:"; grep -F 'self-heal' "$HOSTLOG" | sed 's/^/      /'
    NEW_STUB="$(pgrep -f "$KILLPAT_STUB" | grep -vx "$ORPHAN_PID" | head -1)"
    if grep -qF 'self-heal decision=recoverTakeover' "$HOSTLOG"; then echo "PASS: 剧本A 自愈判定=恢复接管(recoverTakeover)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A 自愈未走恢复接管。日志: $(grep -F self-heal "$HOSTLOG")"; FAIL=$((FAIL+1)); fi
    if [ -n "$ORPHAN_PID" ] && ! kill -0 "$ORPHAN_PID" 2>/dev/null; then echo "PASS: 剧本A 自愈 reap 了上世代孤儿内核(旧 pid=$ORPHAN_PID 已不存活,还 06 反孤儿债)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A 上世代孤儿内核未被 reap(pid=$ORPHAN_PID 仍在)"; FAIL=$((FAIL+1)); pkill -9 -f "$KILLPAT_STUB" 2>/dev/null; fi
    SPA="$("$BIN/aa" proxy status --json 2>/dev/null)"
    if printf '%s' "$SPA" | grep -qF '"running":true'; then echo "PASS: 剧本A 自愈后有存活受管内核(proxy.status running=true → 端口非死)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A 自愈后无存活受管内核。status=$SPA"; FAIL=$((FAIL+1)); fi
    if grep -qF '"enabled":true,"host":"127.0.0.1","port":7890' "$SHNET"; then echo "PASS: 剧本A 自愈后系统代理指向 127.0.0.1:7890(现由重启内核承载,不指向死端口)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A 自愈后代理未指向内核端口。文件: $(cat "$SHNET")"; FAIL=$((FAIL+1)); fi
    if [ -n "$NEW_STUB" ] && [ "$NEW_STUB" != "$ORPHAN_PID" ]; then echo "PASS: 剧本A 自愈重启了新内核(new pid=$NEW_STUB ≠ 旧孤儿 $ORPHAN_PID)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A 未见与旧孤儿不同的新内核(new=$NEW_STUB, orphan=$ORPHAN_PID)"; FAIL=$((FAIL+1)); fi
    if [ -n "$NEW_STUB" ] && [ -f "$SHSTATE" ] && grep -qF "\"kernelPID\":$NEW_STUB" "$SHSTATE"; then echo "PASS: 剧本A 自愈更新了持久化标记(kernelPID=$NEW_STUB,仍处接管态)"; PASS=$((PASS+1)); else echo "FAIL: 剧本A 持久化标记未更新为新内核 pid(new=$NEW_STUB)。文件: $(cat "$SHSTATE" 2>/dev/null)"; FAIL=$((FAIL+1)); fi
  else
    echo "FAIL: 剧本A 重启宿主未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
  fi
else
  echo "FAIL: 剧本A crash_generation 未成功建立残留接管态(前置失败)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi
teardown_hosts also-stub   # 剧本间清场:轮询等宿主+stub 真死(取代盲 sleep 1)

# —— 剧本 B:接管 → kill -9 → 重启(不带内核)→ 还原快照(内核不可重启 → 降级直连,精确复原)——
if crash_generation; then
  echo "    剧本B:crash 后 orphan 内核 pid=$ORPHAN_PID"
  start_restart_host   # 不带 AA_MIHOMO_KERNEL_PATH → 内核不可重启
  if [ "$SOCK_UP" -eq 1 ]; then
    sleep 1
    echo "    剧本B 重启+自愈日志:"; grep -F 'self-heal' "$HOSTLOG" | sed 's/^/      /'
    if grep -qF 'self-heal decision=restoreSnapshot' "$HOSTLOG"; then echo "PASS: 剧本B 自愈判定=还原快照(restoreSnapshot,内核不可重启→降级直连)"; PASS=$((PASS+1)); else echo "FAIL: 剧本B 自愈未走还原快照。日志: $(grep -F self-heal "$HOSTLOG")"; FAIL=$((FAIL+1)); fi
    if [ -n "$ORPHAN_PID" ] && ! kill -0 "$ORPHAN_PID" 2>/dev/null; then echo "PASS: 剧本B 自愈同样先 reap 了上世代孤儿内核(旧 pid=$ORPHAN_PID 已不存活)"; PASS=$((PASS+1)); else echo "FAIL: 剧本B 孤儿内核未被 reap(pid=$ORPHAN_PID)"; FAIL=$((FAIL+1)); pkill -9 -f "$KILLPAT_STUB" 2>/dev/null; fi
    if grep -qF '127.0.0.1' "$SHNET"; then echo "FAIL: 剧本B 自愈后仍残留死端口 127.0.0.1(未清)。文件: $(cat "$SHNET")"; FAIL=$((FAIL+1)); else echo "PASS: 剧本B 自愈后系统代理不再指向死端口 127.0.0.1(降级直连,不断网)"; PASS=$((PASS+1)); fi
    if grep -qF '"enabled":true,"host":"203.0.113.9","port":8080' "$SHNET"; then echo "PASS: 剧本B 还原快照精确回到接管前第三方代理 203.0.113.9:8080(非一律关闭)"; PASS=$((PASS+1)); else echo "FAIL: 剧本B 未精确还原第三方代理。文件: $(cat "$SHNET")"; FAIL=$((FAIL+1)); fi
    if shnet_equals_initial; then echo "PASS: 剧本B 自愈后假 networksetup 终态=接管前快照(精确复原)"; PASS=$((PASS+1)); else echo "FAIL: 剧本B 终态≠接管前快照。终态: $(cat "$SHNET")"; FAIL=$((FAIL+1)); fi
    if [ ! -e "$SHSTATE" ]; then echo "PASS: 剧本B 自愈还原后清除了持久化标记(无残留接管,下次启动 clean)"; PASS=$((PASS+1)); else echo "FAIL: 剧本B 还原后持久化标记仍在: $(cat "$SHSTATE")"; FAIL=$((FAIL+1)); fi
  else
    echo "FAIL: 剧本B 重启宿主未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
  fi
else
  echo "FAIL: 剧本B crash_generation 未成功(前置失败)。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi
teardown_hosts also-stub   # 剧本间清场:轮询等宿主+stub 真死(取代盲 sleep 1)

# —— 剧本 C:接管 → kill -9 → 用户手动把代理改成别的第三方 → 重启 → 只清陈旧标记、绝不覆盖用户设置 ——
if crash_generation; then
  # 用户手动把系统代理改成第三方 198.51.100.5:1080(不再指向我方 7890)。
cat > "$SHNET" <<'JSON'
{"services":[
{"service":"Wi-Fi","http":{"enabled":true,"host":"198.51.100.5","port":1080},"https":{"enabled":true,"host":"198.51.100.5","port":1080},"socks":{"enabled":false,"host":"","port":0}},
{"service":"Ethernet","http":{"enabled":true,"host":"198.51.100.5","port":1080},"https":{"enabled":true,"host":"198.51.100.5","port":1080},"socks":{"enabled":false,"host":"","port":0}}
]}
JSON
  python3 -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2],"w"), sort_keys=True)' "$SHNET" "$BUILD/selfheal-userchanged.json" 2>/dev/null
  start_restart_host AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT"
  if [ "$SOCK_UP" -eq 1 ]; then
    sleep 1
    echo "    剧本C 重启+自愈日志:"; grep -F 'self-heal' "$HOSTLOG" | sed 's/^/      /'
    if grep -qF 'self-heal decision=userChangedProxy' "$HOSTLOG"; then echo "PASS: 剧本C 自愈判定=用户手动改过代理(userChangedProxy)"; PASS=$((PASS+1)); else echo "FAIL: 剧本C 自愈未走 userChanged。日志: $(grep -F self-heal "$HOSTLOG")"; FAIL=$((FAIL+1)); fi
    if python3 -c 'import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
sys.exit(0 if a==b else 1)' "$SHNET" "$BUILD/selfheal-userchanged.json" 2>/dev/null; then echo "PASS: 剧本C 绝不覆盖用户设置(用户第三方代理 198.51.100.5:1080 原封不动)"; PASS=$((PASS+1)); else echo "FAIL: 剧本C 自愈改动了用户设置。终态: $(cat "$SHNET")"; FAIL=$((FAIL+1)); fi
    if grep -qF '127.0.0.1' "$SHNET"; then echo "FAIL: 剧本C 竟出现 127.0.0.1(不该指向我方端口)"; FAIL=$((FAIL+1)); else echo "PASS: 剧本C 终态不指向我方死端口(尊重用户直连/第三方设置)"; PASS=$((PASS+1)); fi
    if [ ! -e "$SHSTATE" ]; then echo "PASS: 剧本C 清除了陈旧持久化标记(不再自作主张接管)"; PASS=$((PASS+1)); else echo "FAIL: 剧本C 陈旧标记仍在: $(cat "$SHSTATE")"; FAIL=$((FAIL+1)); fi
  else
    echo "FAIL: 剧本C 重启宿主未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
  fi
else
  echo "FAIL: 剧本C crash_generation 未成功(前置失败)"; FAIL=$((FAIL+1))
fi
teardown_hosts also-stub   # 剧本间清场:轮询等宿主+stub 真死(取代盲 sleep 1)

# —— 剧本 D:损坏标记 + 本机死代理 → 启动前降级直连；随后宿主正常启停也不得重新留下死端口 ——
printf '%s' 'not-json' > "$SHSTATE"
cat > "$SHNET" <<'JSON'
{"services":[
{"service":"Wi-Fi","http":{"enabled":true,"host":"127.0.0.1","port":7890},"https":{"enabled":true,"host":"localhost","port":7890},"socks":{"enabled":false,"host":"","port":0}},
{"service":"Ethernet","http":{"enabled":true,"host":"203.0.113.9","port":8080},"https":{"enabled":false,"host":"","port":0},"socks":{"enabled":false,"host":"","port":0}}
]}
JSON
start_restart_host AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT"
if [ "$SOCK_UP" -eq 1 ]; then
  if grep -qF 'self-heal decision=failSafeDirect' "$HOSTLOG"; then echo "PASS: 剧本D 损坏标记走 failSafeDirect 隔离路径"; PASS=$((PASS+1)); else echo "FAIL: 剧本D 未走 failSafeDirect。日志: $(grep -F self-heal "$HOSTLOG")"; FAIL=$((FAIL+1)); fi
  if grep -qE '"host":"(127\.0\.0\.1|localhost|::1)"' "$SHNET"; then echo "FAIL: 剧本D 降级后仍有本机死代理: $(cat "$SHNET")"; FAIL=$((FAIL+1)); else echo "PASS: 剧本D 启动前已禁用本机死代理"; PASS=$((PASS+1)); fi
  if grep -qF '"enabled":true,"host":"203.0.113.9","port":8080' "$SHNET"; then echo "PASS: 剧本D 非本机第三方代理保持不变"; PASS=$((PASS+1)); else echo "FAIL: 剧本D 意外改动第三方代理: $(cat "$SHNET")"; FAIL=$((FAIL+1)); fi
  if [ ! -e "$SHSTATE" ]; then echo "PASS: 剧本D 降级成功后清除损坏标记"; PASS=$((PASS+1)); else echo "FAIL: 剧本D 损坏标记仍在"; FAIL=$((FAIL+1)); fi
  kill -USR1 "$HOST_PID" 2>/dev/null
  for _ in $(seq 1 100); do kill -0 "$HOST_PID" 2>/dev/null || break; sleep 0.1; done
  if grep -qE '"host":"(127\.0\.0\.1|localhost|::1)"' "$SHNET"; then echo "FAIL: 剧本D 宿主退出后重新留下本机死代理"; FAIL=$((FAIL+1)); else echo "PASS: 剧本D 宿主正常退出后仍无本机死代理"; PASS=$((PASS+1)); fi
else
  echo "FAIL: 剧本D 损坏标记宿主未就绪。宿主日志:"; cat "$HOSTLOG"; FAIL=$((FAIL+1))
fi
teardown_hosts also-stub
rm -f "$SHSTATE" "$AA_TAKEOVER_STATE_PATH"
