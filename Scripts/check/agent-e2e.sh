# --- agent-delegation：CLI 接线、反孤儿钩子与假 agent 全链路 ---
echo "--- 断言组 A-E2E:aa-agent CLI 与假 agent 全链路 ---"

AGENT_CLI_ROOT="$BUILD/agent-tasks-cli"
AGENT_HELP="$("$BIN/aa-agent" --help 2>&1)"; RC=$?
assert_exit 0 "$RC" "aa-agent --help 退出码 0"
assert_contains "$AGENT_HELP" "completed→0" "帮助含任务终态到退出码映射"
assert_contains "$AGENT_HELP" "永不删 running" "帮助写明 prune 不删除运行中任务"
assert_contains "$AGENT_HELP" "Claude 侧走 bypassPermissions" "帮助显式告警 Claude 文件系统边界"

"$BIN/aa-agent" run --prompt hi >/dev/null 2>&1
assert_exit 1 "$?" "run 缺 --agent 时拒绝"
"$BIN/aa-agent" status "../../etc/passwd" --root "$AGENT_CLI_ROOT" >/dev/null 2>&1
assert_exit 1 "$?" "status 拒绝路径穿越 task-id"
LIST_EMPTY="$("$BIN/aa-agent" list --root "$AGENT_CLI_ROOT" 2>/dev/null)"; RC=$?
assert_exit 0 "$RC" "不存在的任务根目录按空列表处理"
if [ ! -d "$AGENT_CLI_ROOT" ]; then
  echo "PASS: 只读命令不会创建任务根目录"; PASS=$((PASS+1))
else
  echo "FAIL: 只读命令创建了任务根目录"; FAIL=$((FAIL+1))
fi

DRY_CLAUDE="$("$BIN/aa-agent" run --agent claude --prompt hi --exec /bin/echo --root "$AGENT_CLI_ROOT" --dry-run 2>&1)"; RC=$?
assert_exit 0 "$RC" "Claude dry-run 成功"
assert_contains "$DRY_CLAUDE" "--permission-mode bypassPermissions" "Claude dry-run 强制 bypassPermissions"
assert_contains "$DRY_CLAUDE" "--strict-mcp-config" "Claude dry-run 启用严格 MCP 配置"
DRY_CODEX="$("$BIN/aa-agent" run --agent codex --prompt hi --exec /bin/echo --root "$AGENT_CLI_ROOT" --dry-run 2>&1)"; RC=$?
assert_exit 0 "$RC" "Codex dry-run 成功"
assert_contains "$DRY_CODEX" "exec --json --skip-git-repo-check --sandbox read-only" "Codex dry-run 显式使用默认只读沙箱"
assert_contains "$DRY_CODEX" "未碰 CODEX_HOME" "Codex dry-run 不创建任务私有 CODEX_HOME"

# 同一 runner 进入特殊探针模式：故意不回收进程组，验证 atexit 和 SIGTERM 钩子都能兜底。
PROBE_OUT="$(AA_ORPHAN_PROBE=exit "$TESTRUNNER" 2>&1)"; PROBE_RC=$?
PROBE_PGID="$(printf '%s\n' "$PROBE_OUT" | sed -n 's/^ORPHAN_PROBE_PGID=//p' | head -1)"
assert_exit 0 "$PROBE_RC" "反孤儿 exit 探针正常退出"
assert_contains "$PROBE_OUT" "ORPHAN_PROBE_ALIVE=1" "exit 探针退出前进程组确实存活"
if [ -n "$PROBE_PGID" ]; then
  PROBE_LEFT=""
  for _ in $(seq 1 25); do
    PROBE_LEFT="$(pgrep -g "$PROBE_PGID" 2>/dev/null)"
    [ -z "$PROBE_LEFT" ] && break
    sleep 0.2
  done
  if [ -z "$PROBE_LEFT" ]; then
    echo "PASS: atexit 钩子清空探针进程组"; PASS=$((PASS+1))
  else
    echo "FAIL: atexit 后残留进程组 $PROBE_PGID: $PROBE_LEFT"; FAIL=$((FAIL+1))
  fi
else
  echo "FAIL: exit 探针未报告进程组"; FAIL=$((FAIL+1))
fi

SIGPROBE_LOG="$BUILD/orphan-probe-signal.out"
AA_ORPHAN_PROBE=signal "$TESTRUNNER" >"$SIGPROBE_LOG" 2>&1 &
SIGPROBE_PID=$!
SIG_PGID=""
for _ in $(seq 1 100); do
  SIG_PGID="$(sed -n 's/^ORPHAN_PROBE_PGID=//p' "$SIGPROBE_LOG" 2>/dev/null | head -1)"
  [ -n "$SIG_PGID" ] && break
  kill -0 "$SIGPROBE_PID" 2>/dev/null || break
  sleep 0.2
done
if [ -n "$SIG_PGID" ] && [ -n "$(pgrep -g "$SIG_PGID" 2>/dev/null)" ]; then
  echo "PASS: SIGTERM 探针被杀前进程组确实存活"; PASS=$((PASS+1))
  kill -TERM "$SIGPROBE_PID" 2>/dev/null
  SIG_LEFT=""
  for _ in $(seq 1 25); do
    SIG_LEFT="$(pgrep -g "$SIG_PGID" 2>/dev/null)"
    [ -z "$SIG_LEFT" ] && break
    sleep 0.2
  done
  if [ -z "$SIG_LEFT" ]; then
    echo "PASS: SIGTERM 钩子清空探针进程组"; PASS=$((PASS+1))
  else
    echo "FAIL: SIGTERM 后残留进程组 $SIG_PGID: $SIG_LEFT"; FAIL=$((FAIL+1))
  fi
else
  echo "FAIL: SIGTERM 探针未建立可观察的进程组"; FAIL=$((FAIL+1))
fi
kill -KILL "$SIGPROBE_PID" 2>/dev/null
wait "$SIGPROBE_PID" 2>/dev/null

# 用 spike 的真实事件流驱动假 Claude/Codex，覆盖建工作区、拉起、归一化、落盘、收尾和报告。
FAKE_AGENT_DIR="$BUILD/fake-agents"
AGENT_E2E_ROOT="$BUILD/agent-tasks-e2e"
CLAUDE_SAMPLE="$ROOT/.scratch/agent-delegation/research/spike-claude-headless/01-baseline-readonly.stdout.ndjson"
CODEX_SAMPLE="$ROOT/.scratch/agent-delegation/research/spike-codex-exec/samples/exec1-baseline-readonly-default.stdout.jsonl"
mkdir -p "$FAKE_AGENT_DIR" "$AGENT_E2E_ROOT"
if [ ! -f "$CLAUDE_SAMPLE" ] || [ ! -f "$CODEX_SAMPLE" ]; then
  echo "FAIL: 假 agent 全链路缺少 spike 黄金样本"; FAIL=$((FAIL+1))
else
  cat >"$FAKE_AGENT_DIR/fake-claude" <<FAKESH
#!/bin/sh
cat "$CLAUDE_SAMPLE"
cat >/dev/null
FAKESH
  cat >"$FAKE_AGENT_DIR/fake-codex" <<FAKESH
#!/bin/sh
cat "$CODEX_SAMPLE"
FAKESH
  chmod +x "$FAKE_AGENT_DIR/fake-claude" "$FAKE_AGENT_DIR/fake-codex"

  START_SECONDS=$SECONDS
  CLAUDE_E2E="$("$BIN/aa-agent" run --agent claude --prompt hi --exec "$FAKE_AGENT_DIR/fake-claude" --root "$AGENT_E2E_ROOT" --idle-timeout 20 --json 2>&1)"; RC=$?
  ELAPSED=$((SECONDS - START_SECONDS))
  assert_exit 0 "$RC" "假 Claude 全链路成功"
  assert_contains "$CLAUDE_E2E" '"state":"completed"' "假 Claude 收敛到 completed"
  assert_not_contains "$CLAUDE_E2E" "看门狗判定卡死" "假 Claude 正常完成未被看门狗误杀"
  if [ "$ELAPSED" -lt 15 ]; then
    echo "PASS: 假 Claude 在 stdin 收尾后及时退出(${ELAPSED}s)"; PASS=$((PASS+1))
  else
    echo "FAIL: 假 Claude 耗时 ${ELAPSED}s，疑似未关闭 stdin"; FAIL=$((FAIL+1))
  fi
  CLAUDE_TASK="$(printf '%s' "$CLAUDE_E2E" | sed -n 's/.*"task_id":"\([^"]*\)".*/\1/p' | head -1)"
  if [ -f "$AGENT_E2E_ROOT/$CLAUDE_TASK/report.html" ] && [ -s "$AGENT_E2E_ROOT/$CLAUDE_TASK/logs/raw.ndjson" ] && [ -s "$AGENT_E2E_ROOT/$CLAUDE_TASK/logs/normalized.ndjson" ]; then
    echo "PASS: 假 Claude 产出报告及两类日志"; PASS=$((PASS+1))
  else
    echo "FAIL: 假 Claude 缺报告或日志"; FAIL=$((FAIL+1))
  fi
  assert_contains "$(cat "$AGENT_E2E_ROOT/$CLAUDE_TASK/meta.json" 2>/dev/null)" "session_id" "假 Claude meta 保留 session id"

  CODEX_E2E="$("$BIN/aa-agent" run --agent codex --prompt hi --exec "$FAKE_AGENT_DIR/fake-codex" --root "$AGENT_E2E_ROOT" --codex-home "$FAKE_AGENT_DIR/no-auth" --idle-timeout 20 --json 2>&1)"; RC=$?
  assert_exit 0 "$RC" "假 Codex 全链路成功"
  assert_contains "$CODEX_E2E" '"state":"completed"' "假 Codex 收敛到 completed"
  CODEX_TASK="$(printf '%s' "$CODEX_E2E" | sed -n 's/.*"task_id":"\([^"]*\)".*/\1/p' | head -1)"
  if [ -n "$CODEX_TASK" ] && [ ! -d "$AGENT_E2E_ROOT/$CODEX_TASK/codex-home" ]; then
    echo "PASS: 假 Codex 私有 CODEX_HOME 用后即弃"; PASS=$((PASS+1))
  else
    echo "FAIL: 假 Codex 私有 CODEX_HOME 残留"; FAIL=$((FAIL+1))
  fi
fi

RES_FAKE_AGENT="$(pgrep -f "$FAKE_AGENT_DIR/fake-" 2>/dev/null)"
if [ -z "$RES_FAKE_AGENT" ]; then
  echo "PASS: 假 agent 全链路无残留进程"; PASS=$((PASS+1))
else
  echo "FAIL: 假 agent 有残留进程: $RES_FAKE_AGENT"; FAIL=$((FAIL+1))
fi
