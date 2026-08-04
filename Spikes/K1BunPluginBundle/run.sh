#!/bin/bash
# K1 —— BUN_BE_BUN 自举 bun install / bun build spike（.scratch/a2-kernel/issues/02）
# PROTOTYPE：抛弃式实验，不进产品代码。产物（约 60MiB 的编译 bin + 临时插件工程）
# 一律落在临时工作目录，绝不落仓库。
#
#   bash Spikes/K1BunPluginBundle/run.sh [workdir]
#
# 环境：BUN_BIN 覆写系统 bun 路径（默认 ~/.bun/bin/bun，只用来编译出 spike 的内核 bin；
# 编译之后的全部动作都由那个 bin 自己经 BUN_BE_BUN 驱动，不再碰系统 bun）。
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"

BUN="${BUN_BIN:-$HOME/.bun/bin/bun}"
WORK="${1:-${A2_SPIKE_WORKDIR:-$(mktemp -d -t a2-k1)}}"
BIN="$WORK/a2-spike-bin"

echo "== K1 spike =="
echo "系统 bun : $BUN ($("$BUN" --version))"
echo "工作目录 : $WORK"

# 1) 把「内核」编译成单文件 bin（这一步是唯一用到系统 bun 的地方）
if [[ ! -x "$BIN" || "${K1_REBUILD:-0}" == "1" ]]; then
  echo "== 编译 spike 内核 bin（约 60MiB，落 ${BIN}）=="
  "$BUN" build "$HERE/fixtures/kernel.ts" --compile --outfile "$BIN"
fi
ls -l "$BIN" | awk '{print "bin 体积:", $5, "字节"}'

# 2) 备料：把 probe 打成 npm tarball，铺开插件工程与边界样本
echo "== 备料 =="
rm -rf "$WORK/plugin-src" "$WORK/plugin-src-ignore-scripts" "$WORK/plugin-src-cold" \
       "$WORK/registry" "$WORK/neutral" "$WORK/edge-dynamic-require" "$WORK/edge-native-addon" \
       "$WORK/edge-missing-dep" "$WORK/edge-out" "$WORK/pack" "$WORK/cold-cache" \
       "$WORK/auto-iso" "$WORK/auto-blocked" "$WORK/auto-iso-cache" "$WORK/auto-blocked-cache" \
       "$WORK/autoinstall-cache" "$WORK/autoinstall-cache-2"
mkdir -p "$WORK/pack" "$WORK/edge-out"
cp -R "$HERE/fixtures/probe-pkg" "$WORK/pack/package"
tar -czf "$WORK/pack/a2-lifecycle-probe-1.0.0.tgz" -C "$WORK/pack" package

cp -R "$HERE/fixtures/plugin" "$WORK/plugin-src"
cp "$WORK/pack/a2-lifecycle-probe-1.0.0.tgz" "$WORK/plugin-src/"
cp -R "$WORK/plugin-src" "$WORK/plugin-src-ignore-scripts"
cp -R "$WORK/plugin-src" "$WORK/plugin-src-cold"
cp -R "$HERE/fixtures/edge/dynamic-require" "$WORK/edge-dynamic-require"
cp -R "$HERE/fixtures/edge/native-addon" "$WORK/edge-native-addon"
cp -R "$HERE/fixtures/edge/missing-dep" "$WORK/edge-missing-dep"
# auto-install 触发规则的两个对照目录：全隔离 vs 祖先目录有(空)node_modules
mkdir -p "$WORK/auto-iso" "$WORK/auto-blocked/sub" "$WORK/auto-blocked/node_modules"
cp "$HERE/fixtures/edge/auto-install/iso.ts" "$WORK/auto-iso/iso.ts"
cp "$HERE/fixtures/edge/auto-install/iso.ts" "$WORK/auto-blocked/sub/iso.ts"

# 3) 内核 bin 自跑全流程：install → build → 删源目录 → describe/call
echo "== 内核 bin 自测（install / build / 单文件工件执行）=="
set +e
"$BIN" selftest "$WORK" > "$WORK/report.json"
RC=$?
set -e

# 4) 汇总也走 BUN_BE_BUN（顺带再证一次「产物当通用 bun CLI 跑外部 .ts」）
echo "== 断言 =="
BUN_BE_BUN=1 "$BIN" "$HERE/fixtures/summarize.ts" "$WORK/report.json"

exit $RC
