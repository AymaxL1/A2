#!/bin/bash
# PROJECT_AA 04 票 —— dangerous 宿主确认「真机点验」脚本(ready-for-human,需用户在场点击)。
#
# 为什么单列一个脚本:门禁 check.sh 在 headless 下靠 AA_CONFIRM_AUTO 让确认回调「不弹窗即时返回」,
# 因此自动化只覆盖了「策略是否正确路由 approve/deny」,并未真正弹出 NSAlert 让人点。
# 本脚本**不设 AA_CONFIRM_AUTO**、前台起真宿主,让你亲手点「确认执行 / 取消」,肉眼验证:
#
#   * 点「确认执行」→ 另一终端的 `aa capabilities call demo.wipe` 得 exit 0、结果 wiped=true。
#   * 点「取消」   → 该命令得 denied、exit 2。
#
# 自动化无法替你点击,故本步是 04 票 checkbox 里唯一的 ready-for-human 项;其余已由 check.sh 自动验证。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 11 票起产物由 SPM 产在 `--scratch-path` 的 bin 目录里(带三元组/配置名),不再是 .build/check/bin。
# 就地用,**别拷走**:PluginProxy 的资源是与可执行并排的 PROJECT_AA_PluginProxy.bundle,
#   MihomoKernelResource 用 `Bundle.module...!` 强解包取它,可执行一离开 bin 目录就当场崩。
# bin 目录由门禁 build.sh 用 `swift build --show-bin-path` 落档在这里(**唯一权威来源**,不猜不拼)。
BINPATH_FILE="$ROOT/.build/check/spm-bin-path.txt"
SPM_BIN="$( [ -f "$BINPATH_FILE" ] && head -1 "$BINPATH_FILE" )"
HOST_BIN="$SPM_BIN/aahost"
AA_BIN="$SPM_BIN/aa"

if [ ! -x "$HOST_BIN" ] || [ ! -x "$AA_BIN" ]; then
  echo "缺少已编译二进制($HOST_BIN / $AA_BIN)。"
  echo "请先跑一次门禁把它们编出来:  bash Scripts/check.sh"
  exit 1
fi

# 关键:清掉可能从父 shell 继承的 test-only 自动化开关,确保真弹窗、真由人决定。
unset AA_CONFIRM_AUTO
# 不设 AA_AUTO_DENY_SECONDS —— 让弹窗一直等你点,不自动拒绝。(如需夜间兜底可自行 export 一个秒数。)

cat <<EOF
========================================================================
 04 票 dangerous 宿主确认 —— 真机点验(ready-for-human)
========================================================================
 现在将【前台】启动宿主(菜单栏出现 ⚡)。它不会自动决定 dangerous 确认。

 请另开一个终端,依次执行并核对:

   # A) 批准分支:执行后宿主弹出 critical 对话框 → 点「确认执行」
   $AA_BIN capabilities call demo.wipe --input '{"target":"disk0"}'
   echo "exit=\$?"
   # 期望:stdout 打印 {"target":"disk0","wiped":true};exit=0

   # B) 拒绝分支:再次执行 → 点「取消」
   $AA_BIN capabilities call demo.wipe
   echo "exit=\$?"
   # 期望:stderr 提示 denied;exit=2

   # (旁证)safe 能力不弹窗直通:
   $AA_BIN capabilities call demo.echo --input '{"message":"hi"}'
   # 期望:{"echo":"hi"};exit=0,全程无弹窗

 观察要点(对齐 S2 已点验结论):
   * accessory app 的对话框应被 activate 带到前台;偶被遮挡时点一下菜单栏 ⚡ 或 cmd-tab。
   * 只有「确认执行」才批准;点「取消」或直接关窗都算拒绝(denied)。

 点验完成后请把结果记进下面的「记录位」(手填),按 Ctrl-C 停止宿主。
------------------------------------------------------------------------
 记录位(真机点验留痕 —— 手动填写):
   日期/机器:__________________________________
   A) 批准 → exit 0 且 wiped=true            [ ] PASS  [ ] FAIL
   B) 取消 → denied 且 exit 2                 [ ] PASS  [ ] FAIL
   旁证) demo.echo 无弹窗直通 exit 0          [ ] PASS  [ ] FAIL
   备注:____________________________________
========================================================================
EOF

echo "[启动宿主中... Ctrl-C 结束]"
exec "$HOST_BIN"
