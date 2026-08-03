# --- 断言组 R:跑完清场核验(无残留宿主 / stub / 假监听器)---
echo "--- 断言组 R:跑完清场核验(无残留)---"
sleep 1
# 两个宿主都要盯:11 票之前 PROD_HOST_BIN 是 "$BIN/aahost-production-e2e",与 KILLPAT("$BIN/aahost")
#   构成子串关系,一条 pgrep 顺带覆盖了两者;现在它们在**两个不同的 scratch bin 目录**下、同名 aahost,
#   子串关系没了,故显式并起来查,保持这条断言的覆盖面与 11 票之前一致(仍是 1 条断言)。
#
# **守卫不可用时必须显式判 FAIL,绝不能静默算过。** KILLPAT / PROD_HOST_BIN 由 build.sh 现场赋值,
#   若它们为空,`pgrep -f ""` 的空模式会匹配到所有进程 —— 但反过来「因为变量空所以跳过 pgrep」会让
#   $RES_HOST 恒为空,于是打出「PASS: 无残留宿主进程」:**核验根本没做,却报了个绿**。
#   这正是本仓库明令禁止的「白送 PASS」(与断言组 3a「grep 守卫自身出错…绝不算过」同一口径)。
#   故拆成两支:变量齐 → 真查;变量缺 → 直接 FAIL 并说明原因。两支都恰好记 1 条,总数不变。
#
# 12 票起还要盯**第三、第四个宿主路径**:`.app` 里那个 aahost(e2e 档与 production 档各一个,
#   在 $BUILD/app-*/AA.app/Contents/MacOS/ 下)。它们与 $KILLPAT / $PROD_HOST_BIN 是三条互不含子串的
#   绝对路径,一条 pgrep 覆盖不了,必须并起来查(仍只记 1 条断言,覆盖面变宽、总数不变)。
#   production 档按硬约束**从不启动**,把它也列进来是纵深防御:哪天有人破了那条约束,这里会当场亮红。
#   它们由 bootstrap.sh 从 $BUILD 派生(静态常量、恒非空),但仍纳入下面的空值守卫 ——
#   将来若有人把它们改成动态赋值,这条守卫会继续拦住「变量空 → pgrep 空模式 → 白送 PASS」那条路。
if [ -z "${KILLPAT:-}" ] || [ -z "${PROD_HOST_BIN:-}" ] || [ -z "${APP_E2E_HOST_BIN:-}" ] || [ -z "${APP_PROD_HOST_BIN:-}" ]; then
  echo "FAIL: 宿主路径变量缺失(KILLPAT='${KILLPAT:-}' PROD_HOST_BIN='${PROD_HOST_BIN:-}' APP_E2E_HOST_BIN='${APP_E2E_HOST_BIN:-}' APP_PROD_HOST_BIN='${APP_PROD_HOST_BIN:-}'),无法核验残留宿主 —— 绝不算过"; FAIL=$((FAIL+1))
else
  RES_HOST="$( { pgrep -f "$KILLPAT"; pgrep -f "$PROD_HOST_BIN"; pgrep -f "$APP_E2E_HOST_BIN"; pgrep -f "$APP_PROD_HOST_BIN"; } 2>/dev/null; true )"
  if [ -z "$RES_HOST" ]; then echo "PASS: 无残留宿主进程(含 .app 内的 aahost)"; PASS=$((PASS+1)); else echo "FAIL: 残留宿主进程: $RES_HOST"; FAIL=$((FAIL+1)); fi
fi
# 以下三个模式是 bootstrap.sh 里的**静态常量**(在 trap 装上之前就已赋值,不可能为空),故直接用,不需要守卫。
RES_STUB="$(pgrep -f "$KILLPAT_STUB" 2>/dev/null; true)"
RES_LIS="$(pgrep -f "timeout_listener.py")"
if [ -z "$RES_STUB" ]; then echo "PASS: 无残留 fake mihomo stub 进程"; PASS=$((PASS+1)); else echo "FAIL: 残留 stub 进程: $RES_STUB"; FAIL=$((FAIL+1)); fi
if [ -z "$RES_LIS" ]; then echo "PASS: 无残留超时假监听器进程"; PASS=$((PASS+1)); else echo "FAIL: 残留假监听器: $RES_LIS"; FAIL=$((FAIL+1)); fi
RES_AGENT_SLEEP="$( { pgrep -f "$AGENT_SLEEP_SUITE"; pgrep -f "$AGENT_SLEEP_PROBE"; } 2>/dev/null; true )"
if [ -z "$RES_AGENT_SLEEP" ]; then echo "PASS: 无残留 agent 被测子进程"; PASS=$((PASS+1)); else echo "FAIL: 残留 agent 被测子进程: $RES_AGENT_SLEEP"; FAIL=$((FAIL+1)); fi
# 10:订阅 http 假源按 PID 核验已收场(不残留);SUB5 内已 kill+等真死,此处兜底核验。
if [ -n "${SUBHTTP_PID:-}" ] && kill -0 "$SUBHTTP_PID" 2>/dev/null; then echo "FAIL: 残留订阅 http 假源进程: $SUBHTTP_PID"; FAIL=$((FAIL+1)); else echo "PASS: 无残留订阅 http 假源进程(按 PID 收场)"; PASS=$((PASS+1)); fi

# 12:**用户自己的 mihomo 未被误伤的证明**(跑前后不在本仓库树内的 mihomo pid 集合一致)。
#   这台机器上那份 /usr/local/bin/mihomo 很可能就是当下的上网通道,掐掉它 = 断网。
#   门禁只起停仓库自带的锁版内核(同名不同文件),这条把「只碰自己那份」从人工纪律变成断言。
#   见 bootstrap.sh 里 foreign_mihomo_pids() 上方的完整说明(含已知误报场景)。
FOREIGN_MIHOMO_AFTER="$(foreign_mihomo_pids)"
case "$FOREIGN_MIHOMO_BEFORE$FOREIGN_MIHOMO_AFTER" in
  # 守卫自身坏掉时必须显式判 FAIL:否则「pgrep 出错 → 前后都空 → 一致 → PASS」又是一次白送,
  #   而这条守的恰恰是「别把用户的网络掐了」,是最不能白送的一条。
  *PGREP_ERROR*|*PS_ERROR*)
    echo "FAIL: 外部 mihomo 守卫自身出错,无法核验是否误伤用户内核 —— 绝不算过(before=[$FOREIGN_MIHOMO_BEFORE] after=[$FOREIGN_MIHOMO_AFTER])"; FAIL=$((FAIL+1)) ;;
  *)
    if [ "$FOREIGN_MIHOMO_BEFORE" = "$FOREIGN_MIHOMO_AFTER" ]; then
      echo "PASS: 未触碰仓库外的 mihomo 进程(跑前后一致: [${FOREIGN_MIHOMO_BEFORE:-无}])"; PASS=$((PASS+1))
    else
      echo "FAIL: 仓库外的 mihomo 进程集合发生变化 —— 门禁可能误伤了用户自己的内核(before=[$FOREIGN_MIHOMO_BEFORE] after=[$FOREIGN_MIHOMO_AFTER])"; FAIL=$((FAIL+1))
    fi ;;
esac

# 08:未污染真实 AppSupport 接管态文件的证明(跑前后 md5 一致;所有测试宿主的持久化都被 env seam 导向 $BUILD 临时区)。
REAL_TAKEOVER_AFTER="$( [ -e "$REAL_TAKEOVER" ] && md5 -q "$REAL_TAKEOVER" 2>/dev/null || echo ABSENT )"
if [ "$REAL_TAKEOVER_BEFORE" = "$REAL_TAKEOVER_AFTER" ]; then echo "PASS: 未污染真实 AppSupport 接管态文件(跑前后一致: $REAL_TAKEOVER_AFTER)"; PASS=$((PASS+1)); else echo "FAIL: 真实 AppSupport 接管态文件被本次运行改动(before=$REAL_TAKEOVER_BEFORE after=$REAL_TAKEOVER_AFTER)"; FAIL=$((FAIL+1)); fi
REAL_TAKEOVER_RECOVERY_AFTER="$( [ -e "$REAL_TAKEOVER_RECOVERY" ] && md5 -q "$REAL_TAKEOVER_RECOVERY" 2>/dev/null || echo ABSENT )"
if [ "$REAL_TAKEOVER_RECOVERY_BEFORE" = "$REAL_TAKEOVER_RECOVERY_AFTER" ]; then echo "PASS: 未污染真实 AppSupport 接管态恢复副本(跑前后一致: $REAL_TAKEOVER_RECOVERY_AFTER)"; PASS=$((PASS+1)); else echo "FAIL: 真实 AppSupport 接管态恢复副本被本次运行改动(before=$REAL_TAKEOVER_RECOVERY_BEFORE after=$REAL_TAKEOVER_RECOVERY_AFTER)"; FAIL=$((FAIL+1)); fi
REAL_TAKEOVER_CLEARED_AFTER="$( [ -e "$REAL_TAKEOVER_CLEARED" ] && md5 -q "$REAL_TAKEOVER_CLEARED" 2>/dev/null || echo ABSENT )"
if [ "$REAL_TAKEOVER_CLEARED_BEFORE" = "$REAL_TAKEOVER_CLEARED_AFTER" ]; then echo "PASS: 未污染真实 AppSupport 接管态 tombstone(跑前后一致: $REAL_TAKEOVER_CLEARED_AFTER)"; PASS=$((PASS+1)); else echo "FAIL: 真实 AppSupport 接管态 tombstone 被本次运行改动(before=$REAL_TAKEOVER_CLEARED_BEFORE after=$REAL_TAKEOVER_CLEARED_AFTER)"; FAIL=$((FAIL+1)); fi
# 10:未污染真实 AppSupport 订阅目录的证明(所有测试宿主的订阅目录都被 env seam 导向 $BUILD 临时区)。
REAL_SUBS_AFTER="$( [ -e "$REAL_SUBS_DIR" ] && ls -laR "$REAL_SUBS_DIR" 2>/dev/null | md5 2>/dev/null || echo ABSENT )"
if [ "$REAL_SUBS_BEFORE" = "$REAL_SUBS_AFTER" ]; then echo "PASS: 未污染真实 AppSupport 订阅目录(跑前后一致)"; PASS=$((PASS+1)); else echo "FAIL: 真实 AppSupport 订阅目录被本次运行改动(before=$REAL_SUBS_BEFORE after=$REAL_SUBS_AFTER)"; FAIL=$((FAIL+1)); fi

echo
echo "========================================"
echo " 结果: PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo " ALL PASS ✅"
  echo "========================================"
  exit 0
else
  echo " 有失败,见上 ❌"
  echo "========================================"
  exit 1
fi
