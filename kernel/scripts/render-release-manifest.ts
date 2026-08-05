#!/usr/bin/env bun
// 发布元数据的生成入口:扫一个已经组装好的发布包目录,写出 `a2-release.json`。
//
//   bun run kernel/scripts/render-release-manifest.ts <发布包目录> <版本> [渠道根地址]
//
// **有意不做成 `a2` 的子命令**:发布工具不属产品面 —— 用户机器上的那个 bin 不该带着"怎么组装发布包"
// 这种只有维护者用得上的东西(而且它会把 `a2 --help` 撑大)。逻辑全在 `src/release/manifest.ts`,
// 这里只是把 argv 递进去,好让 `Scripts/release-assemble.sh` 有一条命令可调。

import path from "node:path";
import {
  RELEASE_METADATA_FILE,
  buildReleaseManifest,
  renderReleaseManifest,
} from "../src/release/manifest.ts";

const [dir, version, channelBase] = process.argv.slice(2);
if (dir === undefined || version === undefined) {
  console.error("用法:bun run kernel/scripts/render-release-manifest.ts <发布包目录> <版本> [渠道根地址]");
  process.exit(1);
}

const manifest = await buildReleaseManifest({
  dir,
  version,
  ...(channelBase === undefined || channelBase.length === 0 ? {} : { channelBase }),
});
const file = path.join(dir, RELEASE_METADATA_FILE);
await Bun.write(file, renderReleaseManifest(manifest));
console.log(`已写出 ${file}(${manifest.artifacts.length} 个工件,渠道 ${manifest.channel.status})`);
