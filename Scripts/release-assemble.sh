#!/bin/bash
# 组装一个发布包(13 票)—— 各平台单文件 `a2` + 随包静态文本 + 安装脚本 + `a2-panel.app` + 发布元数据。
#
#   bash Scripts/release-assemble.sh [--output <dir>] [--targets a,b] [--bin <平台>=<路径>]…
#                                    [--app <A2 Panel.app 或 .zip>] [--base <渠道根地址>]
#                                    [--skip-self-check]
#
# ============================================================================
# 产出物(全部落在 --output 目录,**不入库**:.gitignore 挡着 .build/)
# ============================================================================
#   a2-<平台>                       内核单文件 bin(60–95MiB;bun compile,内置运行时)
#   NOTICE-external-programs.txt    外部程序声明 —— **`a2 about` 的输出原样落盘**(同一份字节)
#   LICENSE-mihomo-GPL-3.0.txt      GPL-3.0 全文(docs/legal/ 那一份)
#   install.sh                      curl 安装脚本(Scripts/install.sh 原样)
#   A2-Panel-<版本>-macos.zip       菜单栏壳 **+ 内嵌的内核 bin**(要 --app 才有):
#                                   14 票起它是**小白的完整包** —— 下载、打开、点「安装并启动」,
#                                   不必先开终端敲 `a2 service install`(ADR 0012)。约 24MiB。
#   a2-release.json                 发布元数据:版本、各工件 SHA-256、**mihomo 锁定版**、
#                                   **面板包内嵌的内核版本**
#
# ============================================================================
# 四条纪律
# ============================================================================
#   ① **平台表只有一份**(`kernel/src/release/manifest.ts`),本脚本经 release-targets.ts 读它 ——
#      资产名在两处手写就会与元数据对不上,而安装脚本正是按元数据的名字去下载。
#   ② **声明文本不是手抄的**:跑 `a2 about` 落盘。抄一份的那一刻,随包文本就开始与 bin 漂移了。
#   ③ **自检**:组装完用**包里那个 bin** 跑一次 `a2 about --json`,确认它看得见随包的两份文本
#      (`present: true`)。少拷一份声明的发布包,在这里就该停下,而不是发出去之后才发现。
#      (`--skip-self-check` 只给"用假 bin 验脚本结构"的测试用。)
#   ④ **一个发布包里只许有一版内核**(14 票):`.app` 里嵌着内核 bin,于是内核在包里有两处落点。
#      版本不是抄来的 —— 解开 zip、拿包里那份 bin 跑一次 `version`;自检再解一次、再跑一次,
#      与元数据字段、与单文件那份的版本**三处对账**。两版内核的发布包会让用户装到哪一版全看他点了哪里。
#
# 交叉编译:`--target=bun-linux-x64` 首次会下载对应的目标运行时(要联网,可能几分钟);
#   之后走 bun 的缓存。本机跑不了 Linux 产物 —— 只验"能产出 + ELF 文件头对"(13 票如实记账)。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/.build/release"
# 元数据文件名:与 `manifest.ts::RELEASE_METADATA_FILE`、`install.sh::METADATA_FILE` 是同一个
#   (三处一致有断言:`kernel/test/release-manifest.test.ts` ▸ 元数据文件名三处一致)。
METADATA_FILE="a2-release.json"
TARGETS=""
APP_SOURCE=""
CHANNEL_BASE=""
SELF_CHECK=1
PREBUILT=()   # "平台=路径"

BUN_BIN="$(command -v bun 2>/dev/null)"
[ -z "$BUN_BIN" ] && [ -x "$HOME/.bun/bin/bun" ] && BUN_BIN="$HOME/.bun/bin/bun"
[ -n "$BUN_BIN" ] || { echo "FAIL: 找不到 bun(内核是 TS,没有它出不了产物)"; exit 1; }

die() { echo "FAIL: $1" >&2; exit 1; }
need_value() { [ "$2" -ge 2 ] || die "$1 需要一个值"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --output) need_value --output $#; OUTPUT="$2"; shift 2 ;;
    --targets) need_value --targets $#; TARGETS="$2"; shift 2 ;;
    --bin) need_value --bin $#; PREBUILT+=("$2"); shift 2 ;;
    --app) need_value --app $#; APP_SOURCE="$2"; shift 2 ;;
    --base) need_value --base $#; CHANNEL_BASE="$2"; shift 2 ;;
    --skip-self-check) SELF_CHECK=0; shift ;;
    -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
    *) die "未知参数:$1" ;;
  esac
done

# ---- 平台表(唯一来源在 TS 侧)-----------------------------------------------------
TABLE="$("$BUN_BIN" run "$ROOT/kernel/scripts/release-targets.ts")" || die "读不到平台表"
if [ -z "$TARGETS" ]; then
  TARGETS="$(printf '%s\n' "$TABLE" | awk -F'\t' '$4=="yes"{printf "%s%s", sep, $1; sep=","}')"
fi

asset_of()  { printf '%s\n' "$TABLE" | awk -F'\t' -v p="$1" '$1==p{print $2}'; }
target_of() { printf '%s\n' "$TABLE" | awk -F'\t' -v p="$1" '$1==p{print $3}'; }

# 本机平台键(与 install.sh / KERNEL_TARGETS 同一套写法:x64 而非 amd64)。
host_platform() {
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    *) echo ""; return ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch="arm64" ;;
    x86_64|amd64) arch="x64" ;;
    *) echo ""; return ;;
  esac
  printf '%s-%s' "$os" "$arch"
}
HOST_PLATFORM="$(host_platform)"

prebuilt_for() {  # $1=平台 → 路径(没有就空)
  local entry
  for entry in ${PREBUILT+"${PREBUILT[@]}"}; do
    case "$entry" in
      "$1="*) printf '%s' "${entry#*=}"; return ;;
    esac
  done
  printf ''
}

echo "==== release-assemble.sh ===="
echo "  输出   $OUTPUT"
echo "  平台   $TARGETS"

rm -rf "$OUTPUT" || die "清不掉旧的输出目录:$OUTPUT"
mkdir -p "$OUTPUT" || die "建不了输出目录:$OUTPUT"

# ---- ① 内核 bin ------------------------------------------------------------------
IFS=',' read -r -a TARGET_LIST <<<"$TARGETS"
for platform in "${TARGET_LIST[@]}"; do
  [ -n "$platform" ] || continue
  asset="$(asset_of "$platform")"
  bun_target="$(target_of "$platform")"
  [ -n "$asset" ] && [ -n "$bun_target" ] || die "平台表里没有 $platform(可选:$(printf '%s\n' "$TABLE" | cut -f1 | tr '\n' ' '))"

  given="$(prebuilt_for "$platform")"
  if [ -n "$given" ]; then
    [ -f "$given" ] || die "--bin $platform= 指的文件不存在:$given"
    cp "$given" "$OUTPUT/$asset" || die "拷贝 $given 失败"
    echo "-- $platform:用现成产物 $given"
  else
    echo "-- $platform:bun build --compile --target=$bun_target"
    ( cd "$ROOT/kernel" && "$BUN_BIN" build ./src/cli/main.ts --compile --target="$bun_target" \
        --outfile "$OUTPUT/$asset" ) || die "编译 $platform 失败"
  fi
  chmod 755 "$OUTPUT/$asset"
done

# ---- ② 随包静态文本:`a2 about` 的输出原样落盘 -------------------------------------
# **顺序有讲究**(13 票 CR 必修 1a):GPL 全文必须**先**拷进来,`a2 about` 才可能说出
# 「与 a2 同目录,已就位」。反过来的话,随包 NOTICE 会自述「GPL 全文不在此处」,
# 而那份全文就躺在它旁边 —— 一份自己打自己脸的法律声明。
cp "$ROOT/docs/legal/LICENSE-mihomo-GPL-3.0.txt" "$OUTPUT/" || die "拷 GPL 全文失败"
cp "$ROOT/Scripts/install.sh" "$OUTPUT/install.sh" || die "拷安装脚本失败"
chmod 755 "$OUTPUT/install.sh" || die "给 install.sh 加执行位失败"

# 优先用**包里那个本机 bin**(它就是用户将来跑的那一份);本次没产出本机平台时回落源码入口 ——
# 两者是同一份源码渲染出来的同一段文字,但用 bin 更能证明"这份包里的 a2 说得出这段话"。
NOTICE="$OUTPUT/NOTICE-external-programs.txt"
HOST_ASSET=""
[ -n "$HOST_PLATFORM" ] && HOST_ASSET="$(asset_of "$HOST_PLATFORM")"
if [ -n "$HOST_ASSET" ] && [ -x "$OUTPUT/$HOST_ASSET" ]; then
  "$OUTPUT/$HOST_ASSET" about >"$NOTICE" || die "跑 a2 about 失败(包里的本机 bin)"
  echo "-- 声明文本:由 $HOST_ASSET about 产出"
else
  ( cd "$ROOT/kernel" && "$BUN_BIN" run ./src/cli/main.ts about ) >"$NOTICE" \
    || die "跑 a2 about 失败(源码入口)"
  echo "-- 声明文本:由源码入口产出(本次没有本机平台的产物)"
fi
[ -s "$NOTICE" ] || die "声明文本是空的 —— GPL 义务的随包落点不能是个空文件"

# ---- ③ 版本号:问 bin 自己(单一来源)---------------------------------------------
if [ -n "$HOST_ASSET" ] && [ -x "$OUTPUT/$HOST_ASSET" ]; then
  VERSION="$("$OUTPUT/$HOST_ASSET" version 2>/dev/null | tr -d '\r\n')"
else
  VERSION="$( ( cd "$ROOT/kernel" && "$BUN_BIN" run ./src/cli/main.ts version ) 2>/dev/null | tr -d '\r\n')"
fi
[ -n "$VERSION" ] || die "问不出版本号"

# ---- ④ 可选随附:A2 Panel.app(**自带内核的完整包**)-------------------------------
# 内嵌内核 bin 在包里的名字与 `Scripts/build-app.sh::KERNEL_EXE_NAME` 是同一个(有对账断言:
#   `kernel/test/release-manifest.test.ts` ▸ 内嵌内核 bin 的落点两处一致)。
PANEL_KERNEL_NAME="a2"
PANEL_KERNEL_VERSION=""

# 解开一个面板 zip,把里面那份内嵌内核 bin 跑起来问版本。**每次调用都重解一遍**(自检要的就是
#   "对着最终那个 zip 再问一次"),用完即删。`A2_HOME` 指到一次性目录 —— 组装机的真实 `~/.a2` 不许被碰。
panel_kernel_version_of() {  # $1=zip → stdout 版本(取不到则非零返回)
  local zip="$1" work home bin version
  work="$(mktemp -d "${TMPDIR:-/tmp}/a2-panel-probe-XXXXXX")" || return 1
  if command -v ditto >/dev/null 2>&1; then
    ditto -x -k "$zip" "$work" >/dev/null 2>&1 || { rm -rf "$work"; return 1; }
  elif command -v unzip >/dev/null 2>&1; then
    unzip -q "$zip" -d "$work" >/dev/null 2>&1 || { rm -rf "$work"; return 1; }
  else
    rm -rf "$work"; return 1
  fi
  # **恰好一个**(14 票 CR 尾款,与 APP8「恰 N 个可执行」同一纪律):zip 里出现两份 `.app`
  #   (压错了目录、误把 `--output` 整个压进去)时,`head -n 1` 会静默挑第一个,于是"我们验的是哪一份"
  #   变成运气问题 —— 而元数据只记一个版本号。多匹配就当场非零返回,让调用方红。
  local matches count
  matches="$(find "$work" -type f -path "*/Contents/Resources/$PANEL_KERNEL_NAME")"
  count="$(printf '%s\n' "$matches" | grep -c .)"
  [ "$count" = "1" ] || { rm -rf "$work"; return 1; }
  bin="$matches"
  [ -n "$bin" ] && [ -x "$bin" ] || { rm -rf "$work"; return 1; }
  home="$(mktemp -d "${TMPDIR:-/tmp}/a2-panel-home-XXXXXX")" || { rm -rf "$work"; return 1; }
  version="$(A2_HOME="$home" "$bin" version 2>/dev/null | tr -d '\r\n')"
  rm -rf "$work" "$home"
  [ -n "$version" ] || return 1
  printf '%s' "$version"
}

if [ -n "$APP_SOURCE" ]; then
  APP_ZIP="$OUTPUT/A2-Panel-$VERSION-macos.zip"
  case "$APP_SOURCE" in
    *.zip)
      cp "$APP_SOURCE" "$APP_ZIP" || die "拷 .app 压缩包失败" ;;
    *)
      [ -d "$APP_SOURCE" ] || die "--app 既不是 .zip 也不是一个 .app 目录:$APP_SOURCE"
      command -v ditto >/dev/null 2>&1 || die "压 .app 需要 ditto(macOS 自带);非 mac 上请先自己压好再 --app <zip>"
      # ditto -c -k --keepParent:保住 bundle 的符号链接与扩展属性,签名不会被压坏。
      ditto -c -k --keepParent "$APP_SOURCE" "$APP_ZIP" || die "压 .app 失败" ;;
  esac
  PANEL_KERNEL_VERSION="$(panel_kernel_version_of "$APP_ZIP")" || die \
    "面板包里问不出内嵌内核的版本($(basename "$APP_ZIP"))。
  zip 里必须**恰好一份** Contents/Resources/$PANEL_KERNEL_NAME 且能在本机跑起来 —— 14 票起 .app 是
  自带内核的完整包(ADR 0012)。三种停在这里的情形:①拿了 14 票之前的旧 .app;②zip 里压进了两份 .app
  (那样"验的是哪一份"就成了运气);③那份 bin 跑不起来。
  重出一个:bash Scripts/build-app.sh --output .build/app"
  echo "-- 随附壳:$(basename "$APP_ZIP")(内嵌内核 $PANEL_KERNEL_VERSION)"
fi

# ---- ⑤ 发布元数据(摘要 + mihomo 锁定版 + 面板内嵌内核版本)------------------------
"$BUN_BIN" run "$ROOT/kernel/scripts/render-release-manifest.ts" \
    "$OUTPUT" "$VERSION" "$CHANNEL_BASE" "$PANEL_KERNEL_VERSION" \
  || die "生成发布元数据失败(常见原因:发布包里混进了 classifyArtifact 不认识的文件;
  或面板包内嵌的内核与本次发布的内核不同版 —— schema 结构约束③ 会当场拒)"

# ---- ⑥ 自检:包里那个 bin 看得见随包的两份文本吗 ------------------------------------
if [ "$SELF_CHECK" = "1" ]; then
  [ -n "$HOST_ASSET" ] && [ -x "$OUTPUT/$HOST_ASSET" ] \
    || die "自检需要本机平台的产物($HOST_PLATFORM);只交叉编译时请显式 --skip-self-check"
  ABOUT_JSON="$("$OUTPUT/$HOST_ASSET" about --json)" || die "自检:a2 about --json 跑不起来"
  PRESENT_COUNT="$(printf '%s' "$ABOUT_JSON" | grep -o '"present":true' | wc -l | tr -d ' ')"
  [ "$PRESENT_COUNT" = "2" ] \
    || die "自检:包里的 a2 只看见 $PRESENT_COUNT 份随包静态文本(应为 2)—— 声明文本没落对位置"

  # **随包 NOTICE ≡ 包里那个 a2 此刻的 about 输出**(13 票 CR 必修 1c)。
  # 「同一份字节」这句话是本票的核心承诺(声明不是手抄的),那就把它验成字节级的:
  # 重跑一次 about,与落盘那份 `cmp`。顺序装错、渲染改了、有人手改过 NOTICE —— 都在这里现形。
  # 落在**发布包外面**:包里多一个文件会让下一次 `render-release-manifest` 报「不认识的文件」。
  RECHECK="$(mktemp "${TMPDIR:-/tmp}/a2-notice-recheck-XXXXXX")"
  "$OUTPUT/$HOST_ASSET" about >"$RECHECK" || die "自检:重跑 a2 about 失败"
  cmp -s "$RECHECK" "$NOTICE" || {
    rm -f "$RECHECK"
    die "自检:随包 NOTICE 与包里 a2 的 about 输出不是同一份字节"
  }
  rm -f "$RECHECK"

  # 内容自检(13 票 CR 必修 1d):随包声明里不许出现「不在此处」——
  # 那句话的意思是"这份文本旁边没有 GPL 全文",而发布包里它就在旁边。
  grep -q "不在此处" "$NOTICE" \
    && die "自检:随包 NOTICE 里出现「不在此处」—— 它在自述随包文本缺失,而它们就在同目录"
  grep -q "$OUTPUT" "$NOTICE" \
    && die "自检:随包 NOTICE 里烙进了组装机的绝对路径($OUTPUT)—— 那条路径对用户毫无意义"

  # **一个发布包里只许有一版内核**(14 票)。三处对账,而且三处都是**现场问出来的**,不是互相抄:
  #   ① 单文件那份(= 版本单一来源:上面 ③ 步问的就是包里那个 a2 自己);
  #   ② 元数据里的 `embeddedKernelVersion` 字段(从写好的 JSON 里抠出来);
  #   ③ **重新解一遍最终那个 zip**、把里面那个 bin 再跑一次 —— 与 ⑤ 步传给渲染器的那个值互相独立,
  #      于是"传错了值"与"zip 与元数据脱节"这两种事各自都拦得住。
  if [ -n "$APP_SOURCE" ]; then
    META_PANEL_VERSION="$(grep '"kind":"panel-app"' "$OUTPUT/$METADATA_FILE" \
      | sed -n 's/.*"embeddedKernelVersion":"\([^"]*\)".*/\1/p' | head -n 1)"
    ZIP_PANEL_VERSION="$(panel_kernel_version_of "$APP_ZIP")" \
      || die "自检:最终那个面板 zip 里问不出内嵌内核版本"
    [ "$ZIP_PANEL_VERSION" = "$VERSION" ] && [ "$META_PANEL_VERSION" = "$VERSION" ] || die \
      "自检:一个发布包里出现了两版内核 —— zip 里内嵌 '$ZIP_PANEL_VERSION',元数据记 '$META_PANEL_VERSION',单文件那份是 '$VERSION'"
    echo "-- 自检通过:面板包内嵌内核 = 元数据字段 = 单文件那份 = $VERSION(三处对账)"
  fi
  echo "-- 自检通过:两份静态文本就位、NOTICE 与 about 输出逐字节相同、无组装机路径"
fi

# ---- 收口 ------------------------------------------------------------------------
echo
echo "OK: $OUTPUT"
ls -l "$OUTPUT" | awk 'NR>1 {printf "    %-34s %10s 字节\n", $NF, $5}'
echo
echo "发布渠道:${CHANNEL_BASE:-(未定 —— 元数据里 channel.status=undecided,安装脚本会明说)}"
echo "试装(不出网):A2_RELEASE_BASE=\"$OUTPUT\" A2_INSTALL_DIR=/tmp/a2-try sh \"$OUTPUT/install.sh\""
