#!/usr/bin/env bun
// 平台表的 shell 可读投影:`Scripts/release-assemble.sh` 靠它知道「有哪些平台、资产叫什么、
// bun 的 target 名是什么、默认产出哪几个」。
//
// 为什么不在 shell 里再写一遍那张表:两处手写的表必然漂,而漂的后果是**发布元数据里的资产名
// 与真正落盘的文件名对不上**(安装脚本据元数据下载,于是 404)。表只有一份,在
// `src/release/manifest.ts` 里;这里只是把它打成 TSV。
//
//   bun run kernel/scripts/release-targets.ts
//   → platform<TAB>asset<TAB>bunTarget<TAB>default(yes|no)

import { DEFAULT_TARGETS, KERNEL_TARGETS, type KernelPlatform } from "../src/release/manifest.ts";

for (const [platform, target] of Object.entries(KERNEL_TARGETS)) {
  const isDefault = DEFAULT_TARGETS.includes(platform as KernelPlatform) ? "yes" : "no";
  console.log([platform, target.asset, target.bunTarget, isDefault].join("\t"));
}
