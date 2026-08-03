# --- 断言组 APP:`.app` 壳(12 票;手工组 bundle + ad-hoc 签名)+ GPL 义务(15 票)---
#
# 本组把 `Scripts/build-app.sh` 的产物当被测物:production 档只做静态断言,e2e 档跑全链。
#
# 15 票在本组追加 4 条(APP7–APP10),**共用同一批产物、共用 e2e 档那一个宿主**:
#   多起一次宿主 = 门禁多花几秒 + 多一份残留风险,而这 4 条要的东西那个宿主全都有。
#
# ⚠️ **硬约束:只有 e2e 档能起宿主,production 档一律只做静态断言,绝不启动。**
#    理由不是洁癖,是会污染用户真实环境:把内核数据目录导向临时区的 env seam `AA_MIHOMO_DATA_DIR`
#    在 `Sources/AAHostMacOS/HostApp.swift` 里是 `#if AA_E2E` 门控的 —— production 构建里**根本没有
#    读它的那几行代码**。一旦起了 production 宿主,mihomo 的数据目录会落进真实的
#    `~/Library/Application Support/AA/mihomo`,那是用户的东西,门禁不许碰。
#    所以 production 档只验「结构 / plist / 签名」,e2e 档才验「真能跑」。
#
# 为什么用**直接 exec** `AA.app/Contents/MacOS/aahost` 而不是 `open`:
#    ① 直接 exec 时 `Bundle.main` 仍然是 `.app`(macOS 按可执行所在的 `Contents/MacOS/` 往上认 bundle),
#       故 `Bundle.main.resourceURL` / `LSUIElement` 等 bundle 语义一个不少 —— 被测面没有缩水;
#    ② 拿得到 PID,能按 PID 精确等待/收场。`open` 走 LaunchServices,进程与 shell 脱钩,只能靠模式匹配猜。
#    (`open` 那条路径本票已人肉验过一次可用,记在票面「实测记录」里;门禁里不用它。)
echo "--- 断言组 APP:.app 壳(production 静态 + e2e 全链)+ GPL 义务 ---"

APP_BUILD_LOG="$BUILD/build-app.log"
APP_PROD="$APP_OUT_PROD/AA.app"
APP_PROD_RES="$APP_PROD/Contents/Resources/PROJECT_AA_PluginProxy.bundle"

# 传 `AA_SWIFT`:build-app.sh 见到它就直接用,不再自己跑 `dump-package` 探一遍工具链
#   (bootstrap.sh 已经严格探过了,探第二遍纯属浪费;也避免两处判据漂移)。
AA_SWIFT="$SWIFT_BIN" bash "$ROOT/Scripts/build-app.sh" \
  --variant production --output "$APP_OUT_PROD" >"$APP_BUILD_LOG" 2>&1
APP_PROD_RC=$?

# (APP1) production 档 `.app` 构建成功且结构完整。
APP1_ERR=""
if [ "$APP_PROD_RC" -ne 0 ]; then
  APP1_ERR="build-app.sh --variant production 退出码=$APP_PROD_RC"
else
  [ -f "$APP_PROD/Contents/Info.plist" ]   || APP1_ERR="$APP1_ERR 缺 Contents/Info.plist;"
  [ -x "$APP_PROD/Contents/MacOS/aahost" ] || APP1_ERR="$APP1_ERR 缺 Contents/MacOS/aahost 或无执行位;"
  [ -x "$APP_PROD/Contents/MacOS/aa" ]     || APP1_ERR="$APP1_ERR 缺 Contents/MacOS/aa 或无执行位;"
  [ -d "$APP_PROD_RES" ]                   || APP1_ERR="$APP1_ERR 缺内核资源 bundle $APP_PROD_RES;"
  [ -x "$APP_PROD_RES/Resources/mihomo-darwin-arm64" ] || APP1_ERR="$APP1_ERR 内核可执行缺失或无执行位;"
fi
if [ -z "$APP1_ERR" ]; then
  echo "PASS: production 档 .app 一条命令构建成功且结构完整(Info.plist + aahost + aa + 内核资源 bundle,执行位正确)"
  PASS=$((PASS+1))
else
  echo "FAIL: production 档 .app 结构不完整:$APP1_ERR"; FAIL=$((FAIL+1))
  tail -20 "$APP_BUILD_LOG" 2>/dev/null | sed 's/^/    /'
fi

# (APP2) Info.plist:LSUIElement 为 true(菜单栏 accessory,无 Dock 图标),且 CFBundleExecutable 与实际可执行同名。
#   用 `plutil -extract` 取值 —— **不用 grep 猜 XML**:grep 只能证明文件里出现过某个字符串,
#   证明不了它是哪个键的值、类型对不对(`<true/>` vs 字符串 "true" 在 plist 语义里是两回事)。
#   顺带把 `LSMinimumSystemVersion` 与 `Package.swift` 的 `platforms` 对上:这两处是**同一个事实的两处书写**
#   (build-app.sh 的 MIN_MACOS 与清单的 .macOS(.v13)),只靠注释约定同步迟早会漂 ——
#   漂了的表现是 `.app` 声称支持的系统版本低于代码实际要求,装到旧系统上才崩。这里把它变成可核验的不变式。
#   不新增断言条数:并进本条,一起判。
APP2_UI="$(plutil -extract LSUIElement raw -o - "$APP_PROD/Contents/Info.plist" 2>/dev/null)"
APP2_EXEC="$(plutil -extract CFBundleExecutable raw -o - "$APP_PROD/Contents/Info.plist" 2>/dev/null)"
APP2_MIN="$(plutil -extract LSMinimumSystemVersion raw -o - "$APP_PROD/Contents/Info.plist" 2>/dev/null)"
APP2_PKG_MIN="$("$SWIFT_BIN" package dump-package --scratch-path "$BUILD/spm-arch-probe" 2>/dev/null | python3 -c '
import json, sys
try:
    pkg = json.load(sys.stdin)
except Exception:
    sys.exit(0)                      # 输出空串 → 下面判不相等 → FAIL(不静默算过)
for p in pkg.get("platforms", []):
    if p.get("platformName") == "macos":
        print(p.get("version", "")); break
' 2>/dev/null)"
if [ "$APP2_UI" = "true" ] && [ -n "$APP2_EXEC" ] && [ -x "$APP_PROD/Contents/MacOS/$APP2_EXEC" ] \
   && [ -n "$APP2_MIN" ] && [ "$APP2_MIN" = "$APP2_PKG_MIN" ]; then
  echo "PASS: Info.plist 的 LSUIElement=true、CFBundleExecutable='$APP2_EXEC' 与实际可执行同名、LSMinimumSystemVersion='$APP2_MIN' 与 Package.swift 的 macOS 平台声明一致"
  PASS=$((PASS+1))
else
  echo "FAIL: Info.plist 断言不成立(LSUIElement='$APP2_UI' 期望 true;CFBundleExecutable='$APP2_EXEC',对应可执行是否存在: $([ -n "$APP2_EXEC" ] && [ -x "$APP_PROD/Contents/MacOS/$APP2_EXEC" ] && echo 是 || echo 否);LSMinimumSystemVersion='$APP2_MIN' vs Package.swift='$APP2_PKG_MIN')"
  FAIL=$((FAIL+1))
fi

# (APP3) 签名可校验:`.app` 本体过 `--verify --strict`,且内嵌 mihomo 自己也有签名。
#   两者都要:只签壳不签内核,壳的封存会在 15 票重签内核那一刻失效;只签内核不签壳,`.app` 根本不成立。
APP3_V="$(codesign --verify --strict --verbose=2 "$APP_PROD" 2>&1)"; APP3_VRC=$?
APP3_K="$(codesign -dv "$APP_PROD_RES/Resources/mihomo-darwin-arm64" 2>&1)"; APP3_KRC=$?
# 判据同 APP8:两种签名形态的输出行不同,只认 `Signature=` 会在换真证书那天当场坏掉。
APP3_KSIG="$(grep -E '^Signature=adhoc|^Signature size=' <<<"$APP3_K" | head -1)"
if [ "$APP3_VRC" -eq 0 ] && [ "$APP3_KRC" -eq 0 ] && [ -n "$APP3_KSIG" ]; then
  echo "PASS: codesign --verify --strict 通过($(grep -F 'satisfies its Designated Requirement' <<<"$APP3_V" >/dev/null && echo '含 Designated Requirement'))且内嵌 mihomo 有签名($APP3_KSIG)"
  PASS=$((PASS+1))
else
  echo "FAIL: 签名校验不通过(verify rc=$APP3_VRC: $APP3_V;内核 codesign -dv rc=$APP3_KRC)"; FAIL=$((FAIL+1))
fi

# (APP7,15 票) GPL-3.0 全文随 `.app` 打包**且内容完整**:`.app` 内那份的 SHA-256 与仓库源文件一致。
#   为什么不硬编码期望哈希:那样每次换内核(换许可证文本版本)都要手改一处字面量,漏改就成了「比中旧哈希」的假绿;
#   现算现比则天然跟着源文件走。代价是「两份都被同样篡改」这一种情形挡不住 —— 但那种情形下仓库本身已经被改,
#   门禁不是防篡改工具,它防的是**打包链把文件漏了 / 截断了 / 拷坏了**,那才是真实会发生的故障。
#   **两边都真读文件**(shasum 打开并读完整个文件),不是只判 `-f` 存在 —— 只判存在会被一个 0 字节的同名文件骗过。
APP7_SRC="$ROOT/Sources/PluginProxy/Resources/LICENSE-mihomo-GPL-3.0.txt"
APP7_INAPP="$APP_PROD_RES/Resources/LICENSE-mihomo-GPL-3.0.txt"
APP7_H1="$(shasum -a 256 "$APP7_SRC" 2>/dev/null | awk '{print $1}')"
APP7_H2="$(shasum -a 256 "$APP7_INAPP" 2>/dev/null | awk '{print $1}')"
APP7_SIZE="$(wc -c < "$APP7_INAPP" 2>/dev/null | tr -d ' ')"
# 非空守卫:任一侧算不出哈希(文件不存在 / shasum 自身出错)都必须 FAIL —— 两边都空会「相等」,又是一次白送。
if [ -n "$APP7_H1" ] && [ "$APP7_H1" = "$APP7_H2" ] && [ "${APP7_SIZE:-0}" -gt 0 ]; then
  echo "PASS: GPL-3.0 全文随 .app 打包且内容完整(.app 内 ${APP7_SIZE} 字节,SHA-256 与仓库源文件一致: ${APP7_H1:0:16}…)"
  PASS=$((PASS+1))
else
  echo "FAIL: GPL-3.0 全文未随 .app 打包或内容不一致(源=${APP7_H1:-算不出} vs .app 内=${APP7_H2:-算不出};.app 内字节数=${APP7_SIZE:-无})"
  FAIL=$((FAIL+1))
fi

# (APP8,15 票) `.app` 内**所有 Mach-O** 都已签名,且签名身份一致。
#
# ⚠️ **诚实口径(不许含糊,票面同款措辞)**:当前是 ad-hoc 签名,`codesign -dv` 只给
#   `Signature=adhoc` / `TeamIdentifier=not set`,**没有 `Authority=` 证书链**(ad-hoc 根本没有证书)。
#   所以这条断言挡得住的是「`.app` 里混进一个**未签名**或**用别的身份签**的二进制」;
#   它**挡不住**「是不是同一张证书」—— 那个问题在 ad-hoc 下不存在。
#   13 票换成真开发证书之后,`Authority=` 叶子会出现在指纹里,这条断言才真的在比证书。
#   请勿把这条的 PASS 读成「签名有证书背书」。
#
# ⚠️ 两种签名形态的 `codesign -dvvv` 输出**不同行**,判据必须同时认得(这里踩过一次):
#     ad-hoc  → `Signature=adhoc`
#     真证书  → `Signature size=8981` + `Authority=Apple Development: …`(**没有** `Signature=` 这个字面串)
#   若只 grep `Signature=`,换真证书那天每个二进制都会落进「输出形状变了」分支而 FAIL ——
#   fail-closed 不至于假绿,但那不是「自动变强」,那是**当场坏掉**。故归一成 adhoc/real 两个取值再比。
#
# 指纹取三项的组合而不是只取签名种类:种类在 ad-hoc 下人人都是 adhoc,单看它区分度为零;
#   带上 TeamIdentifier 与 Authority(ad-hoc 下为空,真证书下非空)才是「身份」的完整表述。
# **Identifier 刻意不进指纹**:它本来就该每个可执行各不相同(15 票正是给内核补了 `com.aa.host.mihomo-…`,
#   替掉 Go 编译器留下的 `a.out`),拿它比一致等于要求所有二进制同名,是错的。
APP8_FP=""; APP8_ERR=""; APP8_N=0; APP8_LIST=""
while IFS= read -r f; do
  case "$(file -b "$f" 2>/dev/null)" in
    *Mach-O*) ;;
    *) continue ;;                       # 脚本/资源等非 Mach-O 的带执行位文件不在本条覆盖面内
  esac
  APP8_N=$((APP8_N+1))
  APP8_CS="$(codesign -dvvv "$f" 2>&1)"; APP8_RC=$?
  if [ "$APP8_RC" -ne 0 ]; then
    APP8_ERR="$APP8_ERR ${f#$APP_PROD/}=未签名(codesign -dvvv rc=$APP8_RC);"; continue
  fi
  # 归一签名种类:ad-hoc 报 `Signature=adhoc`,真证书报 `Signature size=NNNN`(两者都不含对方的字面串)。
  if grep -qF 'Signature=adhoc' <<<"$APP8_CS"; then
    APP8_SIG="Signature=adhoc"
  elif grep -qE '^Signature size=' <<<"$APP8_CS"; then
    APP8_SIG="Signature=real(有证书链)"
  else
    APP8_SIG=""
  fi
  APP8_TEAM="$(grep -F 'TeamIdentifier=' <<<"$APP8_CS" | head -1)"
  APP8_AUTH="$(grep -F 'Authority=' <<<"$APP8_CS" | head -1)"
  if [ -z "$APP8_SIG" ]; then
    APP8_ERR="$APP8_ERR ${f#$APP_PROD/}=codesign 既未报 Signature=adhoc 也未报 Signature size=(输出形状变了,无法核验);"; continue
  fi
  APP8_ONE="$APP8_SIG | $APP8_TEAM | ${APP8_AUTH:-Authority=(无证书链,ad-hoc)}"
  APP8_LIST="$APP8_LIST ${f#$APP_PROD/}"
  if [ -z "$APP8_FP" ]; then
    APP8_FP="$APP8_ONE"
  elif [ "$APP8_ONE" != "$APP8_FP" ]; then
    APP8_ERR="$APP8_ERR ${f#$APP_PROD/}=身份不一致('$APP8_ONE' ≠ '$APP8_FP');"
  fi
done < <(find "$APP_PROD" -type f -perm +111 2>/dev/null)
# 下限守卫:`.app` 里至少有 aahost / aa / mihomo 三个 Mach-O。数不够 = 枚举本身坏了(find 失败、落点变了),
#   此时「没发现不一致」毫无意义 —— 照本仓库口径显式 FAIL,绝不算过。
if [ "$APP8_N" -lt 3 ]; then
  echo "FAIL: .app 内枚举到的 Mach-O 只有 $APP8_N 个(期望 ≥3:aahost / aa / mihomo)—— 枚举失效,无法核验签名一致性,绝不算过"
  FAIL=$((FAIL+1))
elif [ -z "$APP8_ERR" ]; then
  echo "PASS: .app 内 $APP8_N 个 Mach-O 全部已签名且签名身份一致($APP8_FP)——「一致」在 ad-hoc 下的含义是「无未签名者、无用别的身份签的」,**不含证书背书**(ad-hoc 无证书);换真证书后本条会比到 Authority= 叶子(判据已同时认得两种输出形态)。已查:$APP8_LIST"
  PASS=$((PASS+1))
else
  echo "FAIL: .app 内 Mach-O 签名不齐或身份不一致(共 $APP8_N 个):$APP8_ERR"; FAIL=$((FAIL+1))
fi

# ---- e2e 档:真起一次宿主,验全链 ------------------------------------------------
AA_SWIFT="$SWIFT_BIN" bash "$ROOT/Scripts/build-app.sh" \
  --variant e2e --output "$APP_OUT_E2E" >>"$APP_BUILD_LOG" 2>&1
APP_E2E_RC=$?

APP_E2E_APP="$APP_OUT_E2E/AA.app"
APP_E2E_AA="$APP_E2E_APP/Contents/MacOS/aa"
APP_E2E_CTRL_PORT=39094          # 与 mihomo-real-e2e.sh 的 39090/39092 错开,避免同轮门禁抢端口
APP_E2E_NET="$BUILD/app-e2e-netfake.json"
# 文件后端假 NetworkConfigPort:本组不调用 proxy.system.enable/disable,理论上碰不到它;
#   仍然显式指向临时文件是**纵深防御** —— 万一将来有人在启动路径上加了读写系统代理的逻辑,
#   有这条 env 在,它也只会落到假件上,绝不会去动用户真实的 networksetup 设置。
printf '%s\n' '{"services":[]}' > "$APP_E2E_NET"

if [ "$APP_E2E_RC" -ne 0 ]; then
  # e2e 档构建都没成,后面五条(APP4/5/6 + 15 票的 APP9/APP10)都没法核验 —— 各记 1 条 FAIL,保持本组恒为 10 条。
  echo "FAIL: build-app.sh --variant e2e 退出码=$APP_E2E_RC —— 以下五条无法核验"; FAIL=$((FAIL+1))
  tail -20 "$APP_BUILD_LOG" 2>/dev/null | sed 's/^/    /'
  echo "FAIL: 无 e2e 档 .app,无法核验「mihomo 从 .app 内资源被拉起」"; FAIL=$((FAIL+1))
  echo "FAIL: 无 e2e 档 .app,无法核验「install-cli 指向 .app 内的 aa 且全链可用」"; FAIL=$((FAIL+1))
  echo "FAIL: 无 e2e 档 .app,无法核验「aa proxy license 报出的内核版本与 MIHOMO-VERSION.txt 一致」"; FAIL=$((FAIL+1))
  echo "FAIL: 无 e2e 档 .app,无法核验「子进程红线原文经 proxy.license 能力面暴露」"; FAIL=$((FAIL+1))
else
  teardown_hosts also-stub
  AA_MIHOMO_CONTROL_PORT="$APP_E2E_CTRL_PORT" \
  AA_MIHOMO_DATA_DIR="$BUILD/app-e2e-mihomo-data" \
  AA_TAKEOVER_STATE_PATH="$BUILD/app-e2e-takeover.json" \
  AA_SUBSCRIPTION_DIR="$BUILD/app-e2e-subs" \
  AA_NETWORKSETUP_FAKE_STATE="$APP_E2E_NET" \
  "$APP_E2E_HOST_BIN" >"$HOSTLOG" 2>&1 &
  APP_HOST_PID=$!

  if wait_host_ready "$APP_HOST_PID"; then
    # 就绪判据用 apiReachable(不是 running)—— running 在内核被 spawn 的那一刻就为真,
    #   而版本号要等 mihomo 的 REST 起来才读得到(与 mihomo-real-e2e.sh 同一条已知竞态)。
    # 用 herestring 而不是 `printf | grep`:pipefail 下,grep 命中后提前退出会让 printf 收到 SIGPIPE,
    #   整条管道的退出码变成 141,`&& break` 就永远不触发(与 test-support.sh 的 assert_contains 同一个坑)。
    APP_STATUS=""
    for _ in $(seq 1 300); do
      APP_STATUS="$("$APP_E2E_AA" proxy status --json 2>/dev/null)"
      grep -qF '"apiReachable":true' <<<"$APP_STATUS" && break
      sleep 0.1
    done

    "$APP_E2E_AA" capabilities list >/dev/null 2>&1; APP_CAP_RC=$?

    # (APP5) mihomo 从 `.app` **内**资源被拉起。
    #   两个判据一起看,缺一不可:
    #     ① `aa proxy status --json` 报出锁版内核版本号($MIHOMO_VERSION,来自 MIHOMO-VERSION.txt)—— 证明内核真跑起来了、REST 通了;
    #     ② 内核进程的 argv 绝对路径落在 `.app` 里 —— 证明用的是 `.app` 自带那份,
    #        而不是 SwiftPM 生成的 `resource_bundle_accessor.swift` 里那条**硬编码构建目录**回退。
    #   只验 ① 会被那条回退悄悄放过(构建目录在本机是存在的),那就成了白送的 PASS。
    #   这条同时是 `Bundle.module` 落点实测结论的**运行时证明**(见 Scripts/build-app.sh 顶部)。
    APP_KERNEL_PS="$(pgrep -f "$APP_E2E_KERNEL" 2>/dev/null; true)"
    if grep -qF "$MIHOMO_VERSION" <<<"$APP_STATUS" && [ -n "$APP_KERNEL_PS" ]; then
      echo "PASS: mihomo 从 .app 内资源被拉起(status 报锁版 $MIHOMO_VERSION,且内核进程 argv 落在 .app 内:$APP_E2E_KERNEL)"
      PASS=$((PASS+1))
    else
      echo "FAIL: 内核未从 .app 内资源拉起(status='$APP_STATUS';.app 内内核进程: '${APP_KERNEL_PS:-无}')"
      FAIL=$((FAIL+1))
    fi

    # (APP6) `aa install-cli` 指向 `.app` 内那个 aa,且经该符号链接调用能连上宿主。
    #   `--prefix` 指到 $BUILD 下的临时目录 —— **绝不碰真实 /usr/local/bin**(沿用 05 票既有口径)。
    APP_IP="$BUILD/app-install-prefix"; rm -rf "$APP_IP"; mkdir -p "$APP_IP"
    "$APP_E2E_AA" install-cli --prefix "$APP_IP" >/dev/null 2>&1; APP_INST_RC=$?
    # canonical 化两边再比(/tmp 之类的路径本身可能是符号链接;05 票 hard bug2 同一口径)。
    APP_LINK_REAL="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$APP_IP/aa" 2>/dev/null)"
    APP_AA_REAL="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$APP_E2E_AA" 2>/dev/null)"
    "$APP_IP/aa" capabilities list >/dev/null 2>&1; APP_LINK_CALL_RC=$?
    if [ "$APP_INST_RC" -eq 0 ] && [ -L "$APP_IP/aa" ] && [ -n "$APP_LINK_REAL" ] \
       && [ "$APP_LINK_REAL" = "$APP_AA_REAL" ] && [ "$APP_LINK_CALL_RC" -eq 0 ]; then
      echo "PASS: install-cli 建的符号链接指向 .app 内的 aa($APP_LINK_REAL),且经该链接调用能连上宿主"
      PASS=$((PASS+1))
    else
      echo "FAIL: install-cli 全链断言不成立(rc=$APP_INST_RC;链接→'$APP_LINK_REAL' 期望 '$APP_AA_REAL';经链接调用 rc=$APP_LINK_CALL_RC)"
      FAIL=$((FAIL+1))
    fi

    # ---- 15 票的两条:复用**同一个**已就绪的 e2e 宿主(不另起,省几秒 + 不多一份残留风险)----
    # `proxy.license` 是纯静态资源信息能力,不依赖内核在跑 —— 所以下面两条即便上面 apiReachable 轮询超时也能成立,
    #   刻意不放进任何「内核就绪」的条件分支里。
    APP_LIC="$("$APP_E2E_AA" proxy license --json 2>/dev/null)"; APP_LIC_RC=$?

    # (APP9,15 票) **版本号单一来源的运行时证明**:经 UDS 走注册表拿到的 kernelVersion,
    #   与 bootstrap.sh 从 `Sources/PluginProxy/Resources/MIHOMO-VERSION.txt` 解析出的 $MIHOMO_VERSION 一致。
    #   两侧此刻是两条独立路径:Swift 侧 `MihomoKernelResource.version` 常量 vs shell 侧解析那个 txt。
    #   它们漂开的表现极其阴险 —— 打包的是新内核、关于页却写着旧版本号(GPL 义务里「所用内核版本」直接失真)。
    #   本条把「同源」从注释里的约定变成每轮门禁都真跑一次的核验。
    #   期望值带 `v` 前缀:txt 首行是 `Mihomo Meta v1.19.28 …`,bootstrap 的正则**剥掉了 v** 取 `1.19.28`,
    #   而 Swift 常量按上游 tag 原样写作 `v1.19.28`。这里显式拼回 `v`,比用子串包含更严(子串会把
    #   `1.19.280` 之类也算过)。
    if [ "$APP_LIC_RC" -eq 0 ] && grep -qF "\"kernelVersion\":\"v$MIHOMO_VERSION\"" <<<"$APP_LIC"; then
      echo "PASS: aa proxy license --json 经 UDS 走注册表报出 kernelVersion=v$MIHOMO_VERSION,与 MIHOMO-VERSION.txt 解析值一致(版本号单一来源的运行时证明)"
      PASS=$((PASS+1))
    else
      echo "FAIL: proxy.license 的 kernelVersion 与 MIHOMO-VERSION.txt 不一致或调用失败(rc=$APP_LIC_RC;期望含 \"kernelVersion\":\"v$MIHOMO_VERSION\";实际输出: ${APP_LIC:-无})"
      FAIL=$((FAIL+1))
    fi

    # (APP10,15 票) 子进程红线原文**真的经能力面暴露**,而不是只写在注释/文档里。
    #   为什么要单独一条:关于页的红线文案是经 `proxy.license` 取的(GUI 薄壳、无私有逻辑),
    #   所以「能力输出里有这句话」就是「关于页会显示这句话」的机读证明 —— headless 门禁验得到的最强的那一环。
    #   判据取 ADR 0007 的两个要害词(仅子进程 / 永不进程内链接),不整句比:整句比会让每次措辞微调都红,
    #   而这条要守的是**语义没被削弱**,不是逐字不动。
    if [ "$APP_LIC_RC" -eq 0 ] \
       && grep -qF '"subprocessBoundary":"' <<<"$APP_LIC" \
       && grep -qF '永不进程内链接' <<<"$APP_LIC" \
       && grep -qF '独立子进程' <<<"$APP_LIC"; then
      echo "PASS: 子进程红线原文经 proxy.license 能力面暴露(含「独立子进程」与「永不进程内链接」两个要害词;关于页的同一份文案即由此取得)"
      PASS=$((PASS+1))
    else
      echo "FAIL: proxy.license 输出里找不到完整的子进程红线原文(rc=$APP_LIC_RC;实际输出: ${APP_LIC:-无})"
      FAIL=$((FAIL+1))
    fi

    # 优雅退出(SIGUSR1 走 applicationWillTerminate → 回收内核 → terminate 完整路径)。
    kill -USR1 "$APP_HOST_PID" 2>/dev/null
    for _ in $(seq 1 150); do kill -0 "$APP_HOST_PID" 2>/dev/null || break; sleep 0.1; done
    APP_QUIT_OK=1
    if kill -0 "$APP_HOST_PID" 2>/dev/null; then APP_QUIT_OK=0; kill -TERM "$APP_HOST_PID" 2>/dev/null; fi
    sleep 0.5
    # 残留:宿主本体 + 它拉起的内核。两个都盯**绝对路径** —— 绝不能 pkill/pgrep 裸 "mihomo",
    #   用户机上可能正跑着自己的 mihomo(本票实测时就撞见过 /usr/local/bin/mihomo)。
    APP_RES_HOST="$(pgrep -f "$APP_E2E_HOST_BIN" 2>/dev/null; true)"
    APP_RES_KERNEL="$(pgrep -f "$APP_E2E_KERNEL" 2>/dev/null; true)"

    # (APP4) e2e 档 `.app` 全链可跑:UDS 就绪 + capabilities list 成功 + 优雅退出 + 无残留(宿主与内核都不留)。
    #   编号按票面口径仍是第 4 条,但**输出位置**排在 APP5/APP6 之后 —— 它的判词要等「优雅退出 + 残留核验」
    #   才给得出,而那两步必须在 APP5/APP6 用完宿主之后做。恰好 1 条 PASS/FAIL,与顺序无关。
    if [ "$APP_CAP_RC" -eq 0 ] && [ "$APP_QUIT_OK" -eq 1 ] && [ -z "$APP_RES_HOST" ] && [ -z "$APP_RES_KERNEL" ]; then
      echo "PASS: e2e 档 .app 全链可跑(直接 exec Contents/MacOS/aahost → UDS 就绪 → aa capabilities list 成功 → SIGUSR1 优雅退出 → 宿主与内核均无残留)"
      PASS=$((PASS+1))
    else
      echo "FAIL: e2e 档 .app 全链断言不成立(capabilities list rc=$APP_CAP_RC;优雅退出=$APP_QUIT_OK;残留宿主='${APP_RES_HOST:-无}';残留内核='${APP_RES_KERNEL:-无}')"
      FAIL=$((FAIL+1))
      sed 's/^/    /' "$HOSTLOG" 2>/dev/null | tail -20
    fi
  else
    # 宿主没起来:APP4/5/6 + APP9/APP10 一条都核验不了 —— 各记 1 条 FAIL(wait_host_ready 已 dump 过宿主日志)。
    echo "FAIL: e2e 档 .app 宿主未就绪 —— 全链无法核验"; FAIL=$((FAIL+1))
    echo "FAIL: e2e 档 .app 宿主未就绪 —— 无法核验「mihomo 从 .app 内资源被拉起」"; FAIL=$((FAIL+1))
    echo "FAIL: e2e 档 .app 宿主未就绪 —— 无法核验「install-cli 指向 .app 内的 aa」"; FAIL=$((FAIL+1))
    echo "FAIL: e2e 档 .app 宿主未就绪 —— 无法核验「proxy.license 的 kernelVersion 与 MIHOMO-VERSION.txt 一致」"; FAIL=$((FAIL+1))
    echo "FAIL: e2e 档 .app 宿主未就绪 —— 无法核验「子进程红线原文经 proxy.license 能力面暴露」"; FAIL=$((FAIL+1))
  fi
  # 无论哪条分支都彻底收场,别把宿主/内核留给后面的断言组(mihomo-real-e2e 紧随其后,会争同一个 socket)。
  # **要等真死,不能 pkill 完就走**:pkill 只是把信号递出去,进程收尸有延迟。不等的话,
  #   极端情况下残宿主会漂进下一组、争抢同一个 socket,把下一组变成难查的偶发红
  #   (这正是 09 票踩过的那种时序 flaky)。teardown_hosts 里已有同款轮询,这里对齐它。
  pkill -f "$APP_E2E_HOST_BIN" 2>/dev/null
  pkill -f "$APP_E2E_KERNEL" 2>/dev/null
  for _ in $(seq 1 100); do
    if ! pgrep -f "$APP_E2E_HOST_BIN" >/dev/null 2>&1 && ! pgrep -f "$APP_E2E_KERNEL" >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
  rm -f "$SOCK"
fi
