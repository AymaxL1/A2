#!/usr/bin/env bash
# Spike driver: claude -p --output-format stream-json 无头驱动实测
# 用法: bash run.sh <scenario-number>   例如 bash run.sh 01
#
# 硬性护栏(见票 01-spike-claude-headless.md 派生任务的执行指令):
#   - 所有 claude 子进程 cwd 必须在 SANDBOX 下
#   - 每次调用都套自制超时(本机无 GNU timeout/gtimeout)
#   - 中断只对本脚本自己拉起的进程组发信号(set -m 保证独立 pgid)
set -u

CLAUDE=/usr/local/bin/claude
SPIKE_DIR="/Users/Shared/Workspaces/PROJECT_AA/.claude/worktrees/research-next/.scratch/agent-delegation/research/spike-claude-headless"
SANDBOX="$SPIKE_DIR/sandbox"
SAMPLES="$SPIKE_DIR"

mkdir -p "$SANDBOX"

# ---------- 通用: 后台起进程组 + 轮询等待 + 超时后 TERM/KILL 进程组 ----------
# run_with_timeout <cap_secs> <out_file> <err_file> <meta_file> <cmd_string>
run_with_timeout() {
  local cap="$1" out="$2" err="$3" meta="$4" cmdstr="$5"
  : > "$out"; : > "$err"
  local t0 t1 pid rc waited exited sigkill_needed
  t0=$(date +%s)
  set -m
  bash -c "$cmdstr" >"$out" 2>"$err" &
  pid=$!
  set +m
  waited=0
  exited="no"
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited+1))
    if [ "$waited" -ge "$cap" ]; then
      break
    fi
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM -"$pid" 2>/dev/null
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
      sigkill_needed="yes"
      kill -KILL -"$pid" 2>/dev/null
    else
      sigkill_needed="no(TERM足够)"
    fi
  else
    exited="yes(自然退出,未触发超时)"
    sigkill_needed="n/a"
  fi
  wait "$pid" 2>/dev/null
  rc=$?
  t1=$(date +%s)
  {
    echo "cmd: $cmdstr"
    echo "cap_secs: $cap"
    echo "waited_secs: $waited"
    echo "natural_exit: $exited"
    echo "sigkill_needed: $sigkill_needed"
    echo "exit_code: $rc"
    echo "duration_s: $((t1-t0))"
  } >> "$meta"
  echo "[run_with_timeout] rc=$rc duration=$((t1-t0))s waited=${waited}s natural_exit=$exited" >&2
}

# ---------- SIGTERM 中途打断: after_secs 后对进程组发 TERM,记录残留进程 ----------
# run_with_interrupt <after_secs> <out_file> <err_file> <meta_file> <cmd_string>
run_with_interrupt() {
  local after="$1" out="$2" err="$3" meta="$4" cmdstr="$5"
  : > "$out"; : > "$err"
  local t0 t1 pid rc mypgid
  t0=$(date +%s)
  set -m
  bash -c "$cmdstr" >"$out" 2>"$err" &
  pid=$!
  set +m
  sleep "$after"
  mypgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  {
    echo "--- process tree just before SIGTERM (pgid=$mypgid) ---"
    ps -eo pid,ppid,pgid,stat,command | awk -v g="$mypgid" 'NR==1 || $3==g'
  } >> "$meta"
  kill -TERM -"$pid" 2>/dev/null
  local term_t; term_t=$(date +%s)
  local exited="no"
  local i
  for i in 1 2 3 4 5; do
    if ! kill -0 "$pid" 2>/dev/null; then exited="yes"; break; fi
    sleep 1
  done
  local sigkill_needed="no"
  if [ "$exited" = "no" ]; then
    sigkill_needed="yes"
    kill -KILL -"$pid" 2>/dev/null
    sleep 1
  fi
  wait "$pid" 2>/dev/null
  rc=$?
  t1=$(date +%s)
  sleep 1
  {
    echo "--- process tree scan AFTER kill (searching leftover pgid=$mypgid members, should be empty) ---"
    ps -eo pid,ppid,pgid,stat,command | awk -v g="$mypgid" 'NR==1 || $3==g'
    echo "--- broader scan for any leftover 'sleep 8' anywhere (orphan check) ---"
    ps -eo pid,ppid,pgid,stat,command | grep -i 'sleep 8' | grep -v grep
    echo "cmd: $cmdstr"
    echo "term_sent_after_s: $after"
    echo "graceful_exit_before_sigkill: $exited"
    echo "sigkill_needed: $sigkill_needed"
    echo "exit_code: $rc"
    echo "total_duration_s: $((t1-t0))"
  } >> "$meta"
  echo "[run_with_interrupt] rc=$rc graceful=$exited sigkill_needed=$sigkill_needed duration=$((t1-t0))s" >&2
}

# =========================================================================
# 01: 最小只读任务 -- 事件 schema / session_id
# =========================================================================
scenario_01() {
  local dir="$SANDBOX/s1"; mkdir -p "$dir"
  local base="$SAMPLES/01-baseline-readonly"
  cd "$dir" || return 1
  local cmd="cd '$dir' && '$CLAUDE' -p 'Reply with the word OK' --output-format stream-json --verbose --permission-mode bypassPermissions --model sonnet --effort low < /dev/null"
  run_with_timeout 60 "$base.stdout.ndjson" "$base.stderr.log" "$base.meta.txt" "$cmd"
}

# =========================================================================
# 02: 工具调用(写文件) -- tool_use/tool_result 形状
# =========================================================================
scenario_02() {
  local dir="$SANDBOX/s2"; mkdir -p "$dir"
  local base="$SAMPLES/02-tool-use-bypass"
  local cmd="cd '$dir' && '$CLAUDE' -p 'Create a file named ok.txt containing the text OK' --output-format stream-json --verbose --permission-mode bypassPermissions --model sonnet --effort low < /dev/null"
  run_with_timeout 60 "$base.stdout.ndjson" "$base.stderr.log" "$base.meta.txt" "$cmd"
  {
    echo "--- ls sandbox/s2 after run ---"
    ls -la "$dir"
    echo "--- cat ok.txt (if exists) ---"
    cat "$dir/ok.txt" 2>&1
  } >> "$base.meta.txt"
}

# =========================================================================
# 03: 不加 bypass + stream-json 双向输入 -- 默认权限行为 + control_request 捕获
#     prompt 通过 stdin 的 stream-json 消息送入,且刻意不发送 EOF、不应答任何
#     control_request,观察 90s(护栏:无 bypass 观察轮上限)内的行为。
# =========================================================================
scenario_03() {
  local dir="$SANDBOX/s3"; mkdir -p "$dir"
  local base="$SAMPLES/03-no-bypass-control-request"
  local json_line='{"type":"user","message":{"role":"user","content":"Create a file named ok2.txt containing OK"}}'
  # 用 process substitution 让 stdin 长期开着(写完一行后 sleep 95s 才结束),
  # 模拟"写完 prompt 保持 stdin 打开、且不应答任何 control_request"的场景。
  local cmd="cd '$dir' && '$CLAUDE' -p --input-format stream-json --output-format stream-json --verbose --model sonnet --effort low < <(printf '%s\n' '$json_line'; sleep 95)"
  run_with_timeout 90 "$base.stdout.ndjson" "$base.stderr.log" "$base.meta.txt" "$cmd"
  {
    echo "--- ls sandbox/s3 after run (file should NOT exist if approval never granted) ---"
    ls -la "$dir"
  } >> "$base.meta.txt"
}

# =========================================================================
# 04: 中途 SIGTERM 进程组 -- 退出码/末尾事件/残留子进程
# =========================================================================
scenario_04() {
  local dir="$SANDBOX/s4"; mkdir -p "$dir"
  local base="$SAMPLES/04-sigterm-interrupt"
  local cmd="cd '$dir' && '$CLAUDE' -p 'Run the shell command: sleep 8 -- then reply with the word OK' --output-format stream-json --verbose --permission-mode bypassPermissions --model sonnet --effort low < /dev/null"
  run_with_interrupt 3 "$base.stdout.ndjson" "$base.stderr.log" "$base.meta.txt" "$cmd"
}

# =========================================================================
# 05: 失败场景 -- 不存在的 --model
# =========================================================================
scenario_05() {
  local dir="$SANDBOX/s5"; mkdir -p "$dir"
  local base="$SAMPLES/05-invalid-model"
  local cmd="cd '$dir' && '$CLAUDE' -p 'Reply with the word OK' --output-format stream-json --verbose --permission-mode bypassPermissions --model this-model-does-not-exist-xyz123 < /dev/null"
  run_with_timeout 60 "$base.stdout.ndjson" "$base.stderr.log" "$base.meta.txt" "$cmd"
}

# =========================================================================
# 06: stdin 姿态 -- prompt 走 stream-json stdin,写完后保持打开(不发 EOF),
#     观察进程是否在产出 result 后仍不退出(是否要等 stdin 关闭)。
#     cap 45s 远小于 stdin holder 的 120s,若在 45s 内自然退出即证明"不等 EOF"。
# =========================================================================
scenario_06() {
  local dir="$SANDBOX/s6"; mkdir -p "$dir"
  local base="$SAMPLES/06-stdin-keepopen"
  local json_line='{"type":"user","message":{"role":"user","content":"Reply with the word OK"}}'
  local cmd="cd '$dir' && '$CLAUDE' -p --input-format stream-json --output-format stream-json --verbose --permission-mode bypassPermissions --model sonnet --effort low < <(printf '%s\n' '$json_line'; sleep 120)"
  run_with_timeout 45 "$base.stdout.ndjson" "$base.stderr.log" "$base.meta.txt" "$cmd"
}

# =========================================================================
# 07: 工作目录约束 -- 相对路径向上越界 + 绝对路径越界
# =========================================================================
scenario_07() {
  local dir="$SANDBOX/s7"; mkdir -p "$dir"
  local base="$SAMPLES/07-cwd-escape"
  rm -f "$SANDBOX/escape_relative_from_s7.txt" /tmp/aa_spike_escape_absolute.txt
  local cmd="cd '$dir' && '$CLAUDE' -p 'Create two files: one at path ../escape_relative_from_s7.txt containing OK, and another at absolute path /tmp/aa_spike_escape_absolute.txt containing OK. Use the Write tool directly for both, do not ask for confirmation.' --output-format stream-json --verbose --permission-mode bypassPermissions --model sonnet --effort low < /dev/null"
  run_with_timeout 60 "$base.stdout.ndjson" "$base.stderr.log" "$base.meta.txt" "$cmd"
  {
    echo "--- escape probe results ---"
    echo "relative escape (SANDBOX/escape_relative_from_s7.txt):"
    ls -la "$SANDBOX/escape_relative_from_s7.txt" 2>&1
    cat "$SANDBOX/escape_relative_from_s7.txt" 2>&1
    echo "absolute escape (/tmp/aa_spike_escape_absolute.txt):"
    ls -la /tmp/aa_spike_escape_absolute.txt 2>&1
    cat /tmp/aa_spike_escape_absolute.txt 2>&1
  } >> "$base.meta.txt"
}

# =========================================================================
# 08: SIGTERM 补测 -- 06 秒后打断(经验值:ttft~4-5.6s),力求命中"Bash 工具
#     正在跑 sleep 8"这个真实子进程存活期间,而不是命中首 token 之前。
#     核对:嵌套子进程(sleep 8)是否随进程组一起被清干净。
# =========================================================================
scenario_08() {
  local dir="$SANDBOX/s8"; mkdir -p "$dir"
  local base="$SAMPLES/08-sigterm-mid-tool"
  local cmd="cd '$dir' && '$CLAUDE' -p 'Run the shell command: sleep 8 -- then reply with the word OK' --output-format stream-json --verbose --permission-mode bypassPermissions --model sonnet --effort low < /dev/null"
  run_with_interrupt 6 "$base.stdout.ndjson" "$base.stderr.log" "$base.meta.txt" "$cmd"
}

case "${1:-}" in
  01) scenario_01 ;;
  02) scenario_02 ;;
  03) scenario_03 ;;
  04) scenario_04 ;;
  05) scenario_05 ;;
  06) scenario_06 ;;
  07) scenario_07 ;;
  08) scenario_08 ;;
  *) echo "usage: bash run.sh {01..08}" >&2; exit 2 ;;
esac
