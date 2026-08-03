# --- 断言组 FS:旗舰场景全链验收 E2E(16 票;5 条)---
#
# 验收辞(v1-roadmap Phase 1):「Codex 经 `aa` 开代理/切节点全程零 GUI 打断;换订阅源必触发宿主确认」。
#
# ============================================================================
# 本组与 06–10 各组的分工(**别把它读成"再测一遍各能力"**)
# ============================================================================
# 06/07/09/10 已经逐条测过各能力自己的行为(状态/接管/模式/节点/订阅)。本组**不重复**那些判据,
#   它只做那几组做不到的一件事:把它们**串成验收辞描述的那一条真实路径**,
#   用**一个宿主实例**、**全程只经 `aa`** 走完 开代理 → 切模式 → 选节点 → 更新已有订阅,
#   并断言「零 GUI 打断」这件**整体性质**(单条能力各自不弹窗 ≠ 整条链跑下来没弹过窗)。
#
# ============================================================================
# 「零 GUI 打断」怎么才算被**证明**(而不是"没观察到")
# ============================================================================
# 旗舰链宿主**不带** `AA_CONFIRM_AUTO` 启动 —— 即确认路由是 `interactive` 档(真 NSAlert),
#   这条链上但凡有一个 dangerous,确认回调就会真的走到弹窗那条路。三条证据合起来才叫证明:
#   ① 宿主日志有 `dangerous 确认模式: interactive` —— 确认路由处于**会弹窗**的档位(不是被 auto 短路);
#   ② 全窗口内宿主日志**没有任何** `[confirm] ` 行(该行在 confirmDangerous 最开头无条件打,
#      **早于** AA_CONFIRM_AUTO 的任何分支)—— 确认层压根没被触达;
#   ③ 每一步都在墙钟时限内返回、退出码 0,且响应里**没有** `"pending":true` / `requestId`
#      —— 挡住"因为超时被杀所以看起来没弹窗"和"其实返回了 pending、弹窗在后台开着"这两条假绿。
# ⚠️ 只有 ①②③ 全中才判 PASS;任一缺失即 FAIL 并打印实际日志。
#
# **反向对照(第 3 条断言)**:同一条路由下把最后一步换成 dangerous 的换源(`proxy.subscription.add`),
#   用 `AA_CONFIRM_AUTO=deny` 起第二个宿主,断言它**确实**触发了确认(有 `[confirm] ` 行)且被拦下(退出码 2)。
#   没有这条对照,"零打断"可能只是因为**确认路由整个坏了** —— 那样全绿反而是最危险的。
#
# ============================================================================
# 安全边界(与既有 E2E 同口径,逐条对齐)
# ============================================================================
# * **绝不调真 `networksetup`**:`AA_NETWORKSETUP_FAKE_STATE` 指向 $BUILD 下的文件后端假件。
# * **绝不碰用户自己的 mihomo**:只起仓库树内的 `Scripts/fake-mihomo.py`;清场只按绝对路径 pkill。
# * 订阅目录 / 接管态标记全部导向 $BUILD 临时区,不污染真实 AppSupport(finalize.sh 有跑前后比对守卫)。
# * 旗舰链宿主额外带 `AA_AUTO_DENY_SECONDS=8` —— **纯安全网**:它只在 `.interactive`(真弹窗)分支生效,
#   万一将来有人把链上某条能力误标成 dangerous,弹窗会 8s 后自动拒绝并留下日志,
#   而不是把一个模态框永远挂在用户屏幕上。本组的判据是"压根没有 `[confirm] ` 行",
#   所以这条安全网一旦真被用到,断言照样红 —— 它买的是"别劫持用户的屏幕",不是"让断言好过"。
#
# 排位:在 menubar.sh 之后、mihomo-real-e2e.sh 之前 —— 与 app-bundle / menubar 同一条考量:
#   本组只起 fake stub、不起真内核,而 mihomo-real-e2e 开头就 teardown_hosts,天然替本组兜一层底。
echo "--- 断言组 FS:旗舰场景全链 E2E(16 票)---"
teardown_hosts also-stub

FS_DIR="$BUILD/flagship"; rm -rf "$FS_DIR"; mkdir -p "$FS_DIR"
FS_SUBS="$FS_DIR/subs"; mkdir -p "$FS_SUBS"
FS_NET="$FS_DIR/netfake.json"
FS_TAKEOVER="$FS_DIR/takeover.json"
FS_FIXTURE="$FS_DIR/flagship.fixture.json"        # 旗舰订阅的源(update 前后各写一版,证明真的重新拉取)
FS_SWAP_FIXTURE="$FS_DIR/flagship-swap.fixture.json"  # 反向对照用的"另一个源"
FS_CMDLOG="$FS_DIR/steps.argv"                    # 每一步的 argv —— 第 4 条断言的凭证
FS_STEPLOG="$FS_DIR/steps.log"                    # 逐步骤的 rc / stdout(人读)
FS_REQS="$FS_DIR/host-requests.log"               # 旗舰链窗口内宿主收到的**全部** UDS 请求行
FS_OUTF="$FS_DIR/step.out"; FS_ERRF="$FS_DIR/step.err"
: > "$FS_CMDLOG"; : > "$FS_STEPLOG"

# 假 networksetup 初始状态(与 07 票同款:Wi-Fi 全关;Ethernet 原本就有第三方代理)。
cat > "$FS_NET" <<'JSON'
{"services":[
{"service":"Wi-Fi","http":{"enabled":false,"host":"","port":0},"https":{"enabled":false,"host":"","port":0},"socks":{"enabled":false,"host":"","port":0}},
{"service":"Ethernet","http":{"enabled":true,"host":"203.0.113.9","port":8080},"https":{"enabled":true,"host":"203.0.113.9","port":8080},"socks":{"enabled":false,"host":"","port":0}}
]}
JSON

# 订阅源 v1(旗舰链开始时内核处于这一版)。fixture 格式是 fake-mihomo.py 的 test-only JSON,非真 YAML。
cat > "$FS_FIXTURE" <<'JSON'
{"mode":"rule","groups":{"PROXY":{"type":"Selector","all":["FS-A","FS-B"],"now":"FS-A"}}}
JSON
# 反向对照的"另一个源"(内容无所谓 —— deny 分支根本走不到拉取)。
cat > "$FS_SWAP_FIXTURE" <<'JSON'
{"mode":"global","groups":{"PROXY":{"type":"Selector","all":["SWAP-1"],"now":"SWAP-1"}}}
JSON

# 起旗舰宿主。$1 = 确认档:none(**不设** AA_CONFIRM_AUTO,旗舰链用)/ approve(前置装订阅用)/ deny(反向对照用)。
# 每次先 teardown + truncate 宿主日志 —— 本组的判据全是"日志里有没有某行",日志必须属于**当前这个**宿主。
fs_start_host() {
  local confirm="$1"
  teardown_hosts also-stub
  : > "$HOSTLOG"
  if [ "$confirm" = "none" ]; then
    env AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT" \
        AA_SUBSCRIPTION_DIR="$FS_SUBS" AA_TAKEOVER_STATE_PATH="$FS_TAKEOVER" \
        AA_NETWORKSETUP_FAKE_STATE="$FS_NET" AA_AUTO_DENY_SECONDS=8 \
        "$HOST_BIN" > "$HOSTLOG" 2>&1 &
  else
    env AA_MIHOMO_KERNEL_PATH="$STUB" AA_MIHOMO_CONTROL_PORT="$MIHOMO_PORT" \
        AA_SUBSCRIPTION_DIR="$FS_SUBS" AA_TAKEOVER_STATE_PATH="$FS_TAKEOVER" \
        AA_NETWORKSETUP_FAKE_STATE="$FS_NET" AA_CONFIRM_AUTO="$confirm" \
        "$HOST_BIN" > "$HOSTLOG" 2>&1 &
  fi
  FS_HOST_PID=$!
  disown "$FS_HOST_PID" 2>/dev/null || true
  wait_host_ready "$FS_HOST_PID"
}

# 轮询等内核 REST 就绪(接管要读 mixed-port;订阅重载要经 REST)。返回 0/1。
fs_wait_rest() {
  local i
  for i in $(seq 1 60); do
    if "$BIN/aa" proxy status --json 2>/dev/null | grep -qF '"apiReachable":true'; then return 0; fi
    sleep 0.2
  done
  return 1
}

# ---- 旗舰链的唯一执行入口 --------------------------------------------------
# 每一步都经这里跑,于是三件事**同时**成立且可核验:
#   ① argv 落进 $FS_CMDLOG(第 4 条断言据此核对"每一步都是 $BIN/aa");
#   ② 墙钟超时(超时即 kill -9 并记账,防"因为被杀所以看起来没弹窗"的假绿);
#   ③ 期望 UDS 往返次数记账 —— 域子命令 = capabilities.list(取元数据) + capabilities.call(执行) **两次**往返,
#      这是 DomainCommands.doDomainCommand 的确定行为;本组所有步骤一律用域子命令形态,故每步恒 +2。
# 置全局:FS_RC / FS_OUT / FS_TIMEDOUT。
FS_REQ_EXPECT=0
FS_TIMEOUT_HITS=""
fs_step() {  # $1=步骤名 $2=墙钟超时秒 $3..=命令(必须是 "$BIN/aa" …)
  local desc="$1" secs="$2"; shift 2
  printf '%s\n' "$*" >> "$FS_CMDLOG"
  rm -f "$FS_OUTF" "$FS_ERRF"
  # exec:让后台作业**就是** aa 进程本身(不是包一层 subshell)——否则超时时 kill 只杀得到壳,aa 会漏网。
  ( exec "$@" >"$FS_OUTF" 2>"$FS_ERRF" ) &
  local p=$! i
  FS_TIMEDOUT=0
  for i in $(seq 1 $((secs * 10))); do
    kill -0 "$p" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$p" 2>/dev/null; then
    FS_TIMEDOUT=1
    FS_TIMEOUT_HITS="$FS_TIMEOUT_HITS [$desc 超过 ${secs}s]"
    kill -9 "$p" 2>/dev/null
  fi
  wait "$p" 2>/dev/null; FS_RC=$?
  FS_OUT="$(cat "$FS_OUTF" 2>/dev/null)"
  FS_REQ_EXPECT=$((FS_REQ_EXPECT + 2))
  printf '步骤[%s] rc=%s timedout=%s\n  argv: %s\n  stdout: %s\n  stderr: %s\n' \
    "$desc" "$FS_RC" "$FS_TIMEDOUT" "$*" "$FS_OUT" "$(cat "$FS_ERRF" 2>/dev/null)" >> "$FS_STEPLOG"
  echo "    步骤[$desc] rc=$FS_RC timedout=$FS_TIMEDOUT → $FS_OUT"
}

# 步骤级判据一律用 `<条件> || FS1_ERR="$FS1_ERR …;"` 就地累加(不抽助手 —— 判据描述里带着 JSON 实际输出,
#   经 eval 间接赋值会被里面的引号打断)。三条整体结论各自只在最后打**一次** PASS/FAIL。

# ============================================================================
# 前置(**不属于旗舰链**):这台机器上"已经有一个订阅"
# ============================================================================
# 验收辞里的旗舰链是「更新**已有**订阅」;"新增/换源"才是 dangerous 的那一条(见第 3 条断言)。
#   故先用一个**独立的、带 AA_CONFIRM_AUTO=approve 的**宿主把订阅装上并激活,然后**关掉它**。
#   旗舰链宿主随后重开,自己不带任何 CONFIRM_AUTO —— 前置阶段的 approve 绝不会渗进旗舰链的日志窗口
#   (fs_start_host 每次 truncate $HOSTLOG)。
FS_PREP_OK=0
FS_SUB_ID=""
fs_start_host approve
if [ "$SOCK_UP" -eq 1 ] && fs_wait_rest; then
  FS_PREP_ADD="$("$BIN/aa" capabilities call proxy.subscription.add \
      --input "{\"name\":\"flagship\",\"source\":\"file://$FS_FIXTURE\"}" --json 2>/dev/null)"
  FS_SUB_ID="$(printf '%s' "$FS_PREP_ADD" | grep -o '"id":"[^"]*"' | head -1 | sed 's/^"id":"//;s/"$//')"
  echo "    [前置] 装订阅: $FS_PREP_ADD (id=$FS_SUB_ID)"
  if [ -n "$FS_SUB_ID" ]; then
    "$BIN/aa" capabilities call proxy.subscription.activate --input "{\"id\":\"$FS_SUB_ID\"}" --json >/dev/null 2>&1 \
      && FS_PREP_OK=1
  fi
fi
[ "$FS_PREP_OK" -eq 1 ] || echo "    [前置] ⚠️ 未能装上并激活旗舰订阅 —— 下面四条链上断言会如实红。宿主日志尾部:"
[ "$FS_PREP_OK" -eq 1 ] || tail -20 "$HOSTLOG" 2>/dev/null | sed 's/^/      /'
teardown_hosts also-stub

# 订阅源改版 v2:mode 变 direct、候选多一个 FS-C 且 now=FS-C。
#   旗舰链第 4 步 update 会重新拉取它 —— 于是"更新真的生效了"有硬凭证(不是 updated=true 一句自述)。
cat > "$FS_FIXTURE" <<'JSON'
{"mode":"direct","groups":{"PROXY":{"type":"Selector","all":["FS-A","FS-B","FS-C"],"now":"FS-C"}}}
JSON

# ============================================================================
# 旗舰链:一个宿主实例,全程只经 aa,不设 AA_CONFIRM_AUTO
# ============================================================================
FS1_ERR=""; FS2_ERR=""; FS4_ERR=""
FS_CHAIN_RAN=0
FS_REQ_EXPECT_CHAIN=0; FS_REQ_ACTUAL=0
FS_HOSTLOG_CHAIN="$FS_DIR/host-chain.log"

fs_start_host none
if [ "$SOCK_UP" -eq 1 ] && fs_wait_rest && [ "$FS_PREP_OK" -eq 1 ]; then
  FS_CHAIN_RAN=1
  # 基线:就绪探测本身也发了若干请求,它们不属于旗舰链窗口。从这一刻起计。
  FS_REQ_BASE="$(grep -c '\[AAHost\] 请求: ' "$HOSTLOG" 2>/dev/null || true)"
  [ -z "$FS_REQ_BASE" ] && FS_REQ_BASE=0

  # 步骤 0:agent 先发现"这台机器上有哪个订阅"(id 不硬编码,照 10 票口径读回再喂)。
  fs_step "0 发现订阅 aa proxy subscription list" 25 "$BIN/aa" proxy subscription list --json
  FS_S0_OUT="$FS_OUT"
  [ "$FS_RC" -eq 0 ] || FS1_ERR="$FS1_ERR 步骤0(subscription list)退出码=$FS_RC(期望0);"
  FS_CHAIN_ID="$(printf '%s' "$FS_S0_OUT" | grep -o '"id":"[^"]*"' | head -1 | sed 's/^"id":"//;s/"$//')"
  [ -n "$FS_CHAIN_ID" ] || FS1_ERR="$FS1_ERR 步骤0 未从 list 捕获到订阅 id;"

  # 步骤 1:开代理(proxy.system.enable,normal)。
  fs_step "1 开代理 aa proxy on" 25 "$BIN/aa" proxy on --json
  FS_S1_OUT="$FS_OUT"
  [ "$FS_RC" -eq 0 ] || FS1_ERR="$FS1_ERR 步骤1(proxy on)退出码=$FS_RC(期望0);"
  grep -qF '"enabled":true' <<<"$FS_S1_OUT" || FS1_ERR="$FS1_ERR 步骤1 结果缺 enabled=true;"
  grep -qF '"port":7890' <<<"$FS_S1_OUT" || FS1_ERR="$FS1_ERR 步骤1 未指向内核 mixed-port 7890;"
  # 读回(不经 aa,直接看假 networksetup 状态文件):接管真落到了各服务上,且盖掉了原第三方代理。
  echo "    接管后假 networksetup: $(cat "$FS_NET")"
  # 期望条数**从 fixture 现算**,不写魔数 6:假 networksetup 的服务数一变(fixture 加一个网络服务),
  #   魔数就会与事实脱节 —— 要么白红,要么(更糟)把「少接管了几项」放过去。
  FS_ON_COUNT="$(grep -o '"enabled":true,"host":"127.0.0.1","port":7890' "$FS_NET" | wc -l | tr -d ' ')"
  # 假 networksetup 形状:{"services":[{service, http, https, socks}, …]} —— 每个服务三类代理档,
  #   故期望条数 = 服务数 × 3。服务数从 fixture 现数,不写死。
  FS_SVC_N="$(grep -o '"service"[[:space:]]*:' "$FS_NET" | wc -l | tr -d ' ')"
  FS_ON_EXPECT=$(( FS_SVC_N * 3 ))
  if [ "${FS_ON_EXPECT:-0}" -eq 0 ]; then
    FS1_ERR="$FS1_ERR 步骤1 无法从假 networksetup 推算期望条数(数不出 service 字段,fixture 形状变了),绝不算过;"
  elif [ "${FS_ON_COUNT:-0}" -ne "${FS_ON_EXPECT}" ]; then
    FS1_ERR="$FS1_ERR 步骤1 假 networksetup 指向内核端口的项=$FS_ON_COUNT(按 fixture 推算应为 $FS_ON_EXPECT);"
  fi
  grep -qF '203.0.113.9' "$FS_NET" && FS1_ERR="$FS1_ERR 步骤1 接管后仍残留原第三方代理 203.0.113.9;"

  # 步骤 2:切模式(proxy.mode.set,normal)+ 读回。
  fs_step "2 切模式 aa proxy mode --mode global" 25 "$BIN/aa" proxy mode --mode global --json
  FS_S2_OUT="$FS_OUT"
  [ "$FS_RC" -eq 0 ] || FS1_ERR="$FS1_ERR 步骤2(proxy mode)退出码=$FS_RC(期望0);"
  grep -qF '"set":true' <<<"$FS_S2_OUT" || FS1_ERR="$FS1_ERR 步骤2 结果缺 set=true;"
  fs_step "2r 读回 aa proxy status" 25 "$BIN/aa" proxy status --json
  grep -qF '"mode":"global"' <<<"$FS_OUT" || FS1_ERR="$FS1_ERR 步骤2 读回 mode≠global;"

  # 步骤 3:选节点(proxy.node.select,normal)+ 读回。候选来自 v1 订阅([FS-A,FS-B],now=FS-A)。
  fs_step "3 选节点 aa proxy node --group PROXY --node FS-B" 25 "$BIN/aa" proxy node --group PROXY --node FS-B --json
  FS_S3_OUT="$FS_OUT"
  [ "$FS_RC" -eq 0 ] || FS1_ERR="$FS1_ERR 步骤3(proxy node)退出码=$FS_RC(期望0);"
  grep -qF '"selected":true' <<<"$FS_S3_OUT" || FS1_ERR="$FS1_ERR 步骤3 结果缺 selected=true;"
  fs_step "3r 读回 aa proxy groups" 25 "$BIN/aa" proxy groups --json
  grep -qF '"now":"FS-B"' <<<"$FS_OUT" || FS1_ERR="$FS1_ERR 步骤3 读回 PROXY now≠FS-B;"

  # 步骤 4:更新**已有**订阅(proxy.subscription.update,normal)+ 读回。
  #   源文件已被换成 v2 → 读回必须反映 v2(mode=direct / 候选多出 FS-C / now=FS-C),
  #   否则 updated=true 只是自述,证明不了"真的重新拉取并重载生效"。
  fs_step "4 更新已有订阅 aa proxy subscription update" 25 "$BIN/aa" proxy subscription update --id "$FS_CHAIN_ID" --json
  FS_S4_OUT="$FS_OUT"
  [ "$FS_RC" -eq 0 ] || FS1_ERR="$FS1_ERR 步骤4(subscription update)退出码=$FS_RC(期望0);"
  grep -qF '"updated":true' <<<"$FS_S4_OUT" || FS1_ERR="$FS1_ERR 步骤4 结果缺 updated=true;"
  fs_step "4r 读回 aa proxy status" 25 "$BIN/aa" proxy status --json
  grep -qF '"mode":"direct"' <<<"$FS_OUT" || FS1_ERR="$FS1_ERR 步骤4 读回 mode≠direct(新版源未生效);"
  fs_step "4r2 读回 aa proxy groups" 25 "$BIN/aa" proxy groups --json
  FS_S4R2_OUT="$FS_OUT"
  grep -qF '"now":"FS-C"' <<<"$FS_S4R2_OUT" || FS1_ERR="$FS1_ERR 步骤4 读回 PROXY now≠FS-C;"
  grep -qF '"all":["FS-A","FS-B","FS-C"]' <<<"$FS_S4R2_OUT" || FS1_ERR="$FS1_ERR 步骤4 读回候选未变为 [FS-A,FS-B,FS-C];"

  # —— 旗舰链窗口就此关闭:记账 + 取证 ——
  # 把计数**冻结**在这里。`fs_step` 后面还会被 FS3 的反向对照用到,那些调用照样会往 $FS_REQ_EXPECT 上加,
  #   但对账只认这条链窗口内的数 —— 快照下来,后续增量就不会污染判据(也免得读的人以为那些加法有用)。
  FS_REQ_EXPECT_CHAIN=$FS_REQ_EXPECT
  grep '\[AAHost\] 请求: ' "$HOSTLOG" 2>/dev/null | tail -n +$((FS_REQ_BASE + 1)) > "$FS_REQS" || true
  FS_REQ_ACTUAL="$(wc -l < "$FS_REQS" 2>/dev/null | tr -d ' ')"; [ -z "$FS_REQ_ACTUAL" ] && FS_REQ_ACTUAL=0
  cp "$HOSTLOG" "$FS_HOSTLOG_CHAIN" 2>/dev/null || true
  cp "$FS_CMDLOG" "$FS_CMDLOG.chain" 2>/dev/null || true
else
  FS1_ERR="$FS1_ERR 旗舰链宿主/内核未就绪(socket_up=$SOCK_UP prep_ok=$FS_PREP_OK),整条链没跑起来;"
  FS2_ERR="$FS2_ERR 旗舰链没跑起来,零打断无从谈起;"
  FS4_ERR="$FS4_ERR 旗舰链没跑起来,无从核对调用路径;"
  cp "$HOSTLOG" "$FS_HOSTLOG_CHAIN" 2>/dev/null || true
  : > "$FS_REQS"
fi

# 收场:优雅退出(SIGUSR1 走 applicationWillTerminate → 还原代理 → 停内核),再兜底 teardown。
if [ -n "${FS_HOST_PID:-}" ]; then
  kill -USR1 "$FS_HOST_PID" 2>/dev/null
  for _ in $(seq 1 60); do kill -0 "$FS_HOST_PID" 2>/dev/null || break; sleep 0.1; done
fi
echo "    旗舰链结束后假 networksetup: $(cat "$FS_NET" 2>/dev/null)"
teardown_hosts also-stub

# ---- (FS1) 旗舰链四步全部成功 ----------------------------------------------
if [ -z "$FS1_ERR" ] && [ "$FS_CHAIN_RAN" -eq 1 ]; then
  echo "PASS: 旗舰链四步(开代理 → 切模式 → 选节点 → 更新已有订阅)在**同一个宿主实例**上全部成功,逐步骤退出码=0 且每步结果都经读回核实(接管落到 6/6 项、mode=global、PROXY now=FS-B、更新后新版源生效 mode=direct/now=FS-C)"
  PASS=$((PASS+1))
else
  echo "FAIL: 旗舰链未走通:$FS1_ERR"
  echo "    逐步骤明细($FS_STEPLOG):"; sed 's/^/      /' "$FS_STEPLOG" 2>/dev/null
  FAIL=$((FAIL+1))
fi

# ---- (FS2) 全链零 GUI 打断 --------------------------------------------------
# 三条证据缺一不可(见文件头)。日志取的是**旗舰链那个宿主**的完整日志快照。
FS_CHAIN_LOG_TEXT="$(cat "$FS_HOSTLOG_CHAIN" 2>/dev/null; true)"
if [ "$FS_CHAIN_RAN" -eq 1 ]; then
  # ① 确认路由处于会弹窗的档位(不是被 AA_CONFIRM_AUTO 短路)。
  grep -qF 'dangerous 确认模式: interactive' <<<"$FS_CHAIN_LOG_TEXT" \
    || FS2_ERR="$FS2_ERR 宿主未处于 interactive 确认档(旗舰链本应不带 AA_CONFIRM_AUTO);"
  grep -qF 'AA_CONFIRM_AUTO=approve' <<<"$FS_CHAIN_LOG_TEXT" \
    && FS2_ERR="$FS2_ERR 旗舰链宿主竟带了 AA_CONFIRM_AUTO=approve(确认被短路,零打断不成立);"
  grep -qF 'AA_CONFIRM_AUTO=deny' <<<"$FS_CHAIN_LOG_TEXT" \
    && FS2_ERR="$FS2_ERR 旗舰链宿主竟带了 AA_CONFIRM_AUTO=deny;"
  # ② 确认层压根没被触达([confirm] 行在 confirmDangerous 最开头无条件打)。
  grep -qF '[confirm] ' <<<"$FS_CHAIN_LOG_TEXT" \
    && FS2_ERR="$FS2_ERR 宿主日志出现确认行 [confirm](链上有能力走了 dangerous 确认);"
  grep -qF 'dangerous 确认结果' <<<"$FS_CHAIN_LOG_TEXT" \
    && FS2_ERR="$FS2_ERR 宿主日志出现「dangerous 确认结果」(真弹过窗);"
  grep -qF '自动拒绝计时到' <<<"$FS_CHAIN_LOG_TEXT" \
    && FS2_ERR="$FS2_ERR 触发了 AA_AUTO_DENY_SECONDS 安全网(说明真弹了窗、只是被自动关掉);"
  # ③ 没有一步超时被杀,也没有一步返回 pending(挡两条假绿)。
  [ -z "$FS_TIMEOUT_HITS" ] || FS2_ERR="$FS2_ERR 有步骤超墙钟时限被杀:$FS_TIMEOUT_HITS(不能因为被杀就当没弹窗);"
  if grep -qF '"pending":true' "$FS_STEPLOG" 2>/dev/null || grep -qF '"requestId"' "$FS_STEPLOG" 2>/dev/null; then
    FS2_ERR="$FS2_ERR 有步骤返回了 pending/requestId(确认框正在后台开着,不算零打断);"
  fi
fi
if [ -z "$FS2_ERR" ] && [ "$FS_CHAIN_RAN" -eq 1 ]; then
  echo "PASS: 全链零 GUI 打断已被证明 —— 宿主处于 interactive 确认档(会弹窗)、全窗口无任何 [confirm]/确认结果/自动拒绝日志行、九步全部在 25s 墙钟内返回且无一返回 pending/requestId"
  PASS=$((PASS+1))
else
  echo "FAIL: 零 GUI 打断未成立:$FS2_ERR"
  echo "    旗舰链宿主日志尾部($FS_HOSTLOG_CHAIN):"; tail -30 "$FS_HOSTLOG_CHAIN" 2>/dev/null | sed 's/^/      /'
  FAIL=$((FAIL+1))
fi

# ============================================================================
# (FS3) 反向对照:同一条路由下,dangerous 的换源**确实**触发确认且 deny 挡得住
# ============================================================================
# 这条是 FS2 的**对照组**,不是重复 10 票的 SUB2:它守的是"FS2 的绿不是因为确认路由整个坏了"。
#   姿态刻意与旗舰链一致(同一 $FS_SUBS 目录、同一 fake 内核、同一条 aa 路径),只把最后一步换成
#   `proxy.subscription.add`(dangerous),并把宿主换成 AA_CONFIRM_AUTO=deny。
FS3_ERR=""
fs_start_host deny
if [ "$SOCK_UP" -eq 1 ]; then
  fs_wait_rest || true
  fs_step "R 换源(dangerous) aa proxy subscription add" 25 \
    "$BIN/aa" proxy subscription add --name flagship-swap --source "file://$FS_SWAP_FIXTURE" --json
  FS_R_OUT="$FS_OUT"
  [ "$FS_RC" -eq 2 ] || FS3_ERR="$FS3_ERR 换源退出码=$FS_RC(期望2=denied);"
  grep -qF '"code":"denied"' <<<"$FS_R_OUT" || FS3_ERR="$FS3_ERR 响应缺 error.code=denied;"
  grep -qF '"added"' <<<"$FS_R_OUT" && FS3_ERR="$FS3_ERR 响应竟出现 added(疑似绕过确认执行了);"
  # 确认层**确实**被触达,且看得见本次请求的 name/source(不是盲批)。
  FS_R_CONF="$(grep -F '[confirm] proxy.subscription.add' "$HOSTLOG" | tail -1)"
  echo "    反向对照确认层日志: $FS_R_CONF"
  [ -n "$FS_R_CONF" ] || FS3_ERR="$FS3_ERR 宿主日志无 [confirm] proxy.subscription.add 行(确认路由没被触达——那 FS2 的绿就没有意义了);"
  grep -qF "source=file://$FS_SWAP_FIXTURE" <<<"$FS_R_CONF" || FS3_ERR="$FS3_ERR 确认层看不见 source;"
  grep -qF "name=flagship-swap" <<<"$FS_R_CONF" || FS3_ERR="$FS3_ERR 确认层看不见 name;"
  # 不留痕:catalog 里仍只有前置装的那一条旗舰订阅。
  FS_R_LIST="$("$BIN/aa" capabilities call proxy.subscription.list --json 2>/dev/null)"
  FS_R_IDS="$(printf '%s' "$FS_R_LIST" | grep -o '"id":"' | wc -l | tr -d ' ')"
  echo "    反向对照后 list: $FS_R_LIST(订阅条数=$FS_R_IDS)"
  grep -qF 'flagship-swap' <<<"$FS_R_LIST" && FS3_ERR="$FS3_ERR deny 竟留痕(list 出现 flagship-swap);"
  [ "${FS_R_IDS:-0}" -eq 1 ] || FS3_ERR="$FS3_ERR deny 后订阅条数=$FS_R_IDS(期望仍为1);"
else
  FS3_ERR="$FS3_ERR 反向对照宿主未就绪(socket_up=$SOCK_UP);"
fi

# ---- (FS5 取证)`aa docs agents-md` 提到的能力 id 是否真实存在于注册表 ----
# 趁反向对照这个宿主还活着把注册表清单取下来(safe 只读,不触确认);判据在下面 FS5 处合成一条结论。
FS_REG_IDS="$FS_DIR/registry-ids.txt"
FS_DOCS_TXT="$FS_DIR/agents-md.txt"
"$BIN/aa" capabilities list --json 2>/dev/null | grep -o '"id":"[^"]*"' | sed 's/^"id":"//;s/"$//' | sort -u > "$FS_REG_IDS" || true
"$BIN/aa" docs agents-md > "$FS_DOCS_TXT" 2>/dev/null; FS_DOCS_RC=$?

teardown_hosts also-stub

if [ -z "$FS3_ERR" ]; then
  echo "PASS: 反向对照成立 —— 同一条 aa 路由下,dangerous 换源(proxy.subscription.add)**确实**触发了宿主确认([confirm] 行含本次 name/source),AA_CONFIRM_AUTO=deny 当场挡下(退出码2 + code=denied),catalog 零留痕。故上面那条「零打断」不是因为确认路由坏了"
  PASS=$((PASS+1))
else
  echo "FAIL: 反向对照不成立:$FS3_ERR"
  echo "    ⚠️ 这条红比其它任何一条都危险:它意味着「零 GUI 打断」那条绿可能只是确认路由整个失效。"
  echo "    宿主日志尾部:"; tail -30 "$HOSTLOG" 2>/dev/null | sed 's/^/      /'
  FAIL=$((FAIL+1))
fi

# ============================================================================
# (FS4) 全链只经 `aa`
# ============================================================================
# **这条的证明力边界必须先写清楚**(它不是"内核层面无法绕过"那种强度):
#   UDS 服务端不记录对端进程身份(没取 LOCAL_PEERPID),所以没有任何日志能证明"发这条请求的进程是 aa"。
#   本条能硬证的是**两件可核验的事**,合起来足以排除"表面走 aa、暗地里另开一条道"这种作弊:
#     ① argv 凭证:旗舰链的每一步都经唯一入口 fs_step 执行,它把 argv 逐行落盘;
#        这里逐行核对**每一行都以 $BIN/aa 开头**(即没有任何一步是 python 裸 UDS / curl / networksetup 之类)。
#     ② 流量对账:旗舰链窗口内宿主收到的 UDS 请求**条数**必须恰好等于按步骤形态推算的期望值
#        (域子命令 = capabilities.list + capabilities.call 两次往返 × 9 步 = 18),
#        且**每一条**请求的 op/capability 都落在白名单内。多一条计划外流量(哪怕内容合法)就红。
#   —— 于是"链上有一步偷偷用裸 UDS 客户端做掉了"这条路被堵死:那要么让 argv 出现非 aa 命令(①红),
#      要么让宿主多收到一条请求(②红)。**但请如实理解**:它证的是"本脚本这条链没走别的道",
#      不是"外部进程不可能绕过 aa 直连宿主"——后者是 04/10 票「裸 UDS 直连仍被确认拦下」那两条的职责。
if [ "$FS_CHAIN_RAN" -eq 1 ]; then
  # ① argv 逐行核对
  FS_ARGV_N=0; FS_ARGV_BAD=""
  while IFS= read -r fsline; do
    [ -z "$fsline" ] && continue
    FS_ARGV_N=$((FS_ARGV_N+1))
    case "$fsline" in
      "$BIN/aa "*) : ;;
      *) FS_ARGV_BAD="$FS_ARGV_BAD [$fsline]" ;;
    esac
  done < "$FS_CMDLOG.chain"
  [ "$FS_ARGV_N" -eq 9 ] || FS4_ERR="$FS4_ERR 旗舰链 argv 记录=$FS_ARGV_N 条(期望9);"
  [ -z "$FS_ARGV_BAD" ] || FS4_ERR="$FS4_ERR 有步骤不是经 aa 执行:$FS_ARGV_BAD;"
  # ② 流量对账(条数 + 逐条 op/capability 白名单)
  FS_REQ_VERDICT="$(python3 - "$FS_REQS" <<'PY' 2>/dev/null
import json, sys
allowed_ops = {"capabilities.list", "capabilities.call"}
allowed_caps = {
    "proxy.subscription.list", "proxy.system.enable", "proxy.mode.set",
    "proxy.node.select", "proxy.subscription.update", "proxy.status", "proxy.groups.list",
}
marker = "请求: "
n = 0
bad = []
try:
    lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
except OSError as exc:
    print("FSREQ n=-1 bad=-1 读不到请求日志: %s" % exc)
    sys.exit(0)
for line in lines:
    i = line.find(marker)
    if i < 0:
        continue
    n += 1
    raw = line[i + len(marker):].strip()
    try:
        obj = json.loads(raw)
    except Exception:
        bad.append("非法 JSON 请求行: " + raw[:100])
        continue
    op = obj.get("op")
    if op not in allowed_ops:
        bad.append("计划外 op=%s" % op)
        continue
    if op == "capabilities.call":
        cap = obj.get("capability")
        if cap not in allowed_caps:
            bad.append("计划外 capability=%s" % cap)
print("FSREQ n=%d bad=%d" % (n, len(bad)))
for b in bad[:8]:
    print("  " + b)
PY
)"
  echo "    旗舰链流量对账: $FS_REQ_VERDICT(期望 n=$FS_REQ_EXPECT_CHAIN bad=0)"
  FS_REQ_N="$(sed -n 's/^FSREQ n=\([-0-9]*\) bad=.*/\1/p' <<<"$FS_REQ_VERDICT")"
  FS_REQ_BAD="$(sed -n 's/^FSREQ n=[-0-9]* bad=\([-0-9]*\).*/\1/p' <<<"$FS_REQ_VERDICT")"
  if [ -z "$FS_REQ_N" ] || [ -z "$FS_REQ_BAD" ]; then
    FS4_ERR="$FS4_ERR 流量对账器自身没给出结论行(无法核验,绝不算过);"
  else
    [ "$FS_REQ_N" -eq "$FS_REQ_EXPECT_CHAIN" ] \
      || FS4_ERR="$FS4_ERR 宿主实收请求 $FS_REQ_N 条 ≠ 按步骤推算的 $FS_REQ_EXPECT_CHAIN 条(有计划外流量或步骤形态变了);"
    [ "$FS_REQ_BAD" -eq 0 ] || FS4_ERR="$FS4_ERR 有 $FS_REQ_BAD 条请求的 op/capability 不在白名单内;"
  fi
fi
if [ -z "$FS4_ERR" ] && [ "$FS_CHAIN_RAN" -eq 1 ]; then
  echo "PASS: 旗舰链全程只经 aa —— 9 步 argv 逐行核对全部以 $BIN/aa 开头(无裸 UDS/curl/networksetup),且窗口内宿主实收 UDS 请求恰为 $FS_REQ_ACTUAL 条、条条 op/capability 在白名单内(零计划外流量)。证明力边界见本文件 FS4 段注释:UDS 不记对端身份,本条证的是「这条链没走别的道」,不是「外部无法绕过」"
  PASS=$((PASS+1))
else
  echo "FAIL: 「全链只经 aa」不成立:$FS4_ERR"
  echo "    argv 记录($FS_CMDLOG.chain):"; sed 's/^/      /' "$FS_CMDLOG.chain" 2>/dev/null
  FAIL=$((FAIL+1))
fi

# ============================================================================
# (FS5) `aa docs agents-md` 提到的能力 id 都真实存在于注册表
# ============================================================================
# 16 票 checkbox 2 是「真 Codex 按 `aa docs agents-md` 接入」——真 Codex 是人工项,
#   但**引导文本自己是否与当前能力面对得上**是可自动验的:别让文档指着一个不存在的能力教 agent 用。
# 判据:从引导文本里抽出形如 `<域>.<段>...` 的候选 id(只认首段是**注册表里真实存在的域**的那些,
#   于是 `error.code` / `AGENTS.md` 这类不会被误当能力 id),逐个核对必须真实存在。
#   下限守卫:一个候选都没抽到 = 抽取失效,"没发现不一致"毫无意义 → 显式 FAIL(照 MB3/APP8 同一条纪律)。
FS5_ERR=""
[ "$FS_DOCS_RC" -eq 0 ] || FS5_ERR="$FS5_ERR aa docs agents-md 退出码=$FS_DOCS_RC(期望0);"
[ -s "$FS_REG_IDS" ] || FS5_ERR="$FS5_ERR 取不到注册表能力清单(无法核对);"
if [ -z "$FS5_ERR" ]; then
  FS_DOCS_VERDICT="$(python3 - "$FS_DOCS_TXT" "$FS_REG_IDS" <<'PY' 2>/dev/null
import re, sys
docs = open(sys.argv[1], encoding="utf-8", errors="replace").read()
ids = set(x.strip() for x in open(sys.argv[2], encoding="utf-8") if x.strip())
domains = set(i.split(".")[0] for i in ids)
cands = set()
for m in re.finditer(r"\b[a-z][a-z0-9]*(?:\.[a-z][a-zA-Z0-9]*)+\b", docs):
    tok = m.group(0)
    if tok.split(".")[0] in domains:
        cands.add(tok)
missing = sorted(c for c in cands if c not in ids)
print("FSDOCS cands=%d missing=%d" % (len(cands), len(missing)))
print("  候选(注册表已有的域下): %s" % (" ".join(sorted(cands)) or "(无)"))
if missing:
    print("  注册表里不存在: %s" % " ".join(missing))
PY
)"
  echo "    docs 能力 id 核对: $(printf '%s' "$FS_DOCS_VERDICT" | tr '\n' '|')"
  FS_DOCS_CANDS="$(sed -n 's/^FSDOCS cands=\([0-9]*\) missing=.*/\1/p' <<<"$FS_DOCS_VERDICT")"
  FS_DOCS_MISSING="$(sed -n 's/^FSDOCS cands=[0-9]* missing=\([0-9]*\).*/\1/p' <<<"$FS_DOCS_VERDICT")"
  if [ -z "$FS_DOCS_CANDS" ] || [ -z "$FS_DOCS_MISSING" ]; then
    FS5_ERR="$FS5_ERR 核对器自身没给出结论行(无法核验,绝不算过);"
  else
    [ "$FS_DOCS_CANDS" -ge 1 ] || FS5_ERR="$FS5_ERR 从引导文本里一个能力 id 候选都没抽到(抽取失效,绝不算过);"
    [ "$FS_DOCS_MISSING" -eq 0 ] || FS5_ERR="$FS5_ERR 引导文本提到 $FS_DOCS_MISSING 个注册表里不存在的能力 id;"
  fi
fi
if [ -z "$FS5_ERR" ]; then
  echo "PASS: aa docs agents-md 的接入引导与实际能力面对得上 —— 文本里出现的 $FS_DOCS_CANDS 个能力 id 候选,逐个都真实存在于注册表(不会指着不存在的能力教 agent 用)"
  PASS=$((PASS+1))
else
  echo "FAIL: 接入引导与能力面对不上:$FS5_ERR"
  echo "    注册表能力清单($FS_REG_IDS):"; sed 's/^/      /' "$FS_REG_IDS" 2>/dev/null
  echo "    核对器输出:"; printf '%s\n' "${FS_DOCS_VERDICT:-(无)}" | sed 's/^/      /'
  FAIL=$((FAIL+1))
fi

# 人眼抽查落点(不读 Swift 的人也能行使监督)。
echo "    [人眼抽查] 旗舰链逐步骤明细: $FS_STEPLOG"
echo "    [人眼抽查] 旗舰链宿主日志  : $FS_HOSTLOG_CHAIN"
echo "    [人眼抽查] 窗口内 UDS 请求 : $FS_REQS"

teardown_hosts also-stub
rm -f "$FS_TAKEOVER" "$FS_TAKEOVER.recovery" "$FS_TAKEOVER.cleared" 2>/dev/null
