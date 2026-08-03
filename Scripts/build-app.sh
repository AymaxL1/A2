#!/bin/bash
# PROJECT_AA —— 一条命令出 `.app`(手工组 bundle + codesign)。
#
#   bash Scripts/build-app.sh [--variant production|e2e] [--output <dir>]
#
# ============================================================================
# 为什么不是 XcodeGen(12 票的范围变更,如实记录)
# ============================================================================
# 票面原文是「XcodeGen 工程定义入库 → `xcodegen generate` → `xcodebuild build`」。这条路在**本机不通,
# 且不是暂时不通**:`xcodebuild` 只随 Xcode.app 分发(CLT 里没有,Apple 官方文档明列),而本机没有 Xcode。
# 没有 `xcodebuild` 时,XcodeGen 产出的 `.xcodeproj` 没有任何消费者 —— 入库的是一份谁都跑不动的死重,
# 还要额外维护一套与 `Package.swift` 重复的依赖描述(两处真值,必然漂移)。
#
# 实测证明手工组 bundle 这条路是通的(见 docs/research/electron-recon/toolchain.md §1.3 与本票实测):
#   `swift build` 出可执行 → 手工摆 `Contents/{Info.plist,MacOS,Resources}` → `codesign -s -` ad-hoc 签名
#   → `valid on disk` + `satisfies its Designated Requirement` → 可双击、可常驻菜单栏(LSUIElement)。
# 于是本票的产物是**本脚本**,不是 `project.yml`。验收意图(一条命令出 `.app`、双击即得完整宿主、
# 内核随 `.app` 内资源被拉起、`aa` 经 install-cli 全链可用)一条不减,全部由 `Scripts/check/app-bundle.sh` 把关。
#
# 代价(必须写下来):**XCUITest 随 Xcode 一并推迟。** XCUITest 只能挂在 Xcode 工程下、由 `xcodebuild test`
# 驱动,没有 Xcode 就没有这个 target。本票**不立** XCUITest 骨架(立一个跑不了的空壳只会制造「已有 UI 自动化」
# 的错觉)。UI 层的自动验证缺口按 07 票架构映射的口径靠架构补偿(逻辑下沉 + 快照),归 14 票。
#
# ============================================================================
# ⚠️ 实测结论:资源 bundle 在 `.app` 里的落点(15 票重签内核 / 13 票签名都依赖这段)
# ============================================================================
# SwiftPM 把 PluginProxy 的 resources 打成 `PROJECT_AA_PluginProxy.bundle`,构建时与可执行文件**并排**。
# 进 `.app` 之后该放哪,三个候选**都真跑过**(判据:把构建目录里那份资源 bundle 移开、断掉 SwiftPM
# 生成的 `resource_bundle_accessor.swift` 里那条硬编码 buildPath 回退,再起宿主看是活是崩):
#
#   ① `Contents/Resources/PROJECT_AA_PluginProxy.bundle` —— 光靠 `Bundle.module` **不行**。
#      宿主启动即 `Fatal error: could not load resource bundle`。原因:SwiftPM 生成的访问器只试两个路径 ——
#      `Bundle.main.bundleURL/<资源bundle>` 和构建目录绝对路径;`.app` 里 `Bundle.main.bundleURL` 是
#      `AA.app` 本身,压根不查 `Contents/Resources/`。(「理论上 resourceURL 命中」这个直觉是错的。)
#   ② `Contents/MacOS/PROJECT_AA_PluginProxy.bundle`(复刻构建期布局)—— **不行**,同一条 fatalError。
#   ③ `AA.app/PROJECT_AA_PluginProxy.bundle`(bundle root,与 `Contents` 平级)—— `Bundle.module` **能找到**,
#      宿主起得来、内核确实从 `.app` 内被拉起(`ps` 里内核 argv 是 `.app` 内绝对路径)。
#      **但这个落点签不了名**:`codesign -s - AA.app` 报 `unsealed contents present in the bundle root` 且 rc=1,
#      随后 `codesign --verify --strict` 报 `code has no resources but signature indicates they must be present`。
#      在 bundle root 只放**符号链接**指向 `Contents/Resources/…` 同样被拒(逐字同一条错误)。
#
# 即:「`Bundle.module` 找得到的落点」与「`codesign` 接受的落点」在 `.app` 形态下**没有交集**。
# 结账方式(本票的唯一一处生产码改动):`Sources/PluginProxy/MihomoKernelResource.swift` 在 `Bundle.module`
#   **之前**先查 `Bundle.main.resourceURL/PROJECT_AA_PluginProxy.bundle/Resources/<name>`。于是资源 bundle 住
#   ①(可签、`--verify --strict` 通过),而非 bundle 形态的裸可执行走同一条路径也命中(`Bundle.main.resourceURL`
#   就是可执行所在目录,SwiftPM 正把资源 bundle 产在那里)——两种形态同一条解析,行为不分叉。
#   门禁断言组 APP 的第 5 条是这条结论的**运行时证明**:它核对内核 argv 的绝对路径确实在 `.app` 内。
set -uo pipefail

# ---- 单一来源:改这里,不要在别处再写一遍 --------------------------------------
# ⚠️ bundle id 一旦定下再改,代价是 **TCC / 通知授权重置** —— 系统按 bundle id 记录用户授权,
#   换 id 等于换了一个「新应用」,已授的通知/自动化权限全部作废、要用户重新点一遍(13 票要处理的正是这件事)。
#   `com.aa.host` 是**品牌未定前的中性缺省**:`feature/brand` 分支上还躺着 8 张叫 Aymax 的 logo 概念稿,
#   品牌一旦定了,这个值大概率要改一次 —— 那次改动要连同 13 票的授权仪式一起重做,别在别的时机顺手改。
BUNDLE_ID="com.aa.host"
APP_NAME="AA"
APP_VERSION="0.1.0"          # CFBundleShortVersionString 与 CFBundleVersion 共用这一个值
MIN_MACOS="13.0"             # 与 Package.swift 的 platforms: [.macOS(.v13)] 保持一致

# 签名身份 env seam:缺省 `-` = ad-hoc(无需任何证书,本机开发/门禁用)。
#   将来换开发证书(13 票)**只改这一个值**:`AA_CODESIGN_IDENTITY="Apple Development: …"`,
#   本脚本其余部分一个字不动。13 票另需考虑的两项在这里留个记号:真身份签名默认会去要
#   安全时间戳(离线会失败,需 `--timestamp=none` 或联网),公证还要 `--options runtime`(硬化运行时)。
CODESIGN_IDENTITY="${AA_CODESIGN_IDENTITY:--}"

# ---- 参数 ----------------------------------------------------------------------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VARIANT="production"
OUTPUT="$ROOT/.build/app"

# 带值选项必须显式检查「后面确实还有一个参数」。否则 `--variant` 作为**末参数**时:
#   `${2:-}` 是空串、`shift 2` 在 $#=1 下失败且**一个都不 shift**,`while [ $# -gt 0 ]` 就此死循环。
#   (手误一次就把脚本挂死,而且没有任何输出 —— 比报错难查得多。)
require_value() {  # $1=选项名 $2=剩余参数个数
  [ "$2" -ge 2 ] || { echo "FAIL: $1 需要一个值(用 --help 看用法)"; exit 1; }
}
while [ $# -gt 0 ]; do
  case "$1" in
    --variant) require_value --variant $#; VARIANT="$2"; shift 2 ;;
    --output)  require_value --output  $#; OUTPUT="$2";  shift 2 ;;
    -h|--help)
      echo "用法: bash Scripts/build-app.sh [--variant production|e2e] [--output <dir>]"
      echo "  env: AA_CODESIGN_IDENTITY(缺省 '-' = ad-hoc)  AA_SWIFT(指定 swift 绝对路径)"
      exit 0 ;;
    *) echo "FAIL: 未知参数: $1(用 --help 看用法)"; exit 1 ;;
  esac
done

case "$VARIANT" in
  # production:**不带任何 -D**。这一档才是出厂形态 —— `AA_TESTING` / `AA_E2E` 门控的那些 env seam
  #   (AA_CONFIRM_AUTO / AA_MIHOMO_KERNEL_PATH / AA_MIHOMO_DATA_DIR …)在里面根本不存在。
  production) SWIFT_FLAGS=() ;;
  # e2e:`-DAA_E2E`。只为让门禁能把内核数据目录导向临时区(AA_MIHOMO_DATA_DIR)而真起一次宿主。
  e2e)        SWIFT_FLAGS=(-Xswiftc -DAA_E2E) ;;
  *) echo "FAIL: --variant 只能是 production 或 e2e(收到: '$VARIANT')"; exit 1 ;;
esac

[ -n "$OUTPUT" ] || { echo "FAIL: --output 不能为空"; exit 1; }

# ---- 工具链 --------------------------------------------------------------------
# 判据与候选顺序的**权威在 Scripts/check/bootstrap.sh**(那里用 `swift package dump-package` rc=0 做严格探测)。
#   门禁调用本脚本时会把探好的那个经 `AA_SWIFT` 传进来 —— 此时直接用,不重复探测(省两次 dump-package)。
#   独立手跑(没给 AA_SWIFT)时才自己按同一顺序探一遍,判据也用同一条,免得两处判据漂移。
if [ -n "${AA_SWIFT:-}" ] && { command -v "$AA_SWIFT" >/dev/null 2>&1 || [ -x "$AA_SWIFT" ]; }; then
  SWIFT_BIN="$AA_SWIFT"
else
  SWIFT_BIN=""
  for cand in "$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift" swift; do
    command -v "$cand" >/dev/null 2>&1 || [ -x "$cand" ] || continue
    if "$cand" package dump-package --scratch-path "$ROOT/.build/app-toolchain-probe" >/dev/null 2>&1; then
      SWIFT_BIN="$cand"; break
    fi
  done
  if [ -z "$SWIFT_BIN" ]; then
    echo "FAIL: 找不到 SPM 可用的 swift。装一份官方独立工具链到家目录,或用 AA_SWIFT=<绝对路径> 指定。"
    echo "      (详见 Scripts/check/bootstrap.sh 的工具链探测段)"
    exit 1
  fi
fi

# ---- 构建 ----------------------------------------------------------------------
# **刻意不复用门禁的 scratch 目录**($ROOT/.build/check/spm-*):那两个目录每轮门禁开头都被 `rm -rf`,
#   而且旗标档次不同(AA_TESTING / AA_E2E)。共用只会互相触发整包重编。本脚本自己一档一个目录,
#   跨轮保留 → 增量构建,门禁里稳态只花几秒。
SCRATCH="$ROOT/.build/app-build-$VARIANT"
BUILD_LOG="$ROOT/.build/app-build-$VARIANT.log"
mkdir -p "$(dirname "$BUILD_LOG")"

echo "==== build-app.sh:variant=$VARIANT ===="
echo "-- swift build($([ ${#SWIFT_FLAGS[@]} -eq 0 ] && echo '无 -D 旗标,出厂形态' || echo "${SWIFT_FLAGS[*]}"))"
"$SWIFT_BIN" build --scratch-path "$SCRATCH" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} >"$BUILD_LOG" 2>&1
if [ $? -ne 0 ]; then
  echo "FAIL: swift build 失败(variant=$VARIANT),日志尾部:"
  tail -30 "$BUILD_LOG" | sed 's/^/    /'
  exit 1
fi

# bin 目录带三元组与配置名,只能问 SPM 要,不能拼(与 Scripts/check/build.sh 同口径)。
BIN="$("$SWIFT_BIN" build --scratch-path "$SCRATCH" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --show-bin-path 2>/dev/null)"
if [ -z "$BIN" ] || [ ! -d "$BIN" ]; then
  echo "FAIL: 取不到 swift build 的 bin 目录(BIN='$BIN')"; exit 1
fi

RES_BUNDLE_NAME="PROJECT_AA_PluginProxy.bundle"
for f in "$BIN/aahost" "$BIN/aa"; do
  [ -x "$f" ] || { echo "FAIL: 构建产物缺失或不可执行: $f"; exit 1; }
done
[ -d "$BIN/$RES_BUNDLE_NAME" ] || { echo "FAIL: 内核资源 bundle 缺失: $BIN/$RES_BUNDLE_NAME"; exit 1; }

# ---- 组装 bundle ---------------------------------------------------------------
APP="$OUTPUT/$APP_NAME.app"
rm -rf "$APP" || { echo "FAIL: 清理旧 .app 失败: $APP"; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" || { echo "FAIL: 建 bundle 目录失败: $APP"; exit 1; }

echo "-- 组装 bundle"
cp "$BIN/aahost" "$APP/Contents/MacOS/aahost" || { echo "FAIL: 拷贝 aahost 失败"; exit 1; }
# `aa` 也进 MacOS/:它是产品的一部分(`aa install-cli` 要把 PATH 里的符号链接指向 `.app` 内这一份)。
#   放 MacOS/ 而不是 Resources/ 是因为 codesign 对「可执行代码」的封存规则按目录区分,
#   代码放 Resources/ 会被当成未签名的资源、`--verify --strict` 抱怨。
cp "$BIN/aa" "$APP/Contents/MacOS/aa" || { echo "FAIL: 拷贝 aa 失败"; exit 1; }
# 资源 bundle 落 Contents/Resources/ —— 落点理由见本文件顶部「实测结论」段(这是唯一可签的落点)。
cp -R "$BIN/$RES_BUNDLE_NAME" "$APP/Contents/Resources/" || { echo "FAIL: 拷贝资源 bundle 失败"; exit 1; }

cat > "$APP/Contents/Info.plist" <<PLIST || { echo "FAIL: 写 Info.plist 失败"; exit 1; }
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>aahost</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$APP_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$APP_VERSION</string>
	<!-- LSUIElement:菜单栏 accessory,无 Dock 图标、无菜单栏主菜单。V1 产品形态的定义性一条。 -->
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_MACOS</string>
</dict>
</plist>
PLIST

# ---- 签名 ----------------------------------------------------------------------
# **顺序是硬要求:先内后外。** 签 `.app` 本体会把 `Contents/` 下所有文件的哈希封进 CodeResources;
#   之后再动任何内嵌可执行(签名会改写 Mach-O)都会让外层封存失效,`--verify --strict` 当场报
#   `a sealed resource is missing or invalid`。所以内嵌的先签完,最后才签壳。
#
# **不用 `--deep`**:Apple 已明确弃用(`codesign` man page 标 deprecated),且它对嵌套代码的发现规则
#   不可靠(会漏签非标准落点、也会用错身份/entitlements)。这里显式逐个签,签了哪些一目了然。
echo "-- 签名(identity='$CODESIGN_IDENTITY')"
# ① 资源 bundle 里所有带执行位的普通文件(当前只有 mihomo 内核;写成遍历是为了将来加内核/工具时不漏签)。
#    15 票「内核重签入构建链」接着用的就是这一步。
# 三步都把 codesign 的输出捕下来一起报:签名失败的原因几乎总在 stderr 里(证书不可用、
#   落点被拒、时间戳服务器不通……),吞掉它只剩「签名失败: <文件名>」,等于把诊断信息扔了。
while IFS= read -r exe; do
  echo "   sign: ${exe#$APP/}"
  if ! CS_OUT="$(codesign --force --sign "$CODESIGN_IDENTITY" "$exe" 2>&1)"; then
    echo "FAIL: 签名内嵌可执行失败: $exe"; echo "$CS_OUT" | sed 's/^/    /'; exit 1
  fi
done < <(find "$APP/Contents/Resources/$RES_BUNDLE_NAME" -type f -perm +111)
# ② CLI。
echo "   sign: Contents/MacOS/aa"
if ! CS_OUT="$(codesign --force --sign "$CODESIGN_IDENTITY" "$APP/Contents/MacOS/aa" 2>&1)"; then
  echo "FAIL: 签名 Contents/MacOS/aa 失败"; echo "$CS_OUT" | sed 's/^/    /'; exit 1
fi
# ③ 最后签 `.app` 本体。主可执行 `aahost` 由这一步一并签(它是 CFBundleExecutable,属于壳的一部分),
#    故**不**单独先签它 —— 单独签只会被这一步覆盖,白花时间。
echo "   sign: $APP_NAME.app(壳,含主可执行 aahost)"
CS_OUT="$(codesign --force --sign "$CODESIGN_IDENTITY" "$APP" 2>&1)"
if [ $? -ne 0 ]; then
  echo "FAIL: 签名 .app 本体失败: $CS_OUT"; exit 1
fi
CS_VERIFY="$(codesign --verify --strict --verbose=2 "$APP" 2>&1)"
if [ $? -ne 0 ]; then
  echo "FAIL: codesign --verify --strict 未通过: $CS_VERIFY"; exit 1
fi

# ---- 收口 ----------------------------------------------------------------------
APP_SIZE="$(du -sh "$APP" 2>/dev/null | awk '{print $1}')"
echo
echo "OK: $APP"
echo "    variant  = $VARIANT"
echo "    identity = $CODESIGN_IDENTITY$([ "$CODESIGN_IDENTITY" = "-" ] && echo '  (ad-hoc)')"
echo "    version  = $APP_VERSION   bundle id = $BUNDLE_ID"
echo "    size     = ${APP_SIZE:-?}"
