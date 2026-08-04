# K1 — BUN_BE_BUN 自举 `bun install` / `bun build` spike（PROTOTYPE，抛弃式，不进产品）

> PROTOTYPE。本目录是「a2 内核 bin 化」效应的 02 票实验，验证一条依赖流能否走通，**代码不进产品**、可整目录删除。
> 对应票：`.scratch/a2-kernel/issues/02-spike-bun-be-bun-build.md`（本机决策记录，未入库）。
> 结论已追加进 [`docs/research/ts-kernel-runtime-bun.md`](../../docs/research/ts-kernel-runtime-bun.md) §8（该文档同为未入库的本机调研底稿）。

## 回答的问题

Bun `--compile` 出来的单文件 bin，在 `BUN_BE_BUN=1` 下能否当完整 `bun` CLI 自举整条插件依赖流：

1. 跑 `bun install` 把带 npm 依赖的插件目录装起来（且依赖的 lifecycle scripts 确实被跳过）？
2. 跑 `bun build --target=bun` 把该目录打成**单文件 JS 工件**？
3. 该工件再被**同一个 bin**经 `BUN_BE_BUN` 作子进程拉起，stdin/stdout JSON 往返与退出码语义正确？

结论：**三问全成，31/31 断言通过（Bun 1.3.14 / macOS 15.7.8 arm64）。** 另外撞出三条 12 票必须显式处理的边界（根 package.json 的 lifecycle scripts 默认会执行、运行期 auto-install 会联网装包、`.node` addon 的失败信号形态），详见研究文档 §8。

## 一条命令

```bash
bash Spikes/K1BunPluginBundle/run.sh [workdir]     # workdir 缺省用 mktemp -d
K1_REBUILD=1 bash Spikes/K1BunPluginBundle/run.sh  # 强制重编 spike 内核 bin
```

跑完打印 31 条 PASS/FAIL 断言 + 每步子进程的退出码与耗时，全量报告 JSON 落 `<workdir>/report.json`。

- **产物一律不落仓库**：编译出的 spike 内核 bin 约 **60.5MiB**（63,446,114 字节），连同临时插件工程全在 `workdir` 下。
- **需要网络**：冷缓存 install 与 auto-install 两组对照要连 npm registry；这些步骤把缓存指到 `workdir` 下的临时目录（`BUN_INSTALL_CACHE_DIR`），**不写用户的 `~/.bun/install/cache`**。
- 只用到 `~/.bun/bin/bun` 编译出 spike 的内核 bin（可用 `BUN_BIN` 覆写）；之后的每一步都由那个 bin 自己经 `BUN_BE_BUN=1` 驱动，不再碰系统 bun——这正是被验证的命题。

## 构成

```
fixtures/kernel.ts             「内核」模拟体：编译成单文件 bin；selftest 全流程只用
                                process.execPath + env.BUN_BE_BUN=1 拉自己当 bun CLI
fixtures/summarize.ts           报告打表（也故意用 BUN_BE_BUN 跑，顺带再证外部 .ts 执行）
fixtures/plugin/                带 npm 依赖的目录插件样本（picocolors + 本地 tarball 依赖）
                                协议照 13 票：describe 出清单 / call 走 stdin-stdout JSON
fixtures/probe-pkg/             被打成 npm tarball 的依赖，pre/postinstall 一执行就留 *_RAN 标记
fixtures/edge/dynamic-require/  边界：非静态可分析的 require
fixtures/edge/native-addon/     边界：.node addon（占位文件，只看编译期行为）
fixtures/edge/missing-dep/      边界：声明了依赖但没 install
fixtures/edge/auto-install/     边界：静态 import 一个本地没装的包，验 auto-install 触发规则
run.sh                          编译 bin → 备料 → 内核 bin 自测 → 打表
```

`kernel.ts` 里每一步都记录**原始 argv / cwd / 退出码 / 耗时 / stdout / stderr**，报告 JSON 即证据，不靠叙述。

## 结论速查（细节与原文命令见研究文档 §8）

| 问题 | 结论 | 关键数据 |
|---|---|---|
| ① `BUN_BE_BUN` 跑 `bun install` | **成** | 热缓存 16–18ms、冷缓存约 4.0s（2 包）；依赖 lifecycle scripts 被拦：`Blocked 2 postinstalls` |
| ①附带 | **根 `package.json` 的 pre/post/prepare 脚本默认照跑**（供应链口子） | 三个标记文件全落地；`--ignore-scripts` 可连根一并封死 |
| ② `BUN_BE_BUN` 跑 `bun build --target=bun` | **成** | 6,002 字节单文件工件，`Bundled 3 modules in 5ms`，依赖全内联 |
| ③ 工件被同一 bin 拉起 | **成** | 删掉整个源目录（含 node_modules）后 describe/call 输出不变；独立 PID；退出码 0/2/3/4 语义按插件定义传回 |
| 边界·动态 require | 打包期静默通过，运行期 **auto-install 联网装包** | 加 `--no-install` 即 fail-closed（`Cannot find package`, exit 1） |
| 边界·`.node` addon | `--outfile` 直接 build 失败；`--outdir` 会额外吐出 `.node` 文件 | 「产物不止一个文件」可作拒绝依据 |
| 边界·依赖未装 | build 明确失败，不产坏工件 | `error: Could not resolve: "left-pad". Maybe you need to "bun install"?` |
