echo "==== 阶段 A:swift build 全包构建(两次)===="

# 引擎:SPM。依赖图与拓扑序全在 Package.swift 里,这里只负责「按两种条件编译档各构建一次」。
#
# 为什么是两次:
#   ① -DAA_TESTING —— 门禁自用的一切(aa / aa-agent / aahost / registry-tests)。宿主里的 test-only
#      env seam(AA_CONFIRM_AUTO、AA_MIHOMO_KERNEL_PATH 之流)只在这一档存在。
#   ② -DAA_E2E     —— **只**为拿一个不含 AA_TESTING 的生产 aahost(真锁版内核 + 生产确认路径),
#      供 mihomo-real-e2e.sh 证明「那些 seam 在生产二进制里根本不存在」。
#   两档必须落在**不同的 scratch 目录**:同一目录换 -Xswiftc 旗标只会触发整包重编,拿不到两个并存的产物。
#
# 关于 `-Xswiftc -DAA_TESTING` 施于**整包**:11 票之前只有 AAHostMacOS 带这个旗标(直编时逐 target 给)。
#   现在整包都带,行为等价 —— 全仓只有 Sources/AAHostMacOS/HostApp.swift 用了 `#if AA_TESTING` / `#if AA_E2E`
#   这两个条件编译符号(其余 target 一处都没有),故给别的 target 带上是空操作。
#   (若将来别处新增 `#if AA_TESTING`,这条等价性就不再成立 —— 到时要么收窄旗标,要么明确接受。)

SPM_TESTING_SCRATCH="$BUILD/spm-testing"
SPM_E2E_SCRATCH="$BUILD/spm-e2e"

echo "-- swift build(AA_TESTING 档:aa / aa-agent / aahost / registry-tests)"
"$SWIFT_BIN" build --scratch-path "$SPM_TESTING_SCRATCH" -Xswiftc -DAA_TESTING 2>&1 | tee "$BUILD/build-testing.log"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  echo "FAIL: swift build(AA_TESTING 档)失败,日志: $BUILD/build-testing.log"
  exit 1
fi

echo "-- swift build(AA_E2E 档:只为拿不含 AA_TESTING 的生产 aahost)"
"$SWIFT_BIN" build --scratch-path "$SPM_E2E_SCRATCH" -Xswiftc -DAA_E2E 2>&1 | tee "$BUILD/build-e2e.log"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  echo "FAIL: swift build(AA_E2E 档)失败,日志: $BUILD/build-e2e.log"
  exit 1
fi

# ---- 下游路径变量 --------------------------------------------------------------
# bin 目录带三元组与配置名(如 <scratch>/arm64-apple-macosx/debug),只能问 SPM 要,不能拼。
BIN="$("$SWIFT_BIN" build --scratch-path "$SPM_TESTING_SCRATCH" --show-bin-path 2>/dev/null)"
E2E_BIN="$("$SWIFT_BIN" build --scratch-path "$SPM_E2E_SCRATCH" --show-bin-path 2>/dev/null)"
if [ -z "$BIN" ] || [ ! -d "$BIN" ] || [ -z "$E2E_BIN" ] || [ ! -d "$E2E_BIN" ]; then
  echo "FAIL: 取不到 swift build 的 bin 目录(BIN='$BIN' E2E_BIN='$E2E_BIN')"
  exit 1
fi

# ⚠️ 绝不把这些可执行拷到别处再跑 —— 这不是洁癖,是会当场崩的硬约束:
#   PluginProxy 的资源被 SPM 打成 `PROJECT_AA_PluginProxy.bundle`,产在 bin 目录里、与可执行文件**并排**;
#   Sources/PluginProxy/MihomoKernelResource.swift 在 `#if SWIFT_PACKAGE` 下用 `Bundle.module...!` **强解包**取它。
#   一旦可执行离开 bin 目录,Bundle.module 找不到 bundle,强解包直接 crash。
#   (12 票打 .app 时确实把这个 bundle 一起搬进了 `Contents/Resources/` —— 但那条路**不是**光靠 `Bundle.module`
#    就能走通的:SwiftPM 生成的访问器只认 `Bundle.main.bundleURL/<资源bundle>`,而那个落点 codesign 拒签。
#    结论与三个候选落点的实测记录见 `Scripts/build-app.sh` 顶部。本文件这里仍然只有一条规矩:**别搬**。)
HOST_BIN="$BIN/aahost"                 # AppKit accessory 宿主可执行(AA_TESTING 档)
TESTRUNNER="$BIN/registry-tests"       # TestKit runner(AAHostTestKit + AAAgentTestKit 的统一入口)
PROD_HOST_BIN="$E2E_BIN/aahost"        # 不含 AA_TESTING,真核全链 E2E 宿主
# 只盯本次构建的绝对路径,避免误杀用户机上别处同名的 aahost 进程(见 bootstrap.sh cleanup() 的守卫说明)。
KILLPAT="$HOST_BIN"

# bin 目录落盘留档,供门禁之外的手动脚本(Scripts/manual-verify-04.sh、Scripts/agent-smoke.sh)读取。
#   它们不 source 本文件,却同样需要产物路径。此前各自用 `ls -d …/*/debug | head -1` **猜**目录 ——
#   三处知识重复、布局一变要改三处,而且多三元组(如同时存在 arm64/x86_64 产物)时 `head -1` 会**静默选错**。
#   这里把 `--show-bin-path` 这个唯一权威答案写下来,让它们读,不再猜。
printf '%s\n' "$BIN" > "$BUILD/spm-bin-path.txt"
printf '%s\n' "$E2E_BIN" > "$BUILD/spm-bin-path-e2e.txt"

for f in "$BIN/aa" "$BIN/aa-agent" "$HOST_BIN" "$TESTRUNNER" "$PROD_HOST_BIN"; do
  [ -x "$f" ] || { echo "FAIL: 构建产物缺失或不可执行: $f"; exit 1; }
done

echo "全部 target 构建通过。"
echo "  BIN(AA_TESTING) = $BIN"
echo "  BIN(AA_E2E)     = $E2E_BIN"
