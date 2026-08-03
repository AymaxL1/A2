# --- 断言组 T:swift test(swift-testing 用例)—— 11 票把 `swift test` 接进门禁 ---
#
# source 顺序:在 build.sh **之后**(要用它探到的 $SWIFT_BIN),同时也在 test-support.sh 之后 ——
#   PASS/FAIL 计数器与 assert_* 助手都是 test-support.sh 建的,排在它前面会撞 `set -u`。
#
# 为什么 `--disable-xctest`:本机的独立 Swift 工具链(~/Library/Developer/Toolchains/…)**不带 XCTest**
#   —— 那是 Xcode.app 才提供的。不显式禁掉,SPM 会去构建它根本找不到的 XCTest 宿主而失败。
#   `--enable-swift-testing` 则显式点名跑 swift-testing 那套(`import Testing` / `#expect`)。
#
# 为什么只记 **1 条**断言:这一阶段整体绿/红即一条结论,不按用例数展开 ——
#   否则每加一个 `@Test`,门禁总 PASS 数就漂一次,「PASS 总数」这个粗粒度回归信号就废了。
#   用例级细节看下面打印的 swift test 汇总行与日志。
#
# 覆盖面口径(别误读这条断言):Tests/ 下目前只有 AAContractsTests 一个 target(11 票的试点)。
#   AAHostTestKit / AAAgentTestKit 里那 ~5500 行手写 TestReport 断言仍由 `registry-tests` 跑,
#   整体搬迁到 `#expect` 归 17 票。
echo "--- 断言组 T:swift test(swift-testing)---"
SWIFT_TEST_LOG="$BUILD/swift-test.log"
"$SWIFT_BIN" test --scratch-path "$BUILD/spm-test" --disable-xctest --enable-swift-testing \
  >"$SWIFT_TEST_LOG" 2>&1
SWIFT_TEST_RC=$?
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

# --- 断言组 T2:构建零警告 ---
#
# 11 票的验收辞是「`swift build` 全 target **零错误零警告**通过」。build.sh 只判 rc ——
#   而警告不影响 rc,于是「零警告」这条**没有门禁化**:哪天有人引入一个警告,门禁照样全绿,
#   那个勾就变成了一次性的人工观察,而不是持续成立的事实。这里把它钉死。
#
# 两档构建的日志都要查(AA_TESTING / AA_E2E)。判据是 swiftc/SPM 诊断行里的 `warning:`;
#   日志本身是 `tee` 出来的完整构建输出,缺一即无法核验 → 判 FAIL,不算过。
echo "--- 断言组 T2:构建零警告 ---"
BUILD_WARN_LOGS="$BUILD/build-testing.log $BUILD/build-e2e.log"
BUILD_WARN_MISSING=""
for f in $BUILD_WARN_LOGS; do [ -f "$f" ] || BUILD_WARN_MISSING="$BUILD_WARN_MISSING $f"; done
if [ -n "$BUILD_WARN_MISSING" ]; then
  echo "FAIL: 构建日志缺失($BUILD_WARN_MISSING),无法核验零警告 —— 绝不算过"; FAIL=$((FAIL+1))
else
  BUILD_WARNS="$(grep -hE '(^|[[:space:]])warning:' $BUILD_WARN_LOGS)"
  if [ -z "$BUILD_WARNS" ]; then
    echo "PASS: swift build 两档(AA_TESTING / AA_E2E)输出零 warning"; PASS=$((PASS+1))
  else
    echo "FAIL: swift build 输出含 warning(11 票验收辞要求零警告):"; FAIL=$((FAIL+1))
    printf '%s\n' "$BUILD_WARNS" | head -20 | sed 's/^/    /'
  fi
fi
