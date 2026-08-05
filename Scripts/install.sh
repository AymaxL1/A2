#!/bin/sh
# a2 安装脚本 —— 一条命令装好内核 bin(13 票 / ADR 0008 分发节)。
#
#   curl -fsSL <发布渠道>/install.sh | sh
#   sh install.sh --dir ~/.local/bin        # 指定落点
#   sh install.sh --uninstall               # 卸载(带前置检查,见文末)
#
# ============================================================================
# 五条纪律(每条都有断言盯着,见 kernel/test/install-script.test.ts)
# ============================================================================
#   ① **摘要必须对上**。资产的 SHA-256 来自发布元数据 `a2-release.json`,对不上就一个字节也不落盘。
#      "先装了再说"在一个会被 curl | sh 的脚本里是不可接受的。
#   ② **幂等**。同一版本重跑:不下载、不改动、退出码 0,照样把下一步指引打全。
#   ③ **没有静默更新**。本脚本不留任何定时任务、不写 shell 配置、不后台自查版本 ——
#      升级 = 你自己再跑一次这条命令(或直接换掉那个单文件)。
#   ④ **不碰系统托管**。装完只**打印** `a2 service install`,绝不替你 launchctl / systemctl。
#      系统状态的改变永远是用户显式发起的(ADR 0008 第 6 条)。
#   ⑤ **卸载先看后删**。unit 文件还在、系统代理还被接管着的时候,脚本**拒绝**删 bin ——
#      因为删完之后那两件事就没有工具能收拾了(它们的清理命令正是 a2 自己)。
#
# ============================================================================
# POSIX sh,不用 jq
# ============================================================================
# 装 a2 之前不该先装一个 JSON 解析器。元数据因此约定成"每个工件一行"(见
# `kernel/src/release/manifest.ts::renderReleaseManifest` 的头注),这里用 grep + sed 抠字段。
# 那条格式约定有测试钉着,两边不许各写各的。
set -eu

# ---- 单一来源:改这里,不要在别处再写一遍 ----------------------------------------
# ⚠️ **发布渠道未定**(13 票如实记账):`.invalid` 是 RFC 2606 保留域,永远解析不了 ——
#   所以"渠道没配"是一条会当场失败并给出指引的事实,而不是一个看起来能用、点下去 404 的假地址。
#   这个字面量与 `kernel/src/release/manifest.ts::RELEASE_CHANNEL_PLACEHOLDER` 必须一致(有断言)。
DEFAULT_RELEASE_BASE="https://RELEASE-CHANNEL-UNDECIDED.invalid/a2"
METADATA_FILE="a2-release.json"
SCHEMA_ID="a2-release/1"
# 默认落点:**用户目录,不要 sudo**。`/usr/local/bin` 在新 mac 上默认不存在且要管理员权限,
#   而一个 curl | sh 的脚本去要 sudo 是最不该有的姿势。`~/.local/bin` 是 XDG 的通行约定,
#   不在 PATH 里时脚本会明说该怎么加(**不替你改 shell 配置**)。
DEFAULT_INSTALL_DIR="$HOME/.local/bin"
BIN_NAME="a2"

RELEASE_BASE="${A2_RELEASE_BASE:-$DEFAULT_RELEASE_BASE}"
INSTALL_DIR="${A2_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
METADATA_SOURCE=""
ACTION="install"

die() { printf '错误:%s\n' "$1" >&2; exit 1; }
info() { printf '%s\n' "$1"; }

usage() {
  cat <<USAGE
a2 安装脚本 —— 下载单文件内核 bin、校验 SHA-256、落 PATH

用法:
  sh install.sh [--dir <目录>] [--base <地址或本地目录>] [--metadata <地址或路径>]
  sh install.sh --uninstall [--dir <目录>]

参数:
  --dir <目录>       bin 落点(默认 $DEFAULT_INSTALL_DIR;env: A2_INSTALL_DIR)
  --base <地址>      发布渠道根地址,资产按 <base>/<工件名> 取(env: A2_RELEASE_BASE)
                     也收本地目录或 file:// —— 离线/内网分发直接指过去即可
  --metadata <地址>  直接指定发布元数据(默认 <base>/$METADATA_FILE)
  --uninstall        卸载(会先检查服务与系统代理是否还挂着,见下)
  -h, --help         打印本帮助

升级:**没有静默更新**。重跑本脚本即升级;换了 bin 位置记得重跑 a2 service install。
卸载:先 a2 proxy off、a2 service uninstall、a2 mihomo uninstall,再 --uninstall 删 bin,
      最后按需 rm -rf ~/.a2(里面有插件工件、订阅、mihomo 自管目录)。
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || die "--dir 需要一个值"; INSTALL_DIR="$2"; shift 2 ;;
    --base) [ $# -ge 2 ] || die "--base 需要一个值"; RELEASE_BASE="$2"; shift 2 ;;
    --metadata) [ $# -ge 2 ] || die "--metadata 需要一个值"; METADATA_SOURCE="$2"; shift 2 ;;
    --uninstall) ACTION="uninstall"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "未知参数:$1" ;;
  esac
done

TARGET="$INSTALL_DIR/$BIN_NAME"

# ---- 取文件:http(s) / file:// 走 curl 或 wget,本地路径直接拷 ----------------------
fetch_to() {  # $1=来源 $2=落点
  case "$1" in
    http://*|https://*|file://*)
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2" || return 1
      elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1" || return 1
      else
        die "既没有 curl 也没有 wget —— 装不了。"
      fi
      ;;
    *)
      [ -f "$1" ] || return 1
      cp "$1" "$2" || return 1
      ;;
  esac
}

# 校验工具**开工前就探好**(13 票 CR 必修 3)。此前这段探测写在 `sha256_of` 里,而它总是在
# `$( )` 里被调用 —— 子壳里的 `die` 只杀得掉子壳,外面照跑:于是一台没有 shasum 的机器会
# **先下完 60MiB 再死**,而且死在一个看不懂的地方。判据前置、一次探清,缺工具当场停。
HASH_CMD=""
if command -v shasum >/dev/null 2>&1; then
  HASH_CMD="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then
  HASH_CMD="sha256sum"
fi

sha256_of() {  # $1=文件 → stdout 小写十六进制
  # shellcheck disable=SC2086 —— HASH_CMD 是我们自己拼的两三个词,要按词拆开。
  $HASH_CMD "$1" | cut -d' ' -f1
}

# ---- 平台探测 --------------------------------------------------------------------
# 平台键的写法(x64 而非 amd64)与 `kernel/src/release/manifest.ts::KERNEL_TARGETS` 一致(有断言)。
detect_platform() {
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Darwin) os_key="darwin" ;;
    Linux) os_key="linux" ;;
    *) die "不支持的操作系统:$os(a2 当下承诺 macOS 与 Linux;Windows 是远景,见 ADR 0009)。" ;;
  esac
  case "$arch" in
    arm64|aarch64) arch_key="arm64" ;;
    x86_64|amd64) arch_key="x64" ;;
    *) die "不支持的 CPU 架构:$arch(已发布的资产只有 arm64 与 x64)。" ;;
  esac
  printf '%s-%s' "$os_key" "$arch_key"
}

# ---- 卸载 ------------------------------------------------------------------------
# **先看后删**(纪律⑤):判据全是**文件是否存在**,不调 launchctl / systemctl、不改任何系统状态。
do_uninstall() {
  a2_home="${A2_HOME:-$HOME/.a2}"
  # systemd user 单元的位置**与内核同源**(13 票 CR 必修 2):`src/service/unit.ts` 尊重
  # `XDG_CONFIG_HOME`,这里只查 `~/.config` 就会在改过位的 Linux 机器上看不见那些 unit ——
  # 「先看后删」于是被绕过,bin 被删掉、unit 却还挂着,而收拾它的工具正是刚被删掉的那个。
  # 两条都查(XDG 与默认位):判据宁可宽,不可漏。
  xdg_config="${XDG_CONFIG_HOME:-$HOME/.config}"
  blockers=""
  for unit in \
    "$HOME/Library/LaunchAgents/com.a2.kernel.plist" \
    "$HOME/Library/LaunchAgents/com.a2.mihomo.plist" \
    "$xdg_config/systemd/user/com.a2.kernel.service" \
    "$xdg_config/systemd/user/com.a2.mihomo.service" \
    "$HOME/.config/systemd/user/com.a2.kernel.service" \
    "$HOME/.config/systemd/user/com.a2.mihomo.service"
  do
    case "$blockers" in *"  $unit"*) continue ;; esac   # XDG 就是默认位时别列两遍
    [ -f "$unit" ] && blockers="$blockers  $unit
"
  done
  [ -f "$a2_home/system-proxy.json" ] && blockers="$blockers  $a2_home/system-proxy.json(系统代理正被 a2 接管着)
"

  if [ -n "$blockers" ]; then
    printf '拒绝卸载:还有东西挂在系统上,而收拾它们的工具正是 a2 自己。\n\n' >&2
    printf '%s\n' "$blockers" >&2
    cat >&2 <<'BLOCKED'
先按顺序跑完这几条(每条都是幂等的),再回来卸载:

  a2 proxy off              还原系统代理到接管前(「退出即还原」已废除,这是唯一的还原入口)
  a2 service uninstall      停掉并移除 com.a2.kernel
  a2 mihomo uninstall       停掉并移除 a2 自管的那份 mihomo(不动你自己装的那份)

然后:
  sh install.sh --uninstall
BLOCKED
    exit 1
  fi

  if [ -f "$TARGET" ]; then
    rm -f "$TARGET"
    info "已删除 $TARGET"
  else
    info "$TARGET 不在(可能已经卸过了)—— 未作改动。"
  fi
  cat <<REMAINING

还剩下这些**数据**,脚本不替你决定(删了就没了):
  ${A2_HOME:-$HOME/.a2}/            插件工件与清单、订阅、日志、a2 自管的 mihomo 目录与配置
  要一并清掉就:rm -rf ${A2_HOME:-$HOME/.a2}

没动过的东西:你自己装的 mihomo、你自己的 launchd/systemd 单元、shell 配置文件。
REMAINING
}

if [ "$ACTION" = "uninstall" ]; then
  do_uninstall
  exit 0
fi

# ---- 安装 ------------------------------------------------------------------------
# 没有校验手段就不装(纪律①)——在**任何下载之前**停,而不是下完 60MiB 才发现。
[ -n "$HASH_CMD" ] \
  || die "找不到 shasum / sha256sum —— 没有办法校验下载物,拒绝安装。
装一个(如 coreutils)之后重试,或者直接下载单文件 a2 并自行核对发布元数据里的摘要。"

PLATFORM="$(detect_platform)"

if [ -z "$METADATA_SOURCE" ]; then
  if [ "$RELEASE_BASE" = "$DEFAULT_RELEASE_BASE" ]; then
    cat >&2 <<UNDECIDED
错误:发布渠道尚未确定,脚本没有可下载的地址。

这是 a2 当前的**真实状态**(13 票如实记账:仓库无 remote、无发布渠道),不是配置错误。
两条可走的路:

  ① 已经有一份发布包(哪怕在本地目录里):
       A2_RELEASE_BASE=/path/to/release sh install.sh
       A2_RELEASE_BASE=https://你的地址/a2 sh install.sh
  ② 只有单文件 a2:根本不需要本脚本 —— chmod +x a2 && mv a2 ~/.local/bin/,
     然后 a2 about 读许可声明、a2 service install 装常驻。
UNDECIDED
    exit 1
  fi
  METADATA_SOURCE="$RELEASE_BASE/$METADATA_FILE"
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/a2-install-XXXXXX")"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

META="$WORKDIR/$METADATA_FILE"
fetch_to "$METADATA_SOURCE" "$META" || die "取不到发布元数据:$METADATA_SOURCE"

grep -q "\"schema\": \"$SCHEMA_ID\"" "$META" \
  || die "发布元数据不是本脚本认得的格式($SCHEMA_ID):$METADATA_SOURCE"

VERSION="$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$META" | head -n 1)"
MIHOMO_VERSION="$(sed -n 's/.*"lockedVersion": "\([^"]*\)".*/\1/p' "$META" | head -n 1)"
[ -n "$VERSION" ] || die "发布元数据里没有版本号。"

# 工件一行一个(与 renderReleaseManifest 的约定),所以一条 grep 就能拿到完整信息。
LINE="$(grep '"kind":"kernel-bin"' "$META" | grep "\"platform\":\"$PLATFORM\"" | head -n 1 || true)"
[ -n "$LINE" ] || die "这个发布里没有 $PLATFORM 的内核 bin(元数据:$METADATA_SOURCE)。"
ASSET="$(printf '%s' "$LINE" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')"
EXPECTED="$(printf '%s' "$LINE" | sed -n 's/.*"sha256":"\([^"]*\)".*/\1/p')"
[ -n "$ASSET" ] && [ -n "$EXPECTED" ] || die "元数据里 $PLATFORM 那条工件缺 name 或 sha256。"

info "a2 $VERSION($PLATFORM)"
info "  资产    $ASSET"
info "  摘要    $EXPECTED"
info "  落点    $TARGET"

# ---- 幂等(纪律②):已经是这一版就什么都不做,连下载都省了 --------------------------
if [ -f "$TARGET" ] && [ "$(sha256_of "$TARGET")" = "$EXPECTED" ]; then
  info ""
  info "已经是这一版(摘要逐字相同)—— 未下载、未改动任何东西。"
  ALREADY_INSTALLED=1
else
  ALREADY_INSTALLED=0
  DOWNLOAD="$WORKDIR/$BIN_NAME"
  info ""
  info "下载中……(单文件约 60–90MiB,内置完整运行时)"
  fetch_to "$RELEASE_BASE/$ASSET" "$DOWNLOAD" || die "下载失败:$RELEASE_BASE/$ASSET"

  ACTUAL="$(sha256_of "$DOWNLOAD")"
  if [ "$ACTUAL" != "$EXPECTED" ]; then
    rm -f "$DOWNLOAD"
    die "SHA-256 对不上,已丢弃下载物(一个字节都没落到 $INSTALL_DIR)。
  期望 $EXPECTED
  实得 $ACTUAL
可能是下载被截断、渠道被中间人改过,或元数据与资产不是同一次发布的。"
  fi
  chmod 755 "$DOWNLOAD"

  # 自检:装进去之前先让它自报一次版本。连这一步都过不了的东西,不该落进你的 PATH。
  "$DOWNLOAD" version >/dev/null 2>&1 || die "下载物跑不起来(a2 version 失败)—— 未安装。"

  mkdir -p "$INSTALL_DIR" || die "建不了目录:$INSTALL_DIR"
  # 先落到同目录的临时名再 mv:同一文件系统内的 rename 是原子的,
  #   替换正在被别的进程执行的 bin 也不会撕成两半。
  STAGING="$INSTALL_DIR/.$BIN_NAME.new.$$"
  cp "$DOWNLOAD" "$STAGING" || die "写不进 $INSTALL_DIR(权限?)"
  chmod 755 "$STAGING"
  mv -f "$STAGING" "$TARGET" || { rm -f "$STAGING"; die "就位失败:$TARGET"; }
  info "已安装 $TARGET"
fi

# ---- 下一步指引 ------------------------------------------------------------------
IN_PATH=0
case ":$PATH:" in
  *":$INSTALL_DIR:"*) IN_PATH=1 ;;
esac

info ""
info "下一步:"
if [ "$IN_PATH" = "0" ]; then
  info "  0) $INSTALL_DIR 不在你的 PATH 里。把这一行加进 shell 配置(脚本不替你改文件):"
  info "       export PATH=\"$INSTALL_DIR:\$PATH\""
  info "     本次会话可先跑:export PATH=\"$INSTALL_DIR:\$PATH\""
fi
info "  1) 装成系统托管的常驻服务(开机自启、崩溃自愈全归系统;幂等):"
info "       a2 service install"
info "  2) 让 mihomo 就位(检测并优先复用你已有的那份;锁定版 ${MIHOMO_VERSION:-见 a2 about}):"
info "       a2 mihomo install"
info "  3) 读一遍许可与外部程序声明(GPL 义务落点,不依赖任何 UI):"
info "       a2 about"
info "  4) 看看能干什么(agent 直接读 --json):"
info "       a2 help    /    a2 capabilities list --json"
info ""
info "几件要知道的事:"
info "  * **升级永远显式**:重跑本脚本即升级;a2 不做静默更新、不后台自查版本。"
info "  * **换了 bin 的位置就重跑 a2 service install** —— unit 里写的是当时那个绝对路径,"
info "    重跑是幂等的,会把 unit 收敛到新位置。"
info "  * 卸载:sh install.sh --uninstall(它会先检查服务与系统代理还挂没挂着)。"
if [ "$ALREADY_INSTALLED" = "1" ]; then
  info "  * 本次是幂等重跑:没有下载、没有改动。"
fi
