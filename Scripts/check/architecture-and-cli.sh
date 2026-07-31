# --- 断言组 3:PluginProxy 不依赖任何 Host*(01 票铁律,继续把关)---
echo "--- 断言组 3:PluginProxy 不依赖任何 Host* ---"
# (3a) 源码级 grep 守卫:PluginProxy 源码不得 import 任何 Host* 模块。
# 正则放宽以覆盖子句形 import(如 `import struct AAHostRuntime.Foo`),不止裸 `import AAHostRuntime`。
# 显式判 grep 退出码,杜绝假绿:rc==1 无匹配(好)/ rc==0 命中禁止 import(坏)/ rc>=2 grep 自身出错(无法核验,绝不算过)。
GREP_HITS="$(grep -REn 'import[[:space:]]+([a-z]+[[:space:]]+)?AAHost(Runtime|MacOS|TestKit)' Sources/PluginProxy/)"
GREP_RC=$?
if [ "$GREP_RC" -eq 1 ]; then
  echo "PASS: PluginProxy 源码不含 import Host*(AAHostRuntime|AAHostMacOS|AAHostTestKit)"; PASS=$((PASS+1))
elif [ "$GREP_RC" -eq 0 ]; then
  echo "FAIL: PluginProxy 源码出现 Host* 的 import:"; printf '%s\n' "$GREP_HITS"; FAIL=$((FAIL+1))
else
  echo "FAIL: grep 守卫自身出错(rc=$GREP_RC),无法核验 PluginProxy 边界 —— 绝不算过"; FAIL=$((FAIL+1))
fi
# (3b) 编译期守卫:上面阶段 A 已用「仅 SDK/Contracts/UISystem 的 -I」编过 PluginProxy,能到这里即已证明。
echo "PASS: PluginProxy 已在受限 -I(无 Host* 模块)下编译成功 —— 编译期证明不需要 Host*"
PASS=$((PASS+1))

# (3c) 06 票 Port 落点核验:ProcessPort/HTTPPort **协议**必须声明在 AAPluginSDK(插件只依赖 SDK),Host* 侧只能是实现/假件。
PORT_DECL_SDK="$(grep -REn 'protocol[[:space:]]+(ProcessPort|HTTPPort)' Sources/AAPluginSDK/)"
if [ -n "$PORT_DECL_SDK" ]; then
  echo "PASS: ProcessPort/HTTPPort 协议声明在 AAPluginSDK(插件只依赖 SDK 即可用)"; PASS=$((PASS+1))
else
  echo "FAIL: 未在 AAPluginSDK 找到 ProcessPort/HTTPPort 协议声明"; FAIL=$((FAIL+1))
fi
PORT_DECL_HOST="$(grep -REn 'protocol[[:space:]]+(ProcessPort|HTTPPort)' Sources/AAHostMacOS/ Sources/AAHostRuntime/ Sources/AAHostTestKit/)"
GREP_PORT_RC=$?
if [ "$GREP_PORT_RC" -eq 1 ] && [ -z "$PORT_DECL_HOST" ]; then
  echo "PASS: Host* 侧不声明 Port 协议(只提供真实现/假件),边界正确"; PASS=$((PASS+1))
else
  echo "FAIL: Port 协议不应声明在 Host*(命中: $PORT_DECL_HOST)"; FAIL=$((FAIL+1))
fi

# (3d) 08 票新增 Port 落点核验:TakeoverStateStore/ProcessReaper **协议**必须声明在 AAPluginSDK(插件只依赖 SDK),Host* 侧只能是实现/假件。
NEWPORT_DECL_SDK="$(grep -REn 'protocol[[:space:]]+(TakeoverStateStore|ProcessReaper)' Sources/AAPluginSDK/)"
if [ -n "$NEWPORT_DECL_SDK" ]; then
  echo "PASS: TakeoverStateStore/ProcessReaper 协议声明在 AAPluginSDK(08 新 Port 亦在 SDK,插件不依赖 Host*)"; PASS=$((PASS+1))
else
  echo "FAIL: 未在 AAPluginSDK 找到 TakeoverStateStore/ProcessReaper 协议声明"; FAIL=$((FAIL+1))
fi
NEWPORT_DECL_HOST="$(grep -REn 'protocol[[:space:]]+(TakeoverStateStore|ProcessReaper)' Sources/AAHostMacOS/ Sources/AAHostRuntime/ Sources/AAHostTestKit/)"
NEWPORT_RC=$?
if [ "$NEWPORT_RC" -eq 1 ] && [ -z "$NEWPORT_DECL_HOST" ]; then
  echo "PASS: Host* 侧不声明 08 新 Port 协议(只提供文件后端/假件),边界正确"; PASS=$((PASS+1))
else
  echo "FAIL: 08 新 Port 协议不应声明在 Host*(命中: $NEWPORT_DECL_HOST)"; FAIL=$((FAIL+1))
fi

# (3e) 10 票新增 Port 落点核验:SubscriptionStore/SubscriptionSourcePort **协议**必须声明在 AAPluginSDK,Host* 侧只能是真实现/假件。
SUBPORT_DECL_SDK="$(grep -REn 'protocol[[:space:]]+(SubscriptionStore|SubscriptionSourcePort)' Sources/AAPluginSDK/)"
if [ -n "$SUBPORT_DECL_SDK" ]; then
  echo "PASS: SubscriptionStore/SubscriptionSourcePort 协议声明在 AAPluginSDK(10 新 Port 亦在 SDK,插件不依赖 Host*)"; PASS=$((PASS+1))
else
  echo "FAIL: 未在 AAPluginSDK 找到 SubscriptionStore/SubscriptionSourcePort 协议声明"; FAIL=$((FAIL+1))
fi
SUBPORT_DECL_HOST="$(grep -REn 'protocol[[:space:]]+(SubscriptionStore|SubscriptionSourcePort)' Sources/AAHostMacOS/ Sources/AAHostRuntime/ Sources/AAHostTestKit/)"
SUBPORT_RC=$?
if [ "$SUBPORT_RC" -eq 1 ] && [ -z "$SUBPORT_DECL_HOST" ]; then
  echo "PASS: Host* 侧不声明 10 新 Port 协议(只提供文件后端/真网络/假件),边界正确"; PASS=$((PASS+1))
else
  echo "FAIL: 10 新 Port 协议不应声明在 Host*(命中: $SUBPORT_DECL_HOST)"; FAIL=$((FAIL+1))
fi

# --- 断言组 4:退出码语义表落进 CLI 帮助(逐码断言;补足 2/denied 无行为路径的那一码)---
echo "--- 断言组 4:aa --help 退出码语义表(逐码)---"
HELP="$("$BIN/aa" --help 2>&1)"; RC=$?
assert_exit 0 $RC "aa --help 退出码=0"
assert_contains "$HELP" "0  成功" "帮助含退出码 0=成功"
assert_contains "$HELP" "1  用法错" "帮助含退出码 1=用法错"
assert_contains "$HELP" "2  denied" "帮助含退出码 2=denied(04 票)"
assert_contains "$HELP" "3  超时" "帮助含退出码 3=超时"
assert_contains "$HELP" "4  宿主不可达" "帮助含退出码 4=宿主不可达"
assert_contains "$HELP" "5  能力业务失败" "帮助含退出码 5=能力业务失败"
assert_contains "$HELP" "6  协议/校验错" "帮助含退出码 6=协议/校验错"

# --- 断言组 5:aa docs agents-md 接入片段(05 票;纯文档,无需宿主)---
echo "--- 断言组 5:aa docs agents-md 接入片段(05 票)---"
DOCS="$("$BIN/aa" docs agents-md 2>/dev/null)"; RC=$?
assert_exit 0 $RC "aa docs agents-md 退出码=0"
assert_contains "$DOCS" "prefix_rule" "docs 含 Codex prefix_rule 信任配置示例(S3 沙箱姿态)"
assert_contains "$DOCS" "require_escalated" "docs 含 require_escalated(沙箱外执行的提权声明)"
assert_contains "$DOCS" "capabilities call" "docs 含发现/调用命令(capabilities call/list/describe)"
assert_contains "$DOCS" "When to use" "docs 含「何时用本 CLI」段"
assert_contains "$DOCS" "dangerous" "docs 含 dangerous 语义说明"
assert_contains "$DOCS" "exit code" "docs 含退出码语义(exit code 契约)"

# --- 断言组 6:aa install-cli 幂等/覆盖(05 票;临时目录,绝不碰真实 /usr/local/bin)---
echo "--- 断言组 6:aa install-cli 幂等/覆盖(05 票,临时目录)---"
IP1="$BUILD/install-prefix1"; mkdir -p "$IP1"
"$BIN/aa" install-cli --prefix "$IP1" >/dev/null 2>&1; RC=$?
assert_exit 0 $RC "install-cli 首次 --prefix 退出码=0"
if [ -L "$IP1/aa" ]; then
  echo "PASS: install-cli 建了符号链接 $IP1/aa"; PASS=$((PASS+1))
else
  echo "FAIL: install-cli 未建符号链接 $IP1/aa"; FAIL=$((FAIL+1))
fi
"$IP1/aa" --help >/dev/null 2>&1; RC=$?
assert_exit 0 $RC "经符号链接调用 aa --help 成功(链接指向可用的真 aa)"
IOUT="$("$BIN/aa" install-cli --prefix "$IP1" --json 2>/dev/null)"; RC=$?
assert_exit 0 $RC "install-cli 幂等重跑退出码=0"
assert_contains "$IOUT" "already-installed" "install-cli 幂等重跑报告 already-installed(no-op)"
# 指向别处 → 无 --force 报错;--force 覆盖成功
IP2="$BUILD/install-prefix2"; mkdir -p "$IP2"; ln -s /bin/ls "$IP2/aa"
"$BIN/aa" install-cli --prefix "$IP2" >/dev/null 2>&1; RC=$?
assert_exit 1 $RC "install-cli 目标指向别处且无 --force → 退出码=1(明确报告)"
"$BIN/aa" install-cli --prefix "$IP2" --force >/dev/null 2>&1; RC=$?
assert_exit 0 $RC "install-cli --force 覆盖成功 退出码=0"
"$IP2/aa" --help >/dev/null 2>&1; RC=$?
assert_exit 0 $RC "--force 覆盖后符号链接指向真 aa(卸载/覆盖行为明确)"
# 目标目录不存在 → 明确错误(退出码 1)
"$BIN/aa" install-cli --prefix "$BUILD/no-such-dir" >/dev/null 2>&1; RC=$?
assert_exit 1 $RC "install-cli 目标目录不存在 → 退出码=1(明确错误)"

# (hard bug2 修复)canonical 化比较:相对符号链接指向同一 aa → 判 already-installed(不逼 --force)。
#   $BIN=$BUILD/bin;从 $IPCANON 用相对路径 ../bin/aa 指向同一真 aa,字面≠已 canonical 的 source,但解析后应相等。
IPCANON="$BUILD/install-canon"; mkdir -p "$IPCANON"
( cd "$IPCANON" && ln -s "../bin/aa" "aa" )
CANOUT="$("$BIN/aa" install-cli --prefix "$IPCANON" --json 2>/dev/null)"; RC=$?
echo "    相对链接 install 输出: $CANOUT"
assert_exit 0 $RC "install-cli 相对链接指向同一 aa → 退出码=0(canonical 化)"
assert_contains "$CANOUT" "already-installed" "install-cli canonical 化后相对链接判 already-installed(hard bug2 修复:不误判指向别处)"

# --- --uninstall 幂等 + 拒误删(仍只用临时 prefix)---
IPUN="$BUILD/install-uninst"; mkdir -p "$IPUN"
"$BIN/aa" install-cli --prefix "$IPUN" >/dev/null 2>&1; RC=$?
assert_exit 0 $RC "install-cli(--uninstall 前置)安装退出码=0"
UOUT="$("$BIN/aa" install-cli --uninstall --prefix "$IPUN" --json 2>/dev/null)"; RC=$?
assert_exit 0 $RC "install-cli --uninstall 退出码=0"
assert_contains "$UOUT" "uninstalled" "--uninstall 删除本 aa 链接(action=uninstalled)"
if [ -e "$IPUN/aa" ]; then echo "FAIL: --uninstall 后链接仍在"; FAIL=$((FAIL+1)); else echo "PASS: --uninstall 后链接已删除"; PASS=$((PASS+1)); fi
UOUT2="$("$BIN/aa" install-cli --uninstall --prefix "$IPUN" --json 2>/dev/null)"; RC=$?
assert_exit 0 $RC "install-cli --uninstall 幂等重跑(目标不存在)退出码=0"
assert_contains "$UOUT2" "not-installed" "--uninstall 幂等 no-op(action=not-installed)"
# 拒误删:指向别处的链接(非本 aa)→ 退出码 1 且不删
IPFOREIGN="$BUILD/install-foreign"; mkdir -p "$IPFOREIGN"; ln -s /bin/ls "$IPFOREIGN/aa"
"$BIN/aa" install-cli --uninstall --prefix "$IPFOREIGN" >/dev/null 2>&1; RC=$?
assert_exit 1 $RC "install-cli --uninstall 拒删非本 aa 链接 → 退出码=1"
if [ -L "$IPFOREIGN/aa" ]; then echo "PASS: --uninstall 未误删指向别处的链接(不误删非自己建的)"; PASS=$((PASS+1)); else echo "FAIL: --uninstall 误删了别处链接"; FAIL=$((FAIL+1)); fi
