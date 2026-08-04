#!/bin/bash
# 编译单文件 bin `a2`,并**对产物本身**复跑一遍 bun test(CLI 面测试认 A2_TEST_BIN)。
#
#   bash kernel/scripts/build.sh [产物路径]     # 默认 kernel/dist/a2
#
# 环境:BUN_BIN 覆写 bun 路径(默认 ~/.bun/bin/bun)。
# 产物约 60MiB(内置完整 Bun 运行时,见 docs/research/ts-kernel-runtime-bun.md §2.1),不入库。
set -euo pipefail
cd "$(dirname "$0")/.."

BUN="${BUN_BIN:-$HOME/.bun/bin/bun}"
OUT_REL="${1:-dist/a2}"
mkdir -p "$(dirname "$OUT_REL")"
OUT="$(cd "$(dirname "$OUT_REL")" && pwd)/$(basename "$OUT_REL")"

# 兜底:测试若被中断,可能留下前台 daemon 子进程。只杀"本产物 + daemon run"这一条精确命令行。
cleanup() { pkill -f "^${OUT} daemon run$" 2>/dev/null || true; }
trap cleanup EXIT

echo "== 编译 a2(bun $("$BUN" --version))=="
"$BUN" build ./src/cli/main.ts --compile --outfile "$OUT"
ls -l "$OUT" | awk '{print "产物:", $NF, $5, "字节"}'

echo "== 冒烟:产物自报版本 =="
"$OUT" version

echo "== 对编译产物复跑 bun test =="
A2_TEST_BIN="$OUT" "$BUN" test

echo "== 完成:$OUT =="
