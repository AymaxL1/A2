#!/bin/bash
# PROTOTYPE — S2 无人值守自测。编译 → 起 S2Host（自动拒绝 5s）→ 四项断言 → 清场（不留进程）。
# 不用 set -e：要逐项收集断言结果，不能一失败就退。
set -uo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
LOG="$ROOT/.build/s2host.log"
SOCK="$HOME/Library/Application Support/S2Spike/aa.sock"
AA="$ROOT/.build/aa"
HOST="$ROOT/.build/S2Host"
KILLPAT="S2CapabilitySlice/.build/S2Host"

echo "== 编译 =="
bash run.sh || { echo "编译失败"; exit 1; }

echo "== 清理旧 S2Host =="
pkill -f "$KILLPAT" 2>/dev/null || true
sleep 1
rm -f "$SOCK"

echo "== 启动 S2Host（S2_AUTO_DENY_SECONDS=5）=="
S2_AUTO_DENY_SECONDS=5 "$HOST" > "$LOG" 2>&1 &
HOST_PID=$!

echo "== 等待 socket: $SOCK =="
for _ in $(seq 1 100); do
  [ -S "$SOCK" ] && break
  kill -0 "$HOST_PID" 2>/dev/null || { echo "S2Host 已退出，日志："; cat "$LOG"; exit 1; }
  sleep 0.2
done
if [ ! -S "$SOCK" ]; then
  echo "socket 未出现，超时。日志："; cat "$LOG"
  pkill -f "$KILLPAT" 2>/dev/null || true
  exit 1
fi
echo "socket 就绪"

PASS=0; FAIL=0
assert_exit() {   # $1 期望码 $2 实际码 $3 描述
  if [ "$1" -eq "$2" ]; then echo "PASS: $3 (exit=$2)"; PASS=$((PASS+1));
  else echo "FAIL: $3 (期望 exit=$1, 实际 $2)"; FAIL=$((FAIL+1)); fi
}
assert_contains() {  # $1 文本 $2 子串 $3 描述
  if printf '%s' "$1" | grep -q -- "$2"; then echo "PASS: $3"; PASS=$((PASS+1));
  else echo "FAIL: $3 (未找到 '$2'；实际输出: $1)"; FAIL=$((FAIL+1)); fi
}

echo "--- 断言 1: aa list 含两能力（退出0）---"
OUT="$("$AA" list 2>/dev/null)"; RC=$?
assert_exit 0 $RC "aa list 退出码"
assert_contains "$OUT" "demo.echo" "aa list 含 demo.echo"
assert_contains "$OUT" "demo.wipe" "aa list 含 demo.wipe"

echo "--- 断言 2: aa call demo.echo 回显（退出0）---"
OUT="$("$AA" call demo.echo --input '{"msg":"hi"}' 2>/dev/null)"; RC=$?
assert_exit 0 $RC "aa call demo.echo 退出码"
assert_contains "$OUT" "hi" "echo 回显含 hi"

echo "--- 断言 3: aa call demo.wipe 自动拒绝（退出2）---"
"$AA" call demo.wipe --timeout 10 >/dev/null 2>&1; RC=$?
assert_exit 2 $RC "aa call demo.wipe 自动拒绝"

echo "--- 断言 4: host 关闭后 aa call（退出4）---"
pkill -f "$KILLPAT" 2>/dev/null || true
sleep 1
"$AA" call demo.echo --input '{}' >/dev/null 2>&1; RC=$?
assert_exit 4 $RC "host 不可达"

echo
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
# 清场：确保无残留进程
pkill -f "$KILLPAT" 2>/dev/null || true
rm -f "$SOCK"
if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "有失败，见上"; exit 1; fi
