# --- 断言组 T:swift test(swift-testing 用例)—— 11 票把 `swift test` 接进门禁,17 票把断言全量搬进来 ---
#
# source 顺序:在 build.sh **之后**(要用它探到的 $SWIFT_BIN),同时也在 test-support.sh 之后 ——
#   PASS/FAIL 计数器与 assert_* 助手都是 test-support.sh 建的,排在它前面会撞 `set -u`。
#   它还必须排在 unit-and-domain.sh **之前**:那一组的 96 条 `assert_contains` 现在 grep 的正是
#   本文件跑出来的 `swift test` 输出($SWIFT_TEST_OUT,见下)。
#
# 为什么 `--disable-xctest`:本机的独立 Swift 工具链(~/Library/Developer/Toolchains/…)**不带 XCTest**
#   —— 那是 Xcode.app 才提供的。不显式禁掉,SPM 会去构建它根本找不到的 XCTest 宿主而失败。
#   `--enable-swift-testing` 则显式点名跑 swift-testing 那套(`import Testing` / `#expect`)。
#
# 为什么 `--no-parallel`(17 票新增):swift-testing 默认并行跑用例,而搬进来的
#   `AAAgentTestKitTests.SystemAgentPortTests` **碰真进程、真管道、真信号**,还有一条按耗时判定的
#   阻塞语义断言。旧 runner 是**严格顺序**执行的,这里保持同一语义 —— 门禁的稳定性比这几秒重要。
#   (纯逻辑那十几套并行是安全的;真要提速,应当是把真进程那套单独拎出去,而不是整体开并行。)
#
# 为什么注入 `AA_SPIKE_DIR`(17 票新增;写成命令前缀而不是 `export` —— 只给这一条命令,不污染后续 E2E 组的环境):
#   ClaudeAdapterTests / CodexAdapterTests 读 01/02 spike
#   落盘的**真实**样本(`.scratch/agent-delegation/research/…`)——那是单一真相源,不许复制成常量。
#   17 票之前这个变量由 unit-and-domain.sh 在调 registry-tests 时注入;断言搬进 `swift test` 之后
#   注入点也随之搬到这里。两个套件「缺失即 fail-closed」的设计一字未改:
#   变量缺失 / 目录不存在 / 样本读不出 → 用例直接红,绝不静默跳过。
#
# 为什么只记 **1 条**断言:这一阶段整体绿/红即一条结论,不按用例数展开 ——
#   否则每加一个 `@Test`,门禁总 PASS 数就漂一次,「PASS 总数」这个粗粒度回归信号就废了。
#   用例级细节由 unit-and-domain.sh 的 96 条 `assert_contains` 承担(它们 grep 的是 `@Test` 名字)。
echo "--- 断言组 T:swift test(swift-testing)---"
SWIFT_TEST_LOG="$BUILD/swift-test.log"
AA_SPIKE_DIR="$ROOT/.scratch/agent-delegation/research" \
"$SWIFT_BIN" test --scratch-path "$BUILD/spm-test" --disable-xctest --enable-swift-testing --no-parallel \
  >"$SWIFT_TEST_LOG" 2>&1
SWIFT_TEST_RC=$?

# 下游(unit-and-domain.sh / menubar.sh)要 grep 的那份输出。
#   `swift test` 会把每个用例名打进输出(`◇ Test "…" started.` / `✔ Test "…" passed`),
#   而 17 票**刻意把每条被 shell grep 的旧断言文案原样取作 `@Test` 名** —— 于是那 98 条
#   `assert_contains` 一个字都不用改就继续成立。
SWIFT_TEST_OUT="$(cat "$SWIFT_TEST_LOG")"

if [ "$SWIFT_TEST_RC" -eq 0 ]; then
  # swift-testing 的收尾行形如:`✔ Test run with 6 tests passed after 0.001 seconds.`
  SWIFT_TEST_SUMMARY="$(grep -E 'Test run with .* test' "$SWIFT_TEST_LOG" | tail -1)"
  [ -z "$SWIFT_TEST_SUMMARY" ] && SWIFT_TEST_SUMMARY="(未在输出中找到汇总行,详见 $SWIFT_TEST_LOG)"
  echo "PASS: swift test 全绿 —— $SWIFT_TEST_SUMMARY"; PASS=$((PASS+1))
else
  echo "FAIL: swift test 非零退出(rc=$SWIFT_TEST_RC),日志: $SWIFT_TEST_LOG"; FAIL=$((FAIL+1))
  echo "---- swift test 输出末 40 行 ----"
  tail -40 "$SWIFT_TEST_LOG" | sed 's/^/    /'
fi

# 旧 runner 的机读汇总行 `ALL_UNIT passed=<n> failed=<m>` 的等价物(unit-and-domain.sh 有一条
#   `assert_contains "$OUT" "failed=0"` 在盯它)。**这不是新造的事实,是把 swift-testing 自己的
#   收尾行翻译成旧格式**;而且是 **fail-closed** 的:rc≠0 或汇总行解析不出来就**不追加这一行**,
#   于是那条断言当场红 —— 绝不会出现「跑挂了却因为拿不到数字而静默算过」。
SWIFT_TEST_COUNT=""
if [ "$SWIFT_TEST_RC" -eq 0 ]; then
  SWIFT_TEST_COUNT="$(printf '%s' "${SWIFT_TEST_SUMMARY:-}" | sed -nE 's/.*Test run with ([0-9]+) test.*/\1/p')"
fi
if [ -n "$SWIFT_TEST_COUNT" ]; then
  SWIFT_TEST_OUT="$SWIFT_TEST_OUT
ALL_UNIT passed=$SWIFT_TEST_COUNT failed=0"
fi

# --- 断言组 T2:构建零警告 ---
#
# 11 票的验收辞是「`swift build` 全 target **零错误零警告**通过」。build.sh 只判 rc ——
#   而警告不影响 rc,于是「零警告」这条**没有门禁化**:哪天有人引入一个警告,门禁照样全绿,
#   那个勾就变成了一次性的人工观察,而不是持续成立的事实。这里把它钉死。
#
# 两档构建的日志都要查(AA_TESTING / AA_E2E)。判据是 swiftc/SPM 诊断行里的 `warning:`;
#   日志本身是 `tee` 出来的完整构建输出,缺一即无法核验 → 判 FAIL,不算过。
# 17 票追加:`swift test` 那次构建(测试 target 本身)也进同一张网 —— `swift build` 默认**不构建**
#   test target,若不把 swift-test.log 一并纳入,Tests/ 下引入的警告就永远查不到。
echo "--- 断言组 T2:构建零警告 ---"
BUILD_WARN_LOGS="$BUILD/build-testing.log $BUILD/build-e2e.log $SWIFT_TEST_LOG"
BUILD_WARN_MISSING=""
for f in $BUILD_WARN_LOGS; do [ -f "$f" ] || BUILD_WARN_MISSING="$BUILD_WARN_MISSING $f"; done
if [ -n "$BUILD_WARN_MISSING" ]; then
  echo "FAIL: 构建日志缺失($BUILD_WARN_MISSING),无法核验零警告 —— 绝不算过"; FAIL=$((FAIL+1))
else
  BUILD_WARNS="$(grep -hE '(^|[[:space:]])warning:' $BUILD_WARN_LOGS)"
  if [ -z "$BUILD_WARNS" ]; then
    echo "PASS: swift build 两档(AA_TESTING / AA_E2E)+ swift test 构建输出零 warning"; PASS=$((PASS+1))
  else
    echo "FAIL: swift build/test 输出含 warning(11 票验收辞要求零警告):"; FAIL=$((FAIL+1))
    printf '%s\n' "$BUILD_WARNS" | head -20 | sed 's/^/    /'
  fi
fi
