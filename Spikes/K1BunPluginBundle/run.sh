#!/bin/bash
# K1 —— BUN_BE_BUN 自举 bun install / bun build spike（.scratch/a2-kernel/issues/02）
# PROTOTYPE：抛弃式实验，不进产品代码。产物（约 60MiB 的编译 bin + 临时插件工程）
# 一律落在临时工作目录，绝不落仓库。
#
#   bash Spikes/K1BunPluginBundle/run.sh [workdir]
#
# 环境变量：
#   A2_SPIKE_WORKDIR  工作目录（等价于位置参数；两者都不给就 mktemp -d 开一个）
#   BUN_BIN           系统 bun 路径（默认 ~/.bun/bin/bun）。只用来编译出 spike 的内核 bin；
#                     之后的全部动作都由那个 bin 自己经 BUN_BE_BUN 驱动，不再碰系统 bun。
#   K1_REBUILD=1      强制重编内核 bin（默认已存在就复用）
#
# 目录约定：$WORK/bin/ 放编译产物（跨次运行复用），$WORK/run/ 放本次实验的全部临时工程
# ——每次运行整个 run/ 先删后建，所以这里只需要一条 rm，不必逐个列子目录名。
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"

BUN="${BUN_BIN:-$HOME/.bun/bin/bun}"
WORK="${1:-${A2_SPIKE_WORKDIR:-$(mktemp -d -t a2-k1)}}"
BIN="$WORK/bin/a2-spike-bin"
RUN="$WORK/run"

echo "== K1 spike =="
echo "系统 bun : $BUN ($("$BUN" --version))"
echo "工作目录 : $WORK"

# 1) 把「内核」编译成单文件 bin（这一步是唯一用到系统 bun 的地方）
mkdir -p "$WORK/bin"
if [[ ! -x "$BIN" || "${K1_REBUILD:-0}" == "1" ]]; then
  echo "== 编译 spike 内核 bin（约 60MiB，落 ${BIN}）=="
  "$BUN" build "$HERE/fixtures/kernel.ts" --compile --outfile "$BIN"
fi
ls -l "$BIN" | awk '{print "bin 体积:", $5, "字节"}'

# 2) 备料：把 probe 打成 npm tarball，铺开插件工程与边界样本
echo "== 备料 =="
rm -rf "$RUN"
mkdir -p "$RUN/pack" "$RUN/edge-out"
cp -R "$HERE/fixtures/probe-pkg" "$RUN/pack/package"
tar -czf "$RUN/pack/a2-lifecycle-probe-1.0.0.tgz" -C "$RUN/pack" package

cp -R "$HERE/fixtures/plugin" "$RUN/plugin-src"
cp "$RUN/pack/a2-lifecycle-probe-1.0.0.tgz" "$RUN/plugin-src/"
cp -R "$RUN/plugin-src" "$RUN/plugin-src-ignore-scripts"
cp -R "$RUN/plugin-src" "$RUN/plugin-src-cold"
cp -R "$HERE/fixtures/edge/dynamic-require" "$RUN/edge-dynamic-require"
cp -R "$HERE/fixtures/edge/native-addon" "$RUN/edge-native-addon"
cp -R "$HERE/fixtures/edge/missing-dep" "$RUN/edge-missing-dep"
# auto-install 触发规则的三个对照目录：全隔离 / 只有 package.json / 祖先有(空)node_modules
mkdir -p "$RUN/auto-iso" "$RUN/auto-pkgjson" "$RUN/auto-blocked/sub" "$RUN/auto-blocked/node_modules"
cp "$HERE/fixtures/edge/auto-install/iso.ts" "$RUN/auto-iso/iso.ts"
cp "$HERE/fixtures/edge/auto-install/iso.ts" "$RUN/auto-pkgjson/iso.ts"
cp "$HERE/fixtures/edge/auto-install/package.json" "$RUN/auto-pkgjson/package.json"
cp "$HERE/fixtures/edge/auto-install/iso.ts" "$RUN/auto-blocked/sub/iso.ts"

# 3) 内核 bin 自跑全流程：install → build → 删源目录 → describe/call
echo "== 内核 bin 自测（install / build / 单文件工件执行）=="
set +e
"$BIN" selftest "$RUN" > "$RUN/report.json"
RC=$?
set -e

# 4) 汇总也走 BUN_BE_BUN（顺带再证一次「产物当通用 bun CLI 跑外部 .ts」）
echo "== 断言 =="
BUN_BE_BUN=1 "$BIN" "$HERE/fixtures/summarize.ts" "$RUN/report.json"

exit $RC
