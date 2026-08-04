#!/bin/bash
# 活体冒烟:用**真的** launchctl 把编译产物装成 user 域 agent,跑完整生命周期,再拆干净。
#
#   bash kernel/scripts/service-live-smoke.sh [产物路径]      # 默认 kernel/dist/a2
#
# 为什么这条不在 bun test 里:它真的改系统状态(launchd 里真多一个 job、真起一个进程)。
# bun test 那边用的是 PATH 里的假 supervisor,只验编排与 unit 内容。
#
# 纪律(逐条对应票面红线):
#   * **只碰 com.a2.kernel 这一个 label**,域限 gui/$UID;开跑前先确认它当前不存在,存在就直接中止
#     (那说明有别人的实例,不是我的,不许动)。
#   * HOME 与 A2_HOME 双双指向临时目录:plist 落 $TMPHOME/Library/LaunchAgents,内核数据落 $TMPHOME/a2home,
#     **用户真实的 ~/Library/LaunchAgents 与 ~/.a2 全程不被创建、不被读写**。
#   * trap 兜底:无论从哪一步退出,都 bootout + 删临时目录;末尾再逐条验残留。
set -uo pipefail
cd "$(dirname "$0")/.."

OUT_REL="${1:-dist/a2}"
A2BIN="$(cd "$(dirname "$OUT_REL")" && pwd)/$(basename "$OUT_REL")"
LABEL="com.a2.kernel"
TARGET="gui/$UID/$LABEL"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
step() { printf '\n== %s ==\n' "$1"; }

[ -x "$A2BIN" ] || { echo "找不到编译产物:$A2BIN(先跑 bash kernel/scripts/build.sh)"; exit 2; }

step "开跑前:确认 $LABEL 当前不在 launchd 里(在的话立刻中止,那不是我的)"
if launchctl print "$TARGET" >/dev/null 2>&1; then
  echo "  $TARGET 已存在 —— 本脚本拒绝动它。人工确认后再跑。"
  exit 3
fi
echo "  launchctl print $TARGET → 不存在(预期)"

TMPHOME="$(mktemp -d /tmp/a2live-XXXXXX)"
A2HOME="$TMPHOME/a2home"
PLIST="$TMPHOME/Library/LaunchAgents/$LABEL.plist"

cleanup() {
  launchctl bootout "$TARGET" >/dev/null 2>&1
  rm -rf "$TMPHOME"
}
trap cleanup EXIT INT TERM

a2() { HOME="$TMPHOME" A2_HOME="$A2HOME" "$A2BIN" "$@"; }
svc_json() { a2 service "$1" --json; }
pid_of_service() { svc_json status | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p'; }

step "1/8 未安装态"
OUT="$(svc_json status)"; RC=$?
[ "$RC" = 0 ] && ok "status 退出码 0" || bad "status 退出码 $RC"
case "$OUT" in *'"state":"not_installed"'*) ok "三态 = not_installed";; *) bad "三态不对:$OUT";; esac

step "2/8 install(真 launchctl bootstrap)"
OUT="$(svc_json install)"; RC=$?
[ "$RC" = 0 ] && ok "install 退出码 0" || bad "install 退出码 $RC — $OUT"
case "$OUT" in *'"actions":["unit_written","supervisor_loaded"]'*) ok "actions = 写 unit + 装载";; *) bad "actions 不对:$OUT";; esac
case "$OUT" in *'"state":"running"'*) ok "收敛到 running";; *) bad "没收敛到 running:$OUT";; esac
[ -f "$PLIST" ] && ok "plist 落在临时 HOME:$PLIST" || bad "plist 不在 $PLIST"
[ -z "$(ls -A "$HOME/Library/LaunchAgents" 2>/dev/null | grep -i '^com\.a2\.' || true)" ] \
  && ok "用户真实 ~/Library/LaunchAgents 无 com.a2.* 残留" || bad "用户真实 LaunchAgents 里出现了 com.a2.*"

step "3/8 launchd 真的认识它了"
if launchctl print "$TARGET" >/tmp/a2live-print.txt 2>&1; then
  ok "launchctl print $TARGET 退出码 0"
  LPID="$(sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' /tmp/a2live-print.txt | head -1)"
  [ -n "$LPID" ] && ok "launchd 报了 pid=$LPID" || bad "launchd 没报 pid"
else
  bad "launchctl print 失败"; LPID=""
fi

step "4/8 内核真的活着(a2 status 走 UDS 往返)"
OUT="$(a2 status --json)"; RC=$?
[ "$RC" = 0 ] && ok "a2 status 退出码 0" || bad "a2 status 退出码 $RC — $OUT"
SPID="$(printf '%s' "$OUT" | sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p')"
[ -n "$SPID" ] && [ "$SPID" = "$LPID" ] && ok "daemon 自报 pid=$SPID 与 launchd 的一致" || bad "pid 对不上(launchd=$LPID daemon=$SPID)"
case "$OUT" in *"$A2HOME/run/kernel.sock"*) ok "socket 在临时 A2_HOME 下";; *) bad "socket 路径不对:$OUT";; esac

step "5/8 崩溃自愈(SIGSEGV 弄死内核,launchd 按 KeepAlive.Crashed 重拉)"
# 为什么是 SIGSEGV 而不是 kill -9:`man 5 launchd.plist` 对 KeepAlive.Crashed 的定义是
# "exited due to a signal which is typically associated with a crash (SIGILL, SIGSEGV, etc.)" ——
# **本机实测:SIGSEGV / SIGABRT 都会被重拉(各等约 9s = ThrottleInterval),SIGKILL 不会**
# (launchd 把 SIGKILL 当"有人存心弄死它",不算崩溃)。systemd 的 Restart=on-failure 在这一点上更宽
# (信号致死一律算 failure),两端的这处不对称已记进 src/service/unit.ts 的注释。
kill -SEGV "$LPID" 2>/dev/null || bad "kill -SEGV $LPID 失败"
NEWPID=""
for _ in $(seq 1 50); do   # ThrottleInterval 默认 10s,给足 25s
  sleep 0.5
  CANDIDATE="$(pid_of_service)"
  if [ -n "$CANDIDATE" ] && [ "$CANDIDATE" != "$LPID" ]; then NEWPID="$CANDIDATE"; break; fi
done
[ -n "$NEWPID" ] && ok "被 SIGSEGV 杀死后由系统重拉,新 pid=$NEWPID(应用层零看门狗)" || bad "崩溃后没有被重拉"
OUT="$(a2 status --json)"
case "$OUT" in *'"state":"running"'*) ok "重拉后 daemon 照常应答 UDS";; *) bad "重拉后 status 不通:$OUT";; esac

step "6/8 install 幂等(活体)"
OUT="$(svc_json install)"; RC=$?
[ "$RC" = 0 ] && ok "重复 install 退出码 0" || bad "重复 install 退出码 $RC — $OUT"
case "$OUT" in *'"actions":[]'*) ok "actions 为空 = 什么都没改";; *) bad "重复 install 改了东西:$OUT";; esac
AFTERPID="$(pid_of_service)"
[ "$AFTERPID" = "$NEWPID" ] && ok "幂等 install 没重启进程(pid 未变)" || bad "幂等 install 把进程重启了($NEWPID → $AFTERPID)"

step "7/8 uninstall(真 bootout + 删 plist)"
OUT="$(svc_json uninstall)"; RC=$?
[ "$RC" = 0 ] && ok "uninstall 退出码 0" || bad "uninstall 退出码 $RC — $OUT"
case "$OUT" in *'"actions":["supervisor_unloaded","unit_removed"]'*) ok "actions = 卸载 + 删 unit";; *) bad "actions 不对:$OUT";; esac
case "$OUT" in *'"state":"not_installed"'*) ok "回到 not_installed";; *) bad "没回到未安装:$OUT";; esac
[ ! -f "$PLIST" ] && ok "plist 已删除" || bad "plist 还在"
launchctl print "$TARGET" >/dev/null 2>&1 && bad "launchd 里还有 $LABEL" || ok "launchctl print $TARGET → 已不存在"
sleep 0.5
[ ! -S "$A2HOME/run/kernel.sock" ] && ok "socket 文件已随进程退出被清掉" || bad "socket 残留"
OUT="$(svc_json uninstall)"
case "$OUT" in *'"actions":[]'*) ok "uninstall 幂等(第二次什么都没改)";; *) bad "重复 uninstall 不幂等:$OUT";; esac

step "8/8 清残验证(退出前的最后一道)"
launchctl print "$TARGET" >/dev/null 2>&1 && bad "launchd 残留 $LABEL" || ok "launchd 无 $LABEL"
ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep -qi '^com\.a2\.' && bad "用户 LaunchAgents 有 com.a2.* 残留" || ok "用户 ~/Library/LaunchAgents 无 com.a2.* 残留"
[ -e "$HOME/.a2" ] && bad "用户真实 ~/.a2 被创建了" || ok "用户真实 ~/.a2 仍不存在"
pgrep -f "^$A2BIN daemon run$" >/dev/null 2>&1 && bad "有 a2 孤儿进程" || ok "无 a2 孤儿进程"

rm -f /tmp/a2live-print.txt
printf '\n== 活体冒烟结束:PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
