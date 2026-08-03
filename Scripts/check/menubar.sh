# --- 断言组 MB:菜单栏轻壳 + 手搓快照(14 票;5 条)---
#
# 本组守四件事,对应 14 票的四条验收:
#   MB1 菜单模型覆盖 04 票 In 清单的**全部**用户操作,且每一项都追溯得到**真实存在**的能力 id;
#   MB2 状态变化(内核死活 / 模式 / 节点 / 激活订阅)在模型里如实反映;
#   MB3 快照产物在固定路径生成、是有效 PNG 且尺寸符合预期;
#   MB4 快照与入库 golden 的像素 diff 在容差内(并且模型文本 golden 逐字节一致);
#   MB5 dangerous(proxy.subscription.add)**从菜单路径**发起仍触发宿主确认,deny 挡得住。
#
# ============================================================================
# 为什么 MB1/MB2 的判据在 Swift 侧、shell 这里只 grep 一行结论
# ============================================================================
# MB1 要拿**注册表的实际清单**去交叉核对菜单模型 —— 那是个 Swift 对象,shell 拿不到。
#   若在 shell 里 grep 一份自己写死的能力 id 名单,那就是「抄一份名单跟自己比」,证明力为零。
#   故判据全在 `Sources/AAHostTestKit/MenuModelConformanceTests.swift`(33 条 check,计入 runner 的
#   failed 计数与退出码),那边把结论汇成一行 `MENUBAR_ASSERT1: ok=1 …`,shell 只认这一行。
#   MB2 同理(要喂三种状态、比三份模型)。
# 这样每条门禁断言恰好记 1 次 PASS/FAIL,而背后的诊断信息一条不少(runner 输出已在断言组 1 全量打印)。
#
# $UNIT_OUT 是断言组 1 里 registry-tests 输出的别名(见 unit-and-domain.sh)——
#   不重跑 runner,省十几秒 + 少一次真进程套件。
#
# ============================================================================
# 快照的证明力边界(**别把 MB3/MB4 的绿读成「菜单在屏幕上长这样」**)
# ============================================================================
# 快照走的是**渲染器 B**(`AAMenuModel → 自绘 NSView → PNG`),与状态栏上那个真 NSMenu 是
#   **同一个模型的两种呈现**。它证明模型没回归、也证明两个渲染器共享同一份数据;
#   它**证明不了** AppKit 把真 NSMenu 画成什么样(行高/字体/分隔线/子菜单弹出/深色模式全在系统绘制里)。
#   「菜单在屏幕上真的长这样」只能人眼确认。完整口径见 `Sources/AAHostMacOS/MenuSnapshotRenderer.swift` 头部。
echo "--- 断言组 MB:菜单栏轻壳 + 手搓快照(14 票)---"

MB_SNAP_DIR="$BUILD/snapshots"
MB_GOLDEN_DIR="$ROOT/Snapshots/menubar"
MB_TOOL="$BIN/menu-snapshot"
MB_LOG="$BUILD/menu-snapshot.log"

# 跑快照工具:渲染三种状态 → 落 $BUILD/snapshots/ → 与入库 golden 比对。
#   **绝不传 AA_SNAPSHOT_RECORD** —— 门禁自己录 golden 等于让断言永远为真。录制是人手动的事。
if [ -x "$MB_TOOL" ]; then
  AA_SNAPSHOT_OUT_DIR="$MB_SNAP_DIR" AA_SNAPSHOT_GOLDEN_DIR="$MB_GOLDEN_DIR" \
    "$MB_TOOL" >"$MB_LOG" 2>&1
  MB_TOOL_RC=$?
else
  MB_TOOL_RC=127
  printf '%s\n' "menu-snapshot 可执行缺失或不可执行: $MB_TOOL" >"$MB_LOG"
fi
sed 's/^/    /' "$MB_LOG" 2>/dev/null

# 产物绝对路径打给人看 —— 本票的一条明确要求:**不读 Swift 的人也能行使监督**,他要能直接打开这几张图。
echo "    [人眼抽查] 快照产物目录: $MB_SNAP_DIR"
echo "    [人眼抽查] golden 目录  : $MB_GOLDEN_DIR(说明见 $ROOT/Snapshots/README.md)"

# (MB1) 覆盖面 + 可追溯性。
assert_contains "$UNIT_OUT" "MENUBAR_ASSERT1: ok=1" \
  "14 菜单模型覆盖 04 票 In 清单的全部用户操作,且每项都追溯到真注册表里真实存在的能力 id(判据在 MenuModelConformanceTests,含反向核对:注册表里每条 normal/dangerous 的 proxy 能力都在菜单里露出)"

# (MB2) 状态如实反映。
assert_contains "$UNIT_OUT" "MENUBAR_ASSERT2: ok=1" \
  "14 状态变化在菜单模型里如实反映(内核死 / 内核活+rule 模式+节点 / 有激活订阅 三态,且三态两两不同——排除模型恒定的假绿)"

# (MB3) 快照产物在固定路径生成、是有效 PNG、尺寸符合预期。
#   期望尺寸不在 shell 里写死(写死就成了两处知识、迟早漂):由工具按模型算出并打成 SNAPSHOT_EXPECT 行,
#   shell 这边**独立地**去解 PNG 文件自己的 IHDR 头来比 —— 一边是模型算的,一边是文件里真写着的,才叫核验。
mb_png_dim() {  # $1 = PNG 路径;打印 "宽 高";非 PNG / 读不到 → 什么都不打印
  python3 - "$1" <<'PY' 2>/dev/null
import sys, struct
try:
    with open(sys.argv[1], 'rb') as f:
        head = f.read(24)
except OSError:
    sys.exit(0)
if len(head) < 24 or head[:8] != b'\x89PNG\r\n\x1a\n' or head[12:16] != b'IHDR':
    sys.exit(0)
w, h = struct.unpack('>II', head[16:24])
print(w, h)
PY
}

MB3_ERR=""; MB3_N=0; MB3_LIST=""
while IFS= read -r line; do
  MB3_NAME="$(sed -n 's/.*name=\([^ ]*\).*/\1/p' <<<"$line")"
  MB3_W="$(sed -n 's/.* w=\([0-9]*\).*/\1/p' <<<"$line")"
  MB3_H="$(sed -n 's/.* h=\([0-9]*\).*/\1/p' <<<"$line")"
  [ -z "$MB3_NAME" ] && { MB3_ERR="$MB3_ERR 解析不出 name 的 EXPECT 行:$line;"; continue; }
  MB3_N=$((MB3_N+1))
  MB3_FILE="$MB_SNAP_DIR/$MB3_NAME.png"
  if [ ! -s "$MB3_FILE" ]; then
    MB3_ERR="$MB3_ERR $MB3_NAME.png 不存在或为空;"; continue
  fi
  MB3_DIM="$(mb_png_dim "$MB3_FILE")"
  if [ -z "$MB3_DIM" ]; then
    MB3_ERR="$MB3_ERR $MB3_NAME.png 不是有效 PNG(magic/IHDR 读不出);"; continue
  fi
  if [ "$MB3_DIM" != "$MB3_W $MB3_H" ]; then
    MB3_ERR="$MB3_ERR $MB3_NAME.png 尺寸=[$MB3_DIM] 与模型算出的期望=[$MB3_W $MB3_H] 不符;"; continue
  fi
  MB3_LIST="$MB3_LIST $MB3_NAME(${MB3_W}×${MB3_H})"
done < <(grep '^SNAPSHOT_EXPECT: ' "$MB_LOG" 2>/dev/null; true)
# 下限守卫:少于 3 张 = 枚举本身坏了(工具没跑起来 / 输出格式变了)。此时「没发现不一致」毫无意义,
#   照本仓库口径显式 FAIL,绝不算过(与 app-bundle.sh 的 APP8 同一条纪律)。
if [ "$MB3_N" -lt 3 ]; then
  echo "FAIL: 快照产物只枚举到 $MB3_N 张(期望 ≥3:内核未运行 / 内核运行中 / 有激活订阅)—— 枚举失效,无法核验产物,绝不算过(menu-snapshot rc=$MB_TOOL_RC,日志: $MB_LOG)"
  FAIL=$((FAIL+1))
elif [ -z "$MB3_ERR" ]; then
  echo "PASS: 快照产物在固定路径生成且为有效 PNG、尺寸与模型算出的期望一致($MB3_N 张:$MB3_LIST;目录 $MB_SNAP_DIR)"
  PASS=$((PASS+1))
else
  echo "FAIL: 快照产物核验不通过:$MB3_ERR"; FAIL=$((FAIL+1))
fi

# (MB4) 与 golden 的像素 diff 在容差内 + 模型文本 golden 逐字节一致。
#   两个判据合在一条:像素是主判据,文本是「差在哪一行」的可读凭证 ——
#   也是万一将来证明像素会抖时的降级落点(降级要在票面写明,不许靠调大阈值蒙混)。
#   容差取值与理由写在 Sources/menu-snapshot/MenuSnapshotMain.swift(单通道 ≤2/255,超容差像素允许 0 个)。
MB4_GOLDEN_N="$(ls -1 "$MB_GOLDEN_DIR"/*.png 2>/dev/null | wc -l | tr -d ' ')"
MB4_SUMMARY="$(grep '^SNAPSHOT_SUMMARY: ' "$MB_LOG" 2>/dev/null; true)"
MB4_OK=0
if [ "$MB_TOOL_RC" -eq 0 ] && [ "${MB4_GOLDEN_N:-0}" -ge 3 ] \
   && grep -qF 'goldenMissing=0' <<<"$MB4_SUMMARY" \
   && grep -qF 'decodeFailure=0' <<<"$MB4_SUMMARY" \
   && grep -qF 'overToleranceTotal=0' <<<"$MB4_SUMMARY" \
   && grep -qF 'textMismatch=0' <<<"$MB4_SUMMARY" \
   && grep -qF 'recording=0' <<<"$MB4_SUMMARY" \
   && grep -qF 'ok=1' <<<"$MB4_SUMMARY"; then
  MB4_OK=1
fi
if [ "$MB4_OK" -eq 1 ]; then
  echo "PASS: 快照与入库 golden 的像素 diff 在容差内(超容差像素 0 个)且模型文本 golden 逐字节一致 —— $MB4_SUMMARY"
  PASS=$((PASS+1))
else
  echo "FAIL: 快照与 golden 比对不通过(menu-snapshot rc=$MB_TOOL_RC;入库 golden PNG 数=${MB4_GOLDEN_N:-0},期望 ≥3;结论行: ${MB4_SUMMARY:-无});逐张明细见 $MB_LOG"
  FAIL=$((FAIL+1))
fi

# (MB5) dangerous 从**菜单路径**发起 → 仍走宿主确认 → deny 挡得住。
#
# 这条是「GUI 与 CLI 同源」的运行时证明:菜单项的 action 与 `aa proxy subscription add` 汇到
#   **同一个** `Registry.invoke`,于是同一条 dangerous 路由、同一个 AA_CONFIRM_AUTO=deny 把它挡下。
# 怎么在 headless 下「点菜单」:test-only seam `AA_MENU_CLICK_PROBE=<能力id>` 让宿主启动后
#   经 `NSApp.sendAction` 激活**真 NSMenuItem** 的 action(不是直接调 registry —— 那证明不了菜单接对了线);
#   `AA_MENU_PROMPT_AUTO` 替掉「换源要用户填 name/source」的模态输入框。二者都受 `#if AA_TESTING` 门控。
# ⚠️ 绝不调真 networksetup:AA_NETWORKSETUP_FAKE_STATE 指向 $BUILD 下的文件后端假件(与既有 E2E 同口径)。
teardown_hosts also-stub
MB_E2E_DIR="$BUILD/menubar-e2e"
rm -rf "$MB_E2E_DIR"; mkdir -p "$MB_E2E_DIR"
printf '%s\n' '{"services":[]}' > "$MB_E2E_DIR/netfake.json"
# source 指向一个**根本不存在**的文件:批准分支下它会拉取失败 —— 而本条要验的恰恰是「压根走不到拉取」。
# 若 deny 没挡住,订阅目录会留下痕迹(10 票的 add 会写 config + 清单),下面的「无痕」判据就会红。
MB_E2E_SUBS="$MB_E2E_DIR/subs"
AA_CONFIRM_AUTO=deny \
AA_MENU_CLICK_PROBE=proxy.subscription.add \
AA_MENU_PROMPT_AUTO="{\"name\":\"门禁菜单路径探针\",\"source\":\"file://$MB_E2E_DIR/never-fetched.yaml\"}" \
AA_SUBSCRIPTION_DIR="$MB_E2E_SUBS" \
AA_TAKEOVER_STATE_PATH="$MB_E2E_DIR/takeover.json" \
AA_NETWORKSETUP_FAKE_STATE="$MB_E2E_DIR/netfake.json" \
"$HOST_BIN" >"$HOSTLOG" 2>&1 &
MB_HOST_PID=$!

if wait_host_ready "$MB_HOST_PID"; then
  # 探针是异步的(入 main 队列 → 能力调用又切后台队列),轮询等结论行出现,最多 20s。
  for _ in $(seq 1 200); do
    grep -qF "[menu] 能力调用结果 [proxy.subscription.add]" "$HOSTLOG" 2>/dev/null && break
    sleep 0.1
  done
  MB5_LOG="$(cat "$HOSTLOG" 2>/dev/null; true)"
  # 订阅目录必须**一点痕迹都没留**(不存在,或存在但为空)——deny 分支绝不能执行 handler。
  MB5_RESIDUE="$(ls -A "$MB_E2E_SUBS" 2>/dev/null; true)"
  MB5_ERR=""
  grep -qF "[menu-probe] 激活菜单项" <<<"$MB5_LOG" || MB5_ERR="$MB5_ERR 未激活到菜单项;"
  grep -qF "capabilityID=proxy.subscription.add" <<<"$MB5_LOG" || MB5_ERR="$MB5_ERR 激活的不是 proxy.subscription.add;"
  grep -qF "[confirm] proxy.subscription.add" <<<"$MB5_LOG" || MB5_ERR="$MB5_ERR 未触发宿主确认层;"
  grep -qF "AA_CONFIRM_AUTO=deny → 自动拒绝(test-only,不弹窗)[proxy.subscription.add]" <<<"$MB5_LOG" \
    || MB5_ERR="$MB5_ERR 确认层未走 deny 分支;"
  grep -qF "[menu] 能力调用结果 [proxy.subscription.add]: failed code=denied" <<<"$MB5_LOG" \
    || MB5_ERR="$MB5_ERR 菜单侧未收到 denied 结果;"
  [ -z "$MB5_RESIDUE" ] || MB5_ERR="$MB5_ERR deny 后订阅目录竟有产物($MB5_RESIDUE)——没挡住;"
  if [ -z "$MB5_ERR" ]; then
    echo "PASS: dangerous(proxy.subscription.add)从菜单项的真 target/action 发起,仍经宿主确认路由,AA_CONFIRM_AUTO=deny 当场挡下(code=denied)且订阅目录零产物 —— GUI 与 CLI 同源的运行时证明"
    PASS=$((PASS+1))
  else
    echo "FAIL: dangerous 菜单路径断言不成立:$MB5_ERR"; FAIL=$((FAIL+1))
    sed 's/^/    /' "$HOSTLOG" 2>/dev/null | tail -25
  fi
else
  # 宿主没起来 → 这条核验不了。仍记 1 条 FAIL,保持本组恒为 5 条(wait_host_ready 已 dump 过宿主日志)。
  echo "FAIL: 菜单路径 E2E 宿主未就绪 —— 无法核验「dangerous 从菜单发起仍走宿主确认」"; FAIL=$((FAIL+1))
fi
teardown_hosts
