#!/bin/bash
# PROJECT_AA —— 一条命令出 `A2 Panel.app`(手工组 bundle + codesign + 结构/签名核验)。
#
#   bash Scripts/build-app.sh [--output <dir>]
#
# ============================================================================
# 为什么不是 XcodeGen(12 票的范围变更,10 票原样继承)
# ============================================================================
# spec 原文写的是「XcodeGen 工程」。这条路在**本机不通,且不是暂时不通**:`xcodebuild` 只随 Xcode.app
# 分发(CLT 里没有),而本机没有 Xcode。没有 `xcodebuild` 时,XcodeGen 产出的 `.xcodeproj` 没有任何消费者
# —— 入库的是一份谁都跑不动的死重,还要额外维护一套与 `Package.swift` 重复的依赖描述(两处真值,必然漂移)。
# 手工组 bundle 这条路 12 票已实测走通,10 票只是把主可执行从 `aahost` 换成 `a2-panel`。
# 代价照旧:**XCUITest 随 Xcode 一并推迟**(立一个跑不了的空壳只会制造「已有 UI 自动化」的错觉)。
#
# ============================================================================
# 10 票相对 12/15 票少了什么(**这不是简化,是前提变了**)
# ============================================================================
# 12/15 票的 `.app` 里有三样东西:`aahost`(GUI 宿主)、`aa`(CLI)、以及随包的 **GPL-3.0 mihomo 二进制**
#   + GPL 全文 + 内核重签步骤。现在:
#   * `aahost` / `aa` 已退场(主逻辑全在 `a2` 内核里,CLI 由内核 bin 自己提供,走单文件下载分发);
#   * **不再分发 GPL 二进制**(ADR 0007 修订版)—— 于是「内核重签入构建链」整条**废除**,
#     `Bundle.module` 那套资源 bundle 落点的实测结论也随之没有消费者(留在 git 历史里备查);
#   * `.app` 里因此只有一个 Mach-O:`Contents/MacOS/a2-panel`。
#   本脚本末尾有一条**结构红线断言**盯着这件事:包里出现第二个可执行就是红。
#
# ============================================================================
# 人工项(顺延,不阻塞门禁)
# ============================================================================
# 真开发者证书签名、首次 TCC / 通知授权、公证 —— 全是要人在场的,归 5 条人工项(路线图)。
# 本脚本默认 ad-hoc(`-`),换真身份**只改一个 env**:`AA_CODESIGN_IDENTITY="Apple Development: …"`。
# 真身份签名默认会去要安全时间戳(离线会失败,需 `--timestamp=none` 或联网);公证还要 `--options runtime`。
set -uo pipefail

# ---- 单一来源:改这里,不要在别处再写一遍 --------------------------------------
# ⚠️ bundle id 一旦定下再改,代价是 **TCC / 通知授权重置** —— 系统按 bundle id 记录用户授权。
#   10 票把它从 `com.aa.host` 换成 `com.a2.panel`:aa 系命名全面退场(spec 命名节),
#   而此刻换的代价恰好是零 —— 旧 id 从未上过真证书、也从未做过 TCC 授权仪式(那正是顺延中的人工项)。
#   **授权仪式要做就对着这个新 id 做**,别再改回去。
BUNDLE_ID="com.a2.panel"
APP_NAME="A2 Panel"          # CFBundleName / bundle 目录名(.app 显示名,spec 命名节钉死)
EXE_NAME="a2-panel"          # CFBundleExecutable,与 Package.swift 的 product 同名
APP_VERSION="0.1.0"          # CFBundleShortVersionString 与 CFBundleVersion 共用这一个值
MIN_MACOS="13.0"             # 与 Package.swift 的 platforms: [.macOS(.v13)] 保持一致

CODESIGN_IDENTITY="${AA_CODESIGN_IDENTITY:--}"

# ---- 参数 ----------------------------------------------------------------------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/.build/app"

require_value() {  # $1=选项名 $2=剩余参数个数
  [ "$2" -ge 2 ] || { echo "FAIL: $1 需要一个值(用 --help 看用法)"; exit 1; }
}
while [ $# -gt 0 ]; do
  case "$1" in
    --output) require_value --output $#; OUTPUT="$2"; shift 2 ;;
    -h|--help)
      echo "用法: bash Scripts/build-app.sh [--output <dir>]"
      echo "  env: AA_CODESIGN_IDENTITY(缺省 '-' = ad-hoc)  AA_SWIFT(指定 swift 绝对路径)"
      exit 0 ;;
    *) echo "FAIL: 未知参数: $1(用 --help 看用法)"; exit 1 ;;
  esac
done
[ -n "$OUTPUT" ] || { echo "FAIL: --output 不能为空"; exit 1; }

# ---- 工具链 --------------------------------------------------------------------
# 判据与候选顺序的**权威在 Scripts/check.sh**(`swift package dump-package` rc=0)。
#   门禁调用本脚本时会把探好的那个经 `AA_SWIFT` 传进来 —— 此时直接用,不重复探测。
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
  [ -n "$SWIFT_BIN" ] || {
    echo "FAIL: 找不到 SPM 可用的 swift。装一份官方独立工具链到家目录,或用 AA_SWIFT=<绝对路径> 指定。"
    exit 1
  }
fi

# ---- 构建 ----------------------------------------------------------------------
# **刻意不复用门禁的 scratch 目录**:那边跑的是 `swift test`(会连测试 target 一起编)。
#   本脚本自己一个目录,跨轮保留 → 增量构建,门禁里稳态只花几秒。
SCRATCH="$ROOT/.build/app-build"
BUILD_LOG="$ROOT/.build/app-build.log"
mkdir -p "$(dirname "$BUILD_LOG")"

echo "==== build-app.sh:$APP_NAME.app ===="
echo "-- swift build --product $EXE_NAME"
"$SWIFT_BIN" build --scratch-path "$SCRATCH" --product "$EXE_NAME" >"$BUILD_LOG" 2>&1
if [ $? -ne 0 ]; then
  echo "FAIL: swift build 失败,日志尾部:"; tail -30 "$BUILD_LOG" | sed 's/^/    /'; exit 1
fi

# bin 目录带三元组与配置名,只能问 SPM 要,不能拼。
BIN="$("$SWIFT_BIN" build --scratch-path "$SCRATCH" --show-bin-path 2>/dev/null)"
[ -n "$BIN" ] && [ -d "$BIN" ] || { echo "FAIL: 取不到 swift build 的 bin 目录(BIN='$BIN')"; exit 1; }
[ -x "$BIN/$EXE_NAME" ] || { echo "FAIL: 构建产物缺失或不可执行: $BIN/$EXE_NAME"; exit 1; }

# ---- 组装 bundle ---------------------------------------------------------------
APP="$OUTPUT/$APP_NAME.app"
rm -rf "$APP" || { echo "FAIL: 清理旧 .app 失败: $APP"; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" || { echo "FAIL: 建 bundle 目录失败: $APP"; exit 1; }

echo "-- 组装 bundle"
cp "$BIN/$EXE_NAME" "$APP/Contents/MacOS/$EXE_NAME" || { echo "FAIL: 拷贝 $EXE_NAME 失败"; exit 1; }

cat > "$APP/Contents/Info.plist" <<PLIST || { echo "FAIL: 写 Info.plist 失败"; exit 1; }
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$EXE_NAME</string>
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
# 包里只有一个 Mach-O(主可执行),它由「签壳」这一步一并签,标识符直接取 CFBundleIdentifier。
#   12/15 票那套「先内后外 + 逐个给 -i」的编排随内嵌 GPL 二进制一起废除 —— 没有内嵌代码要先签了。
echo "-- 签名(identity='$CODESIGN_IDENTITY')"
CS_OUT="$(codesign --force --sign "$CODESIGN_IDENTITY" "$APP" 2>&1)"
if [ $? -ne 0 ]; then echo "FAIL: 签名 .app 失败: $CS_OUT"; exit 1; fi

# ---- 核验(门禁第④步的判据就是这一段)------------------------------------------
echo "-- 核验"
VERIFY_FAIL=0
v_ok()  { echo "  PASS: $1"; }
v_bad() { echo "  FAIL: $1"; VERIFY_FAIL=$((VERIFY_FAIL+1)); }

[ -x "$APP/Contents/MacOS/$EXE_NAME" ] \
  && v_ok "APP1 主可执行就位且有执行位(Contents/MacOS/$EXE_NAME)" \
  || v_bad "APP1 主可执行缺失或无执行位"

PLIST_BUDDY=/usr/libexec/PlistBuddy
plist_get() { "$PLIST_BUDDY" -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null; }
[ "$(plist_get CFBundleIdentifier)" = "$BUNDLE_ID" ] \
  && v_ok "APP2 CFBundleIdentifier = $BUNDLE_ID(a2 系命名,aa 系已退场)" \
  || v_bad "APP2 CFBundleIdentifier 不是 $BUNDLE_ID(实际 '$(plist_get CFBundleIdentifier)')"
[ "$(plist_get CFBundleExecutable)" = "$EXE_NAME" ] \
  && v_ok "APP3 CFBundleExecutable = $EXE_NAME" \
  || v_bad "APP3 CFBundleExecutable 不是 $EXE_NAME"
[ "$(plist_get CFBundleName)" = "$APP_NAME" ] \
  && v_ok "APP4 显示名 = 「${APP_NAME}」(spec 命名节)" \
  || v_bad "APP4 显示名不是「${APP_NAME}」"
[ "$(plist_get LSUIElement)" = "true" ] \
  && v_ok "APP5 LSUIElement = true(菜单栏 accessory,无 Dock 图标)" \
  || v_bad "APP5 LSUIElement 不是 true"

CS_VERIFY="$(codesign --verify --strict --verbose=2 "$APP" 2>&1)"
if [ $? -eq 0 ]; then
  v_ok "APP6 codesign --verify --strict 通过"
else
  v_bad "APP6 codesign --verify --strict 未通过: $CS_VERIFY"
fi

# ad-hoc 下**没有证书链**可核验(`codesign -dv` 不会有 Authority 行),所以这里只核对标识符 ——
#   如实口径:这条断言证明的是「签了、且标识符是我们要的那个」,**不证明**「签名可被 Gatekeeper 接受」。
#   后者要真开发者证书 + 公证,归人工项。
CS_INFO="$(codesign -dv "$APP" 2>&1)"
if grep -q "Identifier=$BUNDLE_ID" <<<"$CS_INFO"; then
  v_ok "APP7 签名标识符 = $BUNDLE_ID(ad-hoc 下无证书链可核验,如实口径见脚本注释)"
else
  v_bad "APP7 签名标识符不是 $BUNDLE_ID:$CS_INFO"
fi

# **结构红线**:包里只该有一个 Mach-O。不再分发 GPL 二进制(ADR 0007 修订版),
#   也不再往包里塞 CLI —— `a2` 走单文件下载分发。多出来一个就是有人悄悄改了分发形态。
MACHO_COUNT="$(find "$APP" -type f -perm +111 | wc -l | tr -d ' ')"
if [ "$MACHO_COUNT" = "1" ]; then
  v_ok "APP8 结构红线:包里只有一个可执行($EXE_NAME)—— 不随包分发 GPL 二进制,也不塞 CLI"
else
  v_bad "APP8 结构红线:包里有 $MACHO_COUNT 个可执行(应当只有 1 个)"
  find "$APP" -type f -perm +111 | sed 's/^/      /'
fi

# ---- 收口 ----------------------------------------------------------------------
APP_SIZE="$(du -sh "$APP" 2>/dev/null | awk '{print $1}')"
echo
if [ "$VERIFY_FAIL" -eq 0 ]; then
  echo "OK: $APP"
else
  echo "FAILED($VERIFY_FAIL 条核验未过): $APP"
fi
echo "    identity = $CODESIGN_IDENTITY$([ "$CODESIGN_IDENTITY" = "-" ] && echo '  (ad-hoc)')"
echo "    version  = $APP_VERSION   bundle id = $BUNDLE_ID"
echo "    size     = ${APP_SIZE:-?}"
exit $([ "$VERIFY_FAIL" -eq 0 ] && echo 0 || echo 1)
