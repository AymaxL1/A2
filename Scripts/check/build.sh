echo "==== 阶段 A:按拓扑序编译全部 target ===="

# ① 零依赖底座(含线协议 Codable + UDS 路径常量)
build_lib AAContracts

# ② 只依赖 Contracts(06 票:AAPluginSDK 现含 ProcessPort/HTTPPort 两个宿主 Port 协议 + PluginCapability)
build_lib AAPluginSDK
build_lib AAHostRuntime   # 含 Registry(纯逻辑)
build_lib AAUISystem

# ③ PluginProxy —— 受限搜索路径:只放 SDK/Contracts/UISystem,故意不放任何 Host* 模块。
#    若它能在这条受限 -I 下编过,即从编译期证明「PluginProxy 不需要 Host*」(01 票铁律,06 票继续把关:
#    新增的 ProcessPort/HTTPPort 协议在 SDK,故插件仍只靠 SDK 即可编过)。
#    06 票起 PluginProxy 需被 AAHostTestKit(测试)与 AAHostMacOS(宿主装配)链接,故这里除 .swiftmodule 外也产 .o。
#    先于 AAHostTestKit / AAHostMacOS 编译(二者都 import PluginProxy)。
echo "-- 编译库 target: PluginProxy(受限 -I:仅 SDK/Contracts/UISystem,无 Host*;产 .o + module)"
cp "$MODULES/AAContracts.swiftmodule" "$MODULES/AAPluginSDK.swiftmodule" "$MODULES/AAUISystem.swiftmodule" "$PPMODS/" \
  || { echo "FAIL: 准备 PluginProxy 受限模块目录失败"; exit 1; }
swiftc "${SWIFTC_COMMON[@]}" -wmo \
  -parse-as-library \
  -module-name PluginProxy \
  -c -o "$OBJ/PluginProxy.o" \
  -emit-module-path "$MODULES/PluginProxy.swiftmodule" \
  -I "$PPMODS" \
  Sources/PluginProxy/*.swift \
  || { echo "FAIL: 编译 PluginProxy(受限 -I)失败 —— 它可能意外依赖了 Host* 或其它未提供模块"; exit 1; }

# ④ 假件 + 06 票纯逻辑测试(AAHostTestKit 现依赖 AAPluginSDK + PluginProxy:Port 假件 + RESTClient/status 测试)
build_lib AAHostTestKit

# ⑤ 宿主(库,但门禁单独把它编成可执行做冒烟;@main 是过桥,终态是 12 票 XcodeGen app 壳)。
#    06 票:宿主装配 ProxyPlugin(注入真 SystemProcessPort/SocketHTTPPort),故链接补 AAPluginSDK.o / PluginProxy.o / AAUISystem.o。
echo "-- 编译可执行 target: AAHostMacOS(库→冒烟可执行;AppKit,首次编译约 30s)"
swiftc "${SWIFTC_COMMON[@]}" \
  -parse-as-library \
  -D AA_TESTING \
  -I "$MODULES" \
  -o "$HOST_BIN" \
  "$OBJ/AAContracts.o" "$OBJ/AAHostRuntime.o" "$OBJ/AAPluginSDK.o" "$OBJ/PluginProxy.o" "$OBJ/AAUISystem.o" \
  Sources/AAHostMacOS/*.swift \
  || { echo "FAIL: 编译 AAHostMacOS 失败"; exit 1; }

echo "-- 编译生产 E2E 宿主(不含 AA_TESTING;真锁版内核 + 生产确认路径)"
swiftc "${SWIFTC_COMMON[@]}" \
  -parse-as-library -D AA_E2E \
  -I "$MODULES" \
  -o "$PROD_HOST_BIN" \
  "$OBJ/AAContracts.o" "$OBJ/AAHostRuntime.o" "$OBJ/AAPluginSDK.o" "$OBJ/PluginProxy.o" "$OBJ/AAUISystem.o" \
  Sources/AAHostMacOS/*.swift \
  || { echo "FAIL: 生产 E2E AAHostMacOS 编译失败"; exit 1; }

# ④ CLI 可执行:@main 入口需 -parse-as-library;链接其依赖 AAContracts.o;产真二进制。
echo "-- 编译可执行 target: aa"
swiftc "${SWIFTC_COMMON[@]}" \
  -parse-as-library \
  -I "$MODULES" \
  -o "$BIN/aa" \
  "$OBJ/AAContracts.o" \
  Sources/aa/*.swift \
  || { echo "FAIL: 编译 aa 失败"; exit 1; }

# ⑤ 门禁生成的 Registry 纯逻辑测试 runner —— 断言逻辑在 AAHostTestKit.RegistryConformanceTests,
#    这里只是入口 shim(main.swift 顶层代码,不需 -parse-as-library)。链接 TestKit + Runtime + Contracts。
echo "-- 编译测试 runner: registry-tests(驱动 AAHostTestKit.RegistryConformanceTests)"
cat > "$RUNNER/main.swift" <<'SWIFT'
// 门禁自动生成:纯逻辑测试的入口 shim(断言逻辑在 AAHostTestKit)。
// 06 票:除 RegistryConformanceTests 外,追加 ProxyConformanceTests(Port 假件 / RESTClient / proxy.status 域逻辑)。
import AAHostTestKit
import Foundation
let r1 = RegistryConformanceTests.run()
for line in r1.lines { print(line) }
let r2 = ProxyConformanceTests.run()
for line in r2.lines { print(line) }
print("REGISTRY_TESTS passed=\(r1.passed) failed=\(r1.failed)")
print("PROXY_TESTS passed=\(r2.passed) failed=\(r2.failed)")
let failed = r1.failed + r2.failed
print("ALL_UNIT passed=\(r1.passed + r2.passed) failed=\(failed)")
fflush(stdout)
exit(failed == 0 ? 0 : 1)
SWIFT
swiftc "${SWIFTC_COMMON[@]}" \
  -I "$MODULES" \
  -o "$TESTRUNNER" \
  "$OBJ/AAContracts.o" "$OBJ/AAHostRuntime.o" "$OBJ/AAHostTestKit.o" \
  "$OBJ/AAPluginSDK.o" "$OBJ/PluginProxy.o" "$OBJ/AAUISystem.o" \
  "$RUNNER/main.swift" \
  || { echo "FAIL: 编译 registry-tests runner 失败"; exit 1; }

echo "全部 target 编译通过。"
