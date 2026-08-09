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
#     `Bundle.module` 那套资源 bundle 落点的实测结论也随之没有消费者(留在 git 历史里备查)。
#
# ============================================================================
# 14 票:`.app` 从「纯壳」变「面板自足」([ADR 0012](../docs/adr/0012-panel-self-sufficient-bootstrap.md))
# ============================================================================
# 包里现在有**两个 Mach-O**:`Contents/MacOS/a2-panel`(壳)与 `Contents/Resources/a2`(内核 bin)。
# 多出来的那个**不是 CLI 分发**,也不是"把 a2 装进 PATH"——它是面板**引导内核安装**时唯一的执行器:
#   * 面板只调白名单命令(`service install|uninstall|status`、`version`),别的一律不经它;
#   * 装出来的服务**不指向包内那份**:unit 指的是 `$A2_HOME/bin/a2` 的拷贝(免疫 macOS translocation、
#     挪包/删包不断服 —— 拷贝机制本身是 15 票的活,本脚本只负责让包里那份存在且可执行);
#   * CLI 分发渠道(单文件 + `install.sh`)一字不动,它与本包无关。
# 结构断言随之修订(见文末):APP8 从「恰 1 个可执行」改「**恰 2 个,且就是那两条路径**」,
# 并新增 APP9(内嵌 bin 自报版本 = 内核版本单一来源)与 APP10(arm64 单架构)。
#
# **16 票再加一条 APP11**:内嵌 bin 以一次性 `A2_HOME` 实跑 `service status --json` ——
#   即「面板引导链第一步要调的那条命令」在包内真的可用(只读;门禁永不跑 install/uninstall)。
#   于是本脚本的核验清单是 **APP1–APP11**。
#
# **签名顺序变成先内后外**:先签 `Contents/Resources/a2`,再签 bundle(同一 identity)。
# 12/15 票那套编排当年为随包 GPL 二进制而立、随它一起废除,现在为内嵌内核而回来,理由与当年同构。
# **不许用 `--deep`**(Apple 已弃用的批量签法,会掩盖"哪一层没签上")。
# 本票实测:先内后外签完,`codesign --verify --strict` 通过;改掉内嵌 bin 一个字节即报
# `a sealed resource is missing or invalid` —— 包的签名确实盖住了它(它进的是资源封印,不是嵌套代码)。
#
# ============================================================================
# 工具链:14 票起要两条
# ============================================================================
# 壳要 `swift`,内嵌的内核 bin 要 `bun`(内核是 TS,ADR 0010)。以前包里没有内核,出包不关 bun 的事。
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
# 内嵌内核 bin 在包里的名字(14 票)。面板按 `Bundle.main.resourceURL/a2` 找它 —— 改这个名字
#   就要连壳那侧一起改,所以它在这里、只有这一处。
KERNEL_EXE_NAME="a2"
# CFBundleShortVersionString 与 CFBundleVersion 共用这一个值。
# ⚠️ 它与**内核版本**(`kernel/package.json` → `runtime/version.ts`)是**两个独立的数**,眼下恰好都是
#   0.1.0。14 票起包里嵌着内核,于是「壳版本是否随内核走」成了一个要答的问题 —— **发版前待裁**:
#   要么钉死"同版"(那就加一条硬对账断言),要么明确分开走(那就在发布说明里写清两个版本号)。
#   在裁定之前:**内核发版时来这里同步核对一次**。本票有意不做硬对账 —— 现在钉死等于替用户先裁了。
APP_VERSION="0.1.0"
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
      echo "       AA_BUN(指定 bun 绝对路径)  AA_KERNEL_BIN(门禁刚重建好的内核 bin,见脚本注释)"
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

# bun(14 票起):包里那个内核 bin 是它编出来的,版本权威也要问它。
#
# `AA_BUN` **指了却不可用 → 硬 FAIL**(14 票 CR 尾款):与 `AA_KERNEL_BIN` 同一宽严。显式给的 seam 值
#   不对就是配置错;静默回落 PATH 会让「我明明指了另一份 bun」变成一个查不出来的谜(而那份 bun 的版本
#   决定了包里内核 bin 的字节)。
# ⚠️ 上面 `AA_SWIFT` 那段**有意保留**「指了不可用就往下试候选」的旧形态 —— 那是 10 票起的仓库惯例
#   (check.sh 的候选表也是那个形态),本票不动它;真要统一成硬 FAIL,得连 check.sh 一起改,属另一张票。
if [ -n "${AA_BUN:-}" ]; then
  BUN_BIN="$AA_BUN"
  command -v "$BUN_BIN" >/dev/null 2>&1 || [ -x "$BUN_BIN" ] || {
    echo "FAIL: AA_BUN 指的 bun 不可用(不存在 / 没有执行位): $BUN_BIN"
    echo "  它是显式给进来的 seam —— 不静默回落 PATH,免得包里那份内核是另一个 bun 编的。"
    exit 1
  }
else
  BUN_BIN="$(command -v bun 2>/dev/null)"
  [ -z "$BUN_BIN" ] && [ -x "$HOME/.bun/bin/bun" ] && BUN_BIN="$HOME/.bun/bin/bun"
  [ -n "$BUN_BIN" ] || {
    echo "FAIL: 找不到 bun —— 14 票起 .app 里嵌着内核 bin(内核是 TS,ADR 0010),没有它出不了包。"
    echo "  装法:curl -fsSL https://bun.sh/install | bash(装完在 ~/.bun/bin/bun);或 AA_BUN=<绝对路径>。"
    exit 1
  }
fi

# ---- 一次性 `A2_HOME`(施工红线的落点)-------------------------------------------
# 本脚本要**实跑内核**三次(问版本单一来源、APP9、APP11)。每一次都必须把 `A2_HOME` 指到一个一次性目录:
#   真 `~/.a2` 是用户的家当,出个包不该碰它一个字节。
# **`mktemp` 失败必须当场红,不能让 `A2_HOME=""` 把命令放回默认的 `~/.a2`** —— 那不只是踩红线,
#   还会让「跑完一次性目录里没有残留」那半边断言变成**恒真**(空字符串目录里当然什么都没有)。
#   式样与 `release-assemble.sh::panel_kernel_version_of` 的 rc-check 一致:失败即非零返回,调用方判红。
throwaway_home() {  # → stdout 目录路径;造不出来则非零返回
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/a2-app-throwaway-XXXXXX")" || return 1
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  printf '%s' "$dir"
}

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

# ---- 内核 bin(14 票:要嵌进包里的那一份)-----------------------------------------
# **新鲜度不发明第二套判据**。门禁 ②b 的既有机制是**恒重建**——11 票那道 `find -newer` 守卫 12 票已废,
#   理由写在 check.sh ②b 的注释里(删源文件看不见、`tsconfig.json` 不在比对清单里、mtime 本来就不是
#   内容的可靠代理)。本脚本沿用同一条,而不是把那道有洞的守卫捡回来:
#     * **门禁调用时**:②b 刚恒重建过,经 `AA_KERNEL_BIN` 把产物路径传进来 —— 直接用,不重复编译
#       (与 `AA_SWIFT` 同一种 seam)。它指的文件不在 → FAIL。**手工设这个 env 就是自己担保它是新的**:
#       它是"上游刚做完"的信物,不是"跳过重建"的后门。
#     * **单独跑时**:自己恒重建一次 `kernel/dist/a2`。这是"包里那份内核就是当前源码"的唯一保证:
#       `.app` 里嵌一版旧内核而门禁照绿,正是 ②b 当年要挡的那种假绿 —— 只是这次假绿会被**发出去**。
#   **代价的统一口径**(14 票 CR 尾款,与 check.sh ①/②b 的注释同一句):`bun build --compile` 本机
#   **热缓存下约 1 秒**(2026-08-09 实测,产物 64MiB);**冷的那一次**(首次编译 / 换了 `--target`
#   要先下目标运行时)是十几秒到几分钟,那是 bun 预热的代价,不是这条命令稳态的样子。
#   所以恒重建不必设计任何缓存 —— 稳态就是一秒。
#   编译命令(入口 + 旗标)与 check.sh ②b、`kernel/scripts/build.sh` 是同一条,有对账断言钉着
#   (`kernel/test/release-manifest.test.ts` ▸ 内核编译命令三处一致)。
KERNEL_SRC="$ROOT/kernel/dist/$KERNEL_EXE_NAME"
if [ -n "${AA_KERNEL_BIN:-}" ]; then
  KERNEL_SRC="$AA_KERNEL_BIN"
  [ -f "$KERNEL_SRC" ] || { echo "FAIL: AA_KERNEL_BIN 指的内核 bin 不存在: $KERNEL_SRC"; exit 1; }
  echo "-- 内核 bin:用调用方刚重建好的那份($KERNEL_SRC)"
else
  echo "-- 重建内核 bin(恒重建 —— 包里只许嵌当前这版内核)"
  KERNEL_LOG="$ROOT/.build/app-kernel-build.log"
  if ! env -C "$ROOT/kernel" "$BUN_BIN" build ./src/cli/main.ts --compile --outfile "$KERNEL_SRC" \
        >"$KERNEL_LOG" 2>&1; then
    echo "FAIL: 编译内核 bin 失败,日志尾部:"; tail -20 "$KERNEL_LOG" | sed 's/^/    /'; exit 1
  fi
fi
[ -f "$KERNEL_SRC" ] || { echo "FAIL: 内核 bin 缺失: $KERNEL_SRC"; exit 1; }

# 版本权威**问源码入口要**(`src/runtime/version.ts` → `package.json` 那条单一来源),
#   不在 shell 里再解析一遍那份 JSON —— 多一处解析就多一个会漂的真值。APP9 拿它与内嵌 bin 自报的对账。
# 这也是**一次跑内核**,所以照样配一次性 `A2_HOME`(14 票 CR 尾款):`version` 眼下不写盘,
#   但「跑内核必配 throwaway」是红线口径,不留「先污染、后报警」的窗口 —— 哪天它顺手落个缓存,
#   落的也是这个用完就删的目录。
VERSION_HOME="$(throwaway_home)" || {
  echo "FAIL: 造不出一次性 A2_HOME(mktemp 失败)—— 拒绝拿真 ~/.a2 去跑内核入口"; exit 1; }
KERNEL_VERSION="$( ( cd "$ROOT/kernel" && A2_HOME="$VERSION_HOME" "$BUN_BIN" run ./src/cli/main.ts version ) \
  2>/dev/null | tr -d '\r\n' )"
rm -rf "$VERSION_HOME"
[ -n "$KERNEL_VERSION" ] || { echo "FAIL: 问不出内核版本(源码入口 a2 version 没有输出)"; exit 1; }

# ---- 组装 bundle ---------------------------------------------------------------
APP="$OUTPUT/$APP_NAME.app"
rm -rf "$APP" || { echo "FAIL: 清理旧 .app 失败: $APP"; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" || { echo "FAIL: 建 bundle 目录失败: $APP"; exit 1; }

echo "-- 组装 bundle"
cp "$BIN/$EXE_NAME" "$APP/Contents/MacOS/$EXE_NAME" || { echo "FAIL: 拷贝 $EXE_NAME 失败"; exit 1; }
# 内嵌内核(14 票)。落 `Contents/Resources/` 而不是 `Contents/MacOS/`:那里是 `CFBundleExecutable` 的地盘,
#   多放一个可执行会让"这个 .app 的主程序是谁"变模糊;资源目录里的 Mach-O 由 bundle 签名当**资源**封印
#   (本票实测:改一个字节即 `a sealed resource is missing or invalid`)。
cp "$KERNEL_SRC" "$APP/Contents/Resources/$KERNEL_EXE_NAME" \
  || { echo "FAIL: 拷贝内核 bin 失败($KERNEL_SRC)"; exit 1; }
chmod 755 "$APP/Contents/Resources/$KERNEL_EXE_NAME" \
  || { echo "FAIL: 给内嵌内核 bin 加执行位失败"; exit 1; }

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

# ---- 签名(14 票:先内后外)------------------------------------------------------
# 顺序是硬的:**先签内嵌的内核 bin,再签 bundle**。反过来的话,壳签完之后往包里塞/改文件,
#   资源封印当场对不上(`codesign --verify` 报 `a sealed resource is missing or invalid`)。
# **不用 `--deep`**:Apple 已弃用它,而且它会把"哪一层没签上"糊成一句话 —— 换真身份那天,
#   这两条 `codesign` 用的是同一个 `$AA_CODESIGN_IDENTITY`,谁失败谁当场 exit 1(§4 的 fail-closed 口径)。
echo "-- 签名(identity='$CODESIGN_IDENTITY')"
CS_OUT="$(codesign --force --sign "$CODESIGN_IDENTITY" "$APP/Contents/Resources/$KERNEL_EXE_NAME" 2>&1)"
if [ $? -ne 0 ]; then echo "FAIL: 签名内嵌内核 bin 失败: $CS_OUT"; exit 1; fi
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

# **结构红线**(14 票修订:1 → 2,口径见 [ADR 0012](../docs/adr/0012-panel-self-sufficient-bootstrap.md))。
#   包里恰好两个可执行,且**就是那两条路径**:壳 + 内嵌内核 bin(面板引导内核安装的执行器)。
#   仍然盯死的是同两件事:**不随包分发 GPL 二进制**(ADR 0007 修订版,mihomo 由 `a2 mihomo install` 取)、
#   **不往包里塞第三样东西**。多一个、少一个、或名字挪了位置,都是有人悄悄改了分发形态。
#   比"数个数"更硬:数字对而路径不对(比如内核落错目录、壳被改名)也要红。
MACHO_PATHS="$(find "$APP" -type f -perm +111 | sort)"
MACHO_EXPECT="$(printf '%s\n%s\n' \
  "$APP/Contents/MacOS/$EXE_NAME" "$APP/Contents/Resources/$KERNEL_EXE_NAME" | sort)"
if [ "$MACHO_PATHS" = "$MACHO_EXPECT" ]; then
  v_ok "APP8 结构红线:包里恰好 2 个可执行($EXE_NAME + Resources/$KERNEL_EXE_NAME)—— 不随包分发 GPL 二进制"
else
  v_bad "APP8 结构红线:包里的可执行清单与「壳 + 内嵌内核」对不上"
  echo "      实际:"; printf '%s\n' "$MACHO_PATHS" | sed 's/^/        /'
  echo "      应为:"; printf '%s\n' "$MACHO_EXPECT" | sed 's/^/        /'
fi

# **内嵌 bin 得真是那一版内核**:签完之后**实跑一次** `version`,与版本单一来源对账。
#   拷错文件、拷了上一版、拷了个空文件 —— 光看"有没有这个文件"一条都看不出来。
#   `A2_HOME` 指到一次性目录:门禁跑这条时**绝不许碰真 `~/.a2`**(顺带验一件事:`version` 是无副作用的,
#   跑完那个目录里应当一个文件都没有 —— 与 `a2 about` 同类的 no-op 命令口径)。
#   造不出那个目录就**当场红**(14 票 CR 尾款):不许退化成"拿真 `~/.a2` 跑一次,顺便把无残留验成恒真"。
EMBED_BIN="$APP/Contents/Resources/$KERNEL_EXE_NAME"
if EMBED_HOME="$(throwaway_home)"; then
  EMBED_VERSION="$(A2_HOME="$EMBED_HOME" "$EMBED_BIN" version 2>/dev/null | tr -d '\r\n')"
  EMBED_LEFTOVER="$(ls -A "$EMBED_HOME" 2>/dev/null | wc -l | tr -d ' ')"
  rm -rf "$EMBED_HOME"
  if [ "$EMBED_VERSION" = "$KERNEL_VERSION" ] && [ "$EMBED_LEFTOVER" = "0" ]; then
    v_ok "APP9 内嵌内核 bin 实跑 version = $KERNEL_VERSION(= 版本单一来源),且没在一次性 A2_HOME 里留下任何文件"
  else
    v_bad "APP9 内嵌内核 bin 对不上:自报 '$EMBED_VERSION',单一来源是 '$KERNEL_VERSION';一次性 A2_HOME 残留 $EMBED_LEFTOVER 项"
  fi
else
  v_bad "APP9 造不出一次性 A2_HOME(mktemp 失败,TMPDIR='${TMPDIR:-/tmp}')—— 拒绝拿真 ~/.a2 去跑内嵌 bin"
fi

# **架构**:内嵌 bin 必须是 arm64 **单架构** Mach-O。`lipo -archs` 是判"胖不胖"的权威,
#   `file` 补一句"它到底是不是 Mach-O 可执行"(空文件、shell 脚本、ELF 都在这条上现形)。
#   本机与 Phase 1 的发布口径都是 arm64;真要出 darwin-x64 包,这条与平台表(`KERNEL_TARGETS`)一起改。
EMBED_ARCHS="$(lipo -archs "$EMBED_BIN" 2>&1 | tr -s ' ' | sed 's/^ *//; s/ *$//')"
EMBED_FILE="$(file -b "$EMBED_BIN" 2>&1)"
if [ "$EMBED_ARCHS" = "arm64" ] && grep -q "Mach-O 64-bit executable arm64" <<<"$EMBED_FILE"; then
  v_ok "APP10 内嵌内核 bin 是 arm64 单架构 Mach-O(lipo -archs = arm64)"
else
  v_bad "APP10 内嵌内核 bin 不是 arm64 单架构:lipo -archs = '$EMBED_ARCHS';file = '$EMBED_FILE'"
fi

# **面板将要调的那条命令,在包里真的可用**(16 票 / [ADR 0012](../docs/adr/0012-panel-self-sufficient-bootstrap.md))。
#   APP9 证明的是 `version` 跑得动 —— 那条命令什么都不问,不碰文件系统也不碰 supervisor。
#   而面板引导链的第一步问的是 **`service status --json`**:它要解析 `A2_HOME`、算出 unit 路径、
#   问一次系统 supervisor、再读盘上那份 unit 才答得出 `binPath`。这一整条路在包内环境下断了,
#   APP9 一条都看不出来 —— 而用户会在点开 `.app` 的第一秒撞上它。
#
# **只读 + 不碰真环境**(施工红线):`service status` 不写任何文件、不装任何东西;`A2_HOME` 指一次性目录,
#   真 `~/.a2` 一个字节不动(跑完顺带核对该目录仍是空的)。它确实会以只读方式问一次
#   `launchctl print gui/<uid>/com.a2.kernel`(装没装),那是查询、不改任何状态。
#   门禁**永远不在这里跑 install/uninstall** —— 那两条会真的动 launchd,只归产品运行期用户那一次点击。
#
# 判据四条:退出码 0 · 机读面是一条可解析的包封且 `ok=true` · `result.binPath` 在
#   (15 票新增的必填字段,面板据它判"托管的是不是我这份内核")· 一次性 A2_HOME 无残留。
# 一次性目录造不出来就当场红,与 APP9 同一条守卫(14 票 CR 尾款把 `mktemp` 的 rc 检查补齐)。
if SMOKE_HOME="$(throwaway_home)"; then
  SMOKE_OUT="$(A2_HOME="$SMOKE_HOME" "$EMBED_BIN" service status --json 2>/dev/null)"
  SMOKE_RC=$?
  SMOKE_OK="$(printf '%s' "$SMOKE_OUT" | plutil -extract ok raw -o - -- - 2>/dev/null)"
  SMOKE_BINPATH="$(printf '%s' "$SMOKE_OUT" | plutil -extract result.binPath raw -o - -- - 2>/dev/null)"
  SMOKE_BINPATH_RC=$?
  SMOKE_LEFTOVER="$(ls -A "$SMOKE_HOME" 2>/dev/null | wc -l | tr -d ' ')"
  rm -rf "$SMOKE_HOME"
  if [ "$SMOKE_RC" -eq 0 ] && [ "$SMOKE_OK" = "true" ] \
     && [ "$SMOKE_BINPATH_RC" -eq 0 ] && [ -n "$SMOKE_BINPATH" ] && [ "$SMOKE_LEFTOVER" = "0" ]; then
    v_ok "APP11 内嵌 bin 跑得动面板要调的那条只读命令(service status --json → ok=true,binPath=$SMOKE_BINPATH,一次性 A2_HOME 无残留)"
  else
    v_bad "APP11 内嵌 bin 的 service status --json 不可用:rc=$SMOKE_RC ok='$SMOKE_OK' binPath 取值 rc=$SMOKE_BINPATH_RC 值='$SMOKE_BINPATH' 残留 $SMOKE_LEFTOVER 项"
    echo "      stdout:"; printf '%s\n' "$SMOKE_OUT" | head -5 | sed 's/^/        /'
  fi
else
  v_bad "APP11 造不出一次性 A2_HOME(mktemp 失败,TMPDIR='${TMPDIR:-/tmp}')—— 拒绝拿真 ~/.a2 去跑内嵌 bin"
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
echo "    kernel   = $KERNEL_VERSION(内嵌 Contents/Resources/$KERNEL_EXE_NAME)"
echo "    size     = ${APP_SIZE:-?}"
exit $([ "$VERIFY_FAIL" -eq 0 ] && echo 0 || echo 1)
