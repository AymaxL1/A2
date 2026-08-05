#!/bin/bash
# PROJECT_AA 门禁 —— 一条命令的红绿循环入口。
#
# ============================================================================
# 接口契约(11 票立、10 票换引擎时**逐字不变**)
# ============================================================================
#   一条命令跑完、任一步失败即非零退出;终端有清楚的 PASS/FAIL 输出。
# 入口路径也不变(`bash Scripts/check.sh`)—— 换的是**实现**,不是接口。这与 11 票
# 「换引擎而接口不变」是同一种安排:任何记着这条命令的人/脚本/文档都不必改。
#
# ============================================================================
# 引擎(10 票起):**TS 门禁四件套**
# ============================================================================
#   ① `bun test`(kernel/)  —— CLI 面为主战场:argv 进、stdout JSON / 退出码出。
#                              **契约金标的 TS 半边**在这一步里(`contract-golden.test.ts`)。
#   ② `swift test`          —— 契约金标的 **Swift 半边**(同一批样本、手写 Codable 对照 + 词表对账)
#                              + 客户端协议逻辑 + 壳纯逻辑 + **壳快照**(离屏渲染 × 入库 golden)。
#   ③ 旗舰 e2e              —— `Scripts/a2-flagship-e2e.sh`:真 `a2` bin + 假 mihomo + 壳的真代码路径,
#                              旗舰链零打断 / dangerous 三收场 / 壳退出仅断连 / 显式还原。
#   ④ `.app` 出包           —— `Scripts/build-app.sh`:以 **a2-panel** 身份组 bundle + ad-hoc 签名,
#                              并核验包结构与签名(证书 / TCC / 公证是人工项,顺延不阻塞)。
#
#   另加两条**便宜且能挡真事**的静态关:`bun x tsc --noEmit`(TS 类型漂移)与
#   `swift build` 零 warning(Swift 侧)。它们此前分别在 nightlog 与旧 `check/build.sh` 里,
#   本票收进同一条命令 —— 少一处「要另外记得跑」的东西。
#
# ============================================================================
# 10 票退役了什么(旧引擎)
# ============================================================================
# `Scripts/check/` 整棵(15 个模块、429 条断言)随旧 Swift 逻辑面一并退场。
# 每一条旧断言的落定(映射 / 合并 / 淘汰 / 顺延)逐条写在 `kernel/test/swift-parity-map.md`,
# 其中「10 票收口」一节是本次退场那批。**不许有悬账**:那张表就是这次退场的账本。
#
# 环境:
#   swift —— 现场探测一份 **SPM 可用**的(判据:`swift package dump-package` rc=0)。
#   bun   —— PATH 或 `~/.bun/bin/bun`。
#   env seam:`AA_SWIFT`(指定 swift 绝对路径)、`A2_BIN` / `A2_SOURCE`(旗舰 e2e 的被测体形态)。
#
# 不用 set -e:每一步显式判错并收集结果,最后统一报告 —— 一失败就退会让"还有哪几步没跑"变成猜谜。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)/.."
ROOT="$(cd "$ROOT" && pwd)"
cd "$ROOT"

BUILD="$ROOT/.build/check"
mkdir -p "$BUILD"

STEPS_OK=0
STEPS_FAIL=0
FAILED_NAMES=()

step_pass() { echo "PASS: $1"; STEPS_OK=$((STEPS_OK+1)); }
step_fail() { echo "FAIL: $1"; STEPS_FAIL=$((STEPS_FAIL+1)); FAILED_NAMES+=("$1"); }

# 跑一步:成功即 PASS,失败即 FAIL 并把日志尾部打出来(吞掉诊断信息是门禁最不该干的事)。
run_step() {  # $1=名字  $2=日志文件  剩下=命令
  local name="$1" log="$2"; shift 2
  echo
  echo "==== $name ===="
  "$@" >"$log" 2>&1
  local rc=$?
  if [ $rc -eq 0 ]; then
    step_pass "$name"
  else
    step_fail "$name(exit=$rc)"
    echo "  日志:$log(尾部 40 行)"
    tail -40 "$log" | sed 's/^/    /'
  fi
  return $rc
}

echo "========================================"
echo " PROJECT_AA check.sh —— TS 门禁四件套"
echo " ROOT = $ROOT"
echo "========================================"

# ---- 工具链探测 ------------------------------------------------------------------------
# swift 的判据只有一条:**`swift package dump-package` 能 rc=0**。它要求真正加载
#   libPackageDescription 并解析清单 —— 坏 CLT 的那份 dylib 与其 .swiftmodule 接口错配,这一步必 rc≠0。
SWIFT_BIN=""
SWIFT_PROBE_REPORT=""
PROBE_I=0
SWIFT_CANDIDATES=()
[ -n "${AA_SWIFT:-}" ] && SWIFT_CANDIDATES+=("$AA_SWIFT")
SWIFT_CANDIDATES+=("$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift")
SWIFT_CANDIDATES+=("swift")
for cand in "${SWIFT_CANDIDATES[@]}"; do
  PROBE_I=$((PROBE_I+1))
  if ! command -v "$cand" >/dev/null 2>&1 && [ ! -x "$cand" ]; then
    SWIFT_PROBE_REPORT="$SWIFT_PROBE_REPORT
  [$PROBE_I] $cand —— 不存在 / 不可执行"
    continue
  fi
  if "$cand" package dump-package --scratch-path "$BUILD/toolchain-probe" \
       >"$BUILD/dump-$PROBE_I.log" 2>&1; then
    SWIFT_BIN="$cand"; break
  fi
  SWIFT_PROBE_REPORT="$SWIFT_PROBE_REPORT
  [$PROBE_I] $cand —— \`swift package dump-package\` rc≠0(SPM 不可用),日志:$BUILD/dump-$PROBE_I.log"
done
if [ -z "$SWIFT_BIN" ]; then
  echo "FAIL: 找不到 SPM 可用的 swift —— 壳侧门禁的引擎是 swift build + swift test。"
  echo "  已试候选:$SWIFT_PROBE_REPORT"
  echo
  echo "  最常见原因:CLT 自带的 SPM 是坏的(libPackageDescription.dylib 与其 .swiftmodule 接口错配)。"
  echo "  解法是装一份官方独立工具链到家目录(**不需要 Xcode,也不需要 sudo**):"
  echo "    curl -O https://download.swift.org/swift-6.1.2-release/xcode/swift-6.1.2-RELEASE/swift-6.1.2-RELEASE-osx.pkg"
  echo "    installer -pkg ~/Downloads/swift-6.1.2-RELEASE-osx.pkg -target CurrentUserHomeDirectory"
  echo "  也可用 AA_SWIFT=<swift 绝对路径> 显式指定。"
  exit 1
fi
export AA_SWIFT="$SWIFT_BIN"   # 下游脚本(build-app.sh / a2-flagship-e2e.sh)直接用,不重复探测

BUN_BIN="$(command -v bun 2>/dev/null)"
[ -z "$BUN_BIN" ] && [ -x "$HOME/.bun/bin/bun" ] && BUN_BIN="$HOME/.bun/bin/bun"
if [ -z "$BUN_BIN" ]; then
  echo "FAIL: 找不到 bun —— 内核是 TS(ADR 0010),没有它跑不了 ① ③ 两步。"
  echo "  装法:curl -fsSL https://bun.sh/install | bash(装完 bun 在 ~/.bun/bin/bun)"
  exit 1
fi

echo " swift = $SWIFT_BIN"
echo " 版本  = $("$SWIFT_BIN" --version 2>/dev/null | head -1)"
echo " bun   = $BUN_BIN($("$BUN_BIN" --version 2>/dev/null))"
echo " 引擎  = bun test + swift test + 旗舰 e2e + .app 出包"
echo "========================================"

# ---- ⓪ 静态关:TS 类型 ------------------------------------------------------------------
run_step "⓪a TS 类型检查(tsc --noEmit)" "$BUILD/tsc.log" \
  env -C "$ROOT/kernel" "$BUN_BIN" x tsc --noEmit

# ---- ⓪b 静态关:Swift 构建零 warning ----------------------------------------------------
# 单独一步而不是让 `swift test` 顺带编:`swift test` 的输出里 warning 会被淹没在用例流水里,
#   而「零 warning」是本仓库自 11 票起的既有口径,值得有一条自己的红绿。
echo
echo "==== ⓪b Swift 构建零 warning ===="
"$SWIFT_BIN" build --scratch-path "$BUILD/spm" >"$BUILD/swift-build.log" 2>&1
SWIFT_BUILD_RC=$?
# `grep -c` 没匹配时输出 0 并以 rc=1 退出 —— **不能**再补一个 `|| echo 0`,
#   那会让变量变成 "0\n0",`[ ... -ne 0 ]` 当场语法错。
SWIFT_WARNINGS="$(grep -c ': warning:' "$BUILD/swift-build.log" 2>/dev/null)"
SWIFT_WARNINGS="${SWIFT_WARNINGS:-0}"
if [ $SWIFT_BUILD_RC -ne 0 ]; then
  step_fail "⓪b swift build 失败(exit=$SWIFT_BUILD_RC)"
  tail -40 "$BUILD/swift-build.log" | sed 's/^/    /'
elif [ "$SWIFT_WARNINGS" -ne 0 ]; then
  step_fail "⓪b swift build 有 $SWIFT_WARNINGS 条 warning(口径:零 warning)"
  grep ': warning:' "$BUILD/swift-build.log" | head -20 | sed 's/^/    /'
else
  step_pass "⓪b swift build 通过且零 warning"
fi

# ---- ① bun test(内核 CLI 面 + 契约金标 TS 半边)----------------------------------------
# **两种被测体各跑一遍**是内核侧自 07 票起的纪律,但那要先有编译产物;这里跑的是源码入口那一遍
#   (产物那一遍由 `kernel/scripts/build.sh` 之后的显式复跑负责,不进这条命令 ——
#   编译一次 60MiB 的单文件要十几秒,门禁不为它买单)。
run_step "① bun test(内核 CLI 面 + 契约金标 TS 半边)" "$BUILD/bun-test.log" \
  env -C "$ROOT/kernel" "$BUN_BIN" test

# ---- ② swift test(契约金标 Swift 半边 + 客户端协议 + 壳纯逻辑 + 壳快照)-----------------
# `--no-parallel`:壳快照要在主 actor 上做离屏渲染,而并行调度下 09 票撞过一次时序 flake。
#   顺带让失败输出按顺序可读。代价是慢几秒 —— 这批用例本来就只有几百毫秒。
run_step "② swift test(契约金标 Swift 半边 + 客户端协议 + 壳纯逻辑 + 壳快照)" "$BUILD/swift-test.log" \
  "$SWIFT_BIN" test --scratch-path "$BUILD/spm" --no-parallel

# ---- ③ 旗舰 e2e ------------------------------------------------------------------------
run_step "③ 旗舰 e2e(真 a2 bin + 假 mihomo + 壳的真代码路径)" "$BUILD/flagship-e2e.log" \
  bash "$ROOT/Scripts/a2-flagship-e2e.sh"

# ---- ④ `.app` 出包(a2-panel 身份 + ad-hoc 签名)----------------------------------------
run_step "④ .app 出包(a2-panel · ad-hoc 签名 · 包结构核验)" "$BUILD/build-app.log" \
  bash "$ROOT/Scripts/build-app.sh" --output "$BUILD/app"

# ---- 收口 ------------------------------------------------------------------------------
# 各步自己的断言条数(供人读;判据是**步的成败**,不是这些数字 —— 数字漂了不该让门禁变色)。
# bun 的汇总行带 ANSI 转义,先去色再取数。
BUN_COUNT="$(sed -E $'s/\033\\[[0-9;]*m//g' "$BUILD/bun-test.log" 2>/dev/null \
  | grep -Eo 'Ran [0-9]+ tests' | tail -1 | grep -Eo '[0-9]+' || true)"
SWIFT_COUNT="$(grep -Eo 'with [0-9]+ tests? passed|Test run with [0-9]+ tests?' "$BUILD/swift-test.log" 2>/dev/null | tail -1 | grep -Eo '[0-9]+' || true)"
FLAGSHIP_COUNT="$(grep -Eo 'PASS=[0-9]+' "$BUILD/flagship-e2e.log" 2>/dev/null | tail -1 | cut -d= -f2 || true)"

echo
echo "========================================"
echo " 四件套明细(人读;判据是步的成败)"
echo "   ① bun test        : ${BUN_COUNT:-?} 条"
echo "   ② swift test      : ${SWIFT_COUNT:-?} 条"
echo "   ③ 旗舰 e2e        : ${FLAGSHIP_COUNT:-?} 条"
echo "   ④ .app 出包       : 结构 + ad-hoc 签名核验"
echo "----------------------------------------"
echo " 结果: 步 PASS=$STEPS_OK  FAIL=$STEPS_FAIL"
if [ "$STEPS_FAIL" -eq 0 ]; then
  echo " ALL PASS ✅"
  echo "========================================"
  exit 0
fi
for name in "${FAILED_NAMES[@]}"; do echo "   ✗ $name"; done
echo " FAILED ❌"
echo "========================================"
exit 1
