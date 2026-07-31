#!/bin/bash
# ============================================================================
#  ⚠️  真跑 agent 的端到端冒烟 —— 手动执行,需要人在场。Scripts/check.sh 绝不调用本脚本。
# ============================================================================
#
#  跑之前请把下面四条读完:
#
#  1. **会花真钱**。本脚本会真的拉起 claude / codex 各跑一个最小任务,消耗你的真实配额
#     (01 spike 的 8 次调用累计约 $0.372;本脚本两次任务的量级远小于此,但不是零)。
#
#  2. **Claude 侧对文件系统没有隔离**。适配层给 claude 的是 `--permission-mode bypassPermissions`,
#     那是「全放行 / 无差别拒绝」的两态开关,**没有「仅放行 cwd 内」的中间档**(01 spike 第 3 题)。
#     实证结论(第 7 题):bypass 下相对路径 `../` 越界写与绝对路径 `/tmp/…` 越界写**都会成功**,
#     无拒绝、无提示,事件形状与 cwd 内的正常写完全一致。**cwd 不是安全边界**。
#     故本脚本给 Claude 的任务是**只读诊断**,且工作目录是一个专门建出来的空沙箱目录。
#     即便如此,agent 理论上仍能写到沙箱之外 —— 请在一台你愿意承担这个风险的机器上跑,并盯着它。
#
#  3. **Codex 侧有真沙箱**(默认 read-only 档),与 Claude 不对称。本脚本用默认只读档。
#     每个任务用独立的 `$CODEX_HOME`(只拷 `auth.json`,**绝不**拷 `config.toml` —— 你的真配置里写着
#     `sandbox_mode = "danger-full-access"`,拷过去等于把沙箱关掉),任务结束后该目录连同其中的
#     auth.json 副本一起被删掉。
#
#  4. **无人值守时不要跑**。它会拉起真进程、写真文件、花真钱。
#
#  用法:
#      bash Scripts/agent-smoke.sh              # 两家都跑
#      bash Scripts/agent-smoke.sh claude       # 只跑 Claude
#      bash Scripts/agent-smoke.sh codex        # 只跑 Codex
#
#  前置:先跑一次 `bash Scripts/check.sh` 把 aa-agent 编出来(产物在 .build/check/bin/aa-agent)。
#
#  ---------------------------------------------------------------------------
#  第 0 步(**本脚本会自动做,但结论要你亲自看**):核对两个**未经本机二进制验证**的 Claude 旗标。
#    `--strict-mcp-config` 与 `--allowedTools` 是 01 spike findings 第 7 条要求的能力面收紧,
#    但那 8 次样本**一次都没带过它们**(findings 里写的还是笼统的「--tools」)。
#    拼写以 Claude Code CLI 参考手册为准;万一拼错,claude 会以用法错立刻退出(fail-fast 且可见,
#    不会静默把能力面放开)。下面的 grep 是这两个旗标真值化的唯一场合 —— 它需要跑一次 `claude --help`。
#  ---------------------------------------------------------------------------

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/.build/check/bin/aa-agent"
SMOKE="$ROOT/.build/agent-smoke"          # 沙箱工作目录 + 任务工作区都落在这里(不进仓库)
TASKS_ROOT="$SMOKE/agent-tasks"
SANDBOX="$SMOKE/sandbox"
WHICH="${1:-both}"

if [ ! -x "$CLI" ]; then
  echo "找不到 aa-agent:$CLI"
  echo "先跑:bash Scripts/check.sh"
  exit 1
fi

cat <<'WARN'
============================================================
 ⚠️  这一步会真的拉起 claude / codex,消耗真实配额与费用。
 ⚠️  Claude 走 bypassPermissions,对文件系统没有隔离(../ 与 /tmp/… 越界写均会成功)。
 ⚠️  请确认你在场、且愿意在这台机器上承担该风险。
============================================================
WARN
printf "键入 yes 继续:"
read -r CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "已取消(什么都没跑)。"; exit 1; }

mkdir -p "$SANDBOX" "$TASKS_ROOT"
PASS=0; FAIL=0
note_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
note_fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# 第 0 步:两个未验证旗标的真值化(只跑 --help,不产生任何任务)
# ---------------------------------------------------------------------------
if [ "$WHICH" = "both" ] || [ "$WHICH" = "claude" ]; then
  echo "--- 第 0 步:核对 claude 的两个能力面旗标(只跑 --help)---"
  CLAUDE_BIN="$(command -v claude || echo /usr/local/bin/claude)"
  if [ -x "$CLAUDE_BIN" ]; then
    CH="$("$CLAUDE_BIN" --help 2>&1)"
    printf '%s' "$CH" | grep -F -- "--strict-mcp-config" >/dev/null \
      && note_pass "claude --help 里有 --strict-mcp-config" \
      || note_fail "claude --help 里**没有** --strict-mcp-config —— 组装器要改拼写(见 AgentLaunchAssembler 文件头)"
    printf '%s' "$CH" | grep -F -- "--allowedTools" >/dev/null \
      && note_pass "claude --help 里有 --allowedTools" \
      || note_fail "claude --help 里**没有** --allowedTools —— 组装器要改拼写(可能是 --allowed-tools 或 --tools)"
  else
    note_fail "找不到 claude 可执行,无法核对旗标"
  fi
fi

# ---------------------------------------------------------------------------
# 冒烟一:Claude —— **只读诊断**任务(不要求它写任何文件)
# ---------------------------------------------------------------------------
run_claude() {
  echo "--- 冒烟一:Claude 只读诊断任务(真调用,真花钱)---"
  OUT="$("$CLI" run \
      --agent claude \
      --prompt "List the files in the current directory and reply with ONLY the integer count. Do not create or modify any file." \
      --workdir "$SANDBOX" \
      --root "$TASKS_ROOT" \
      --idle-timeout 180 \
      --json 2>&1)"
  RC=$?
  echo "$OUT"
  [ $RC -eq 0 ] && note_pass "Claude 任务退出码 0(终态 completed)" || note_fail "Claude 任务退出码 $RC(期望 0)"
  TASK="$(printf '%s' "$OUT" | sed -n 's/.*"task_id":"\([^"]*\)".*/\1/p' | head -1)"
  if [ -n "$TASK" ]; then
    note_pass "Claude 任务产出了 task-id:$TASK"
    [ -f "$TASKS_ROOT/$TASK/report.html" ] \
      && note_pass "report.html 已产出:$TASKS_ROOT/$TASK/report.html" \
      || note_fail "report.html 缺失(04 票的兜底路径没走到)"
    [ -s "$TASKS_ROOT/$TASK/logs/raw.ndjson" ] \
      && note_pass "raw.ndjson 非空(agent 原话留下了)" || note_fail "raw.ndjson 是空的"
    [ -s "$TASKS_ROOT/$TASK/logs/normalized.ndjson" ] \
      && note_pass "normalized.ndjson 非空(归一化落盘了)" || note_fail "normalized.ndjson 是空的"
    grep -F '"state" : "completed"' "$TASKS_ROOT/$TASK/meta.json" >/dev/null 2>&1 \
      && note_pass "meta.json 的 state 是 completed" \
      || note_fail "meta.json 的 state 不是 completed(看 $TASKS_ROOT/$TASK/meta.json 的 error 字段)"
  else
    note_fail "没从 --json 输出里解出 task_id"
  fi
}

# ---------------------------------------------------------------------------
# 冒烟二:Codex —— 最小只读任务(默认 read-only 沙箱档)
# ---------------------------------------------------------------------------
run_codex() {
  echo "--- 冒烟二:Codex 最小只读任务(真调用,真花钱)---"
  OUT="$("$CLI" run \
      --agent codex \
      --prompt "Reply with ONLY the word OK." \
      --workdir "$SANDBOX" \
      --root "$TASKS_ROOT" \
      --sandbox read-only \
      --idle-timeout 180 \
      --json 2>&1)"
  RC=$?
  echo "$OUT"
  [ $RC -eq 0 ] && note_pass "Codex 任务退出码 0(终态 completed)" || note_fail "Codex 任务退出码 $RC(期望 0)"
  TASK="$(printf '%s' "$OUT" | sed -n 's/.*"task_id":"\([^"]*\)".*/\1/p' | head -1)"
  if [ -n "$TASK" ]; then
    note_pass "Codex 任务产出了 task-id:$TASK"
    [ -f "$TASKS_ROOT/$TASK/report.html" ] \
      && note_pass "report.html 已产出:$TASKS_ROOT/$TASK/report.html" \
      || note_fail "report.html 缺失"
    # 每任务独立 CODEX_HOME 必须用完即弃 —— 它里面有一份你的 auth.json 副本。
    [ ! -d "$TASKS_ROOT/$TASK/codex-home" ] \
      && note_pass "任务私有 CODEX_HOME 已清理(auth.json 副本没留在磁盘上)" \
      || note_fail "任务私有 CODEX_HOME 还在:$TASKS_ROOT/$TASK/codex-home(里面有 auth.json 副本,请手工删除)"
  else
    note_fail "没从 --json 输出里解出 task_id"
  fi
}

case "$WHICH" in
  claude) run_claude ;;
  codex)  run_codex ;;
  both)   run_claude; run_codex ;;
  *) echo "用法:bash Scripts/agent-smoke.sh [claude|codex|both]"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# 管理面顺带过一遍(只读,不花钱)
# ---------------------------------------------------------------------------
echo "--- 管理面:list / status(只读)---"
"$CLI" list --root "$TASKS_ROOT"

echo
echo "===================================="
echo " 冒烟结果:PASS=$PASS  FAIL=$FAIL"
echo " 任务工作区:$TASKS_ROOT"
echo " 清理:rm -rf \"$SMOKE\"(或 aa-agent prune --root \"$TASKS_ROOT\" --keep 0)"
echo "===================================="
[ "$FAIL" -eq 0 ] || exit 1

# ---------------------------------------------------------------------------
# 仍未覆盖(ready-for-human,本脚本**不**做,别当它做过了):
#   * 旗舰验收辞点验:委托一次经 `aa demo.note.set` 的可逆改动零打断 + 一次经 `aa demo.wipe` 的
#     dangerous 改动触发宿主确认且拒绝分支能挡住。那需要 **AA 宿主在跑 + 真 agent + 用户在场点确认**,
#     三者缺一不可,故只能人工做。
#   * 取消路径的真进程验证(`aa-agent cancel` 打断一个真在跑的 claude/codex,核验终态与整组零残留)。
#     它同样要真拉起 agent;真做时请另开一个终端跑 `aa-agent cancel <task-id>`,并用
#     `pgrep -g <pgid>` 核验整组已清空。
#   * **能力面收紧是否真生效(CR 记的一笔,别把上面第 0 步当成它的答案)**:第 0 步的 grep 只证明
#     `--strict-mcp-config` / `--allowedTools` 这两个旗标**拼写存在**,证明不了「白名单之外的工具真的用不了」。
#     值得怀疑的具体点:`--allowedTools` 在 Claude Code 里的语义是「免询问放行清单」,而我们同时给了
#     `--permission-mode bypassPermissions`(本来就全放行)—— 两者叠加时它很可能**一个工具都没挡掉**,
#     被委托 agent 照样能用 Task / SendMessage 派子代理。门禁里断言组 1i 的「能力面只能收紧不能放开」
#     断的是 **argv 组得对**,不是**现实里真被挡住**,两者别混为一谈。
#     真值化的做法(需人在场):委托一个「请调用 Task 工具派一个子代理」的任务,看事件流里它是被拒绝
#     还是照做了。若照做,说明白名单在 bypass 下无效,应改用 `--disallowedTools` 硬拒名单
#     (该旗标语义是硬拒,方向安全),并把结论回填 AgentLaunchAssembler 文件头那段「未经本机二进制验证」。
# ---------------------------------------------------------------------------
