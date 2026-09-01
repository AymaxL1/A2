# 02 — Spike:BUN_BE_BUN 自举 bun install / bun build

**What to build:** 用最小实验回答插件依赖流(spec「插件」节)的成立条件:Bun compile 出的单文件 bin 在 `BUN_BE_BUN=1` 下能否当完整 bun CLI 用——对一个带 npm 依赖的目录跑 `bun install`(默认跳过 lifecycle scripts)与 `bun build --target=bun` 打出单文件 JS 工件,且该工件能被同一 bin 经 `BUN_BE_BUN` 作为子进程正确执行。这是 13 票唯一标注「高置信推断、未实测」的环节。

**Blocked by:** None — can start immediately。

**Status:** done — 875525f(+CR 修复)三问全成(32/32 硬断言 + 2 条留档记录):install/build/工件执行都能由编译产物自举,依赖流照 13 票原样实施;附带撞出三条 12 票必须显式处理的边界(根 package.json 的 lifecycle scripts 默认照跑、运行期 auto-install 会联网装包、.node addon 的失败信号形态)。

- [x] 编译产物内经 `BUN_BE_BUN=1` 执行 `bun install`,在隔离目录装成带依赖的插件工程(记录 lifecycle scripts 是否确未执行)
      —— 成:`exit=0`,`Blocked 2 postinstalls`,依赖包目录里无任何执行标记;`bun pm untrusted` 能列出被拦脚本原文。同一份 workdir 私有缓存(`BUN_INSTALL_CACHE_DIR`,不写用户 `~/.bun`)下冷缓存(首次真下载)3.4s、热缓存 19ms。**但根 `package.json` 自己的 pre/post/prepare 默认照跑**(三个标记文件全落地)——`--ignore-scripts` 实测可连根一并封死。
- [x] 同一产物经 `BUN_BE_BUN=1` 执行 `bun build --target=bun` 产出单文件 JS 工件
      —— 成:`Bundled 3 modules in 5ms`,6,002 字节单文件,两个依赖(registry 包 + 本地 tarball 包)全内联,登记目录下无 chunk/无 node_modules。
- [x] 该工件被同一产物经 `BUN_BE_BUN=1` 作为子进程拉起,stdin/stdout JSON 往返正确、退出码语义正确
      —— 成:**删掉整个插件源目录(含 node_modules)后** describe 输出与删前逐字一致;call 的 stdin/stdout JSON 往返正确;退出码 0(成功)/2(坏报文)/3(插件内失败)/4(未知工具)/1(未捕获异常,栈走 stderr)全部原样传回;插件 PID 与内核不同(进程外隔离)。单次往返 7–11ms。
- [x] 结论(【实测】口径,含 Bun 版本与命令原文)追加进既有 Bun 调研文档;若任一步翻车,写明失败面与备选方案(如内核内调用 Bun 的编程式 build API、或 add 期要求系统级 bun),供插件依赖流票(12)复议
      —— `docs/research/ts-kernel-runtime-bun.md` 新增 §8(Bun 1.3.14 / macOS 15.7.8 arm64,含每条命令原文与 stdout),并更正 §3.3 对 auto-install 的归因;§8.7 记了三条备选方案备查(本次未触发)。

**实测环境与复现**:Bun 1.3.14 / macOS 15.7.8 arm64;spike 代码入库 `Spikes/K1BunPluginBundle/`,一条命令 `bash Spikes/K1BunPluginBundle/run.sh [workdir]`(或 `A2_SPIKE_WORKDIR=…`)——32 条硬断言 + 2 条留档记录 + 每步 argv/退出码/耗时/stdout 落 `<workdir>/run/report.json`。产物(60.5MiB bin + 临时插件工程)一律落临时目录,不入库;所有 install/auto-install 用 workdir 私有缓存,不写用户 `~/.bun/install/cache`。

**给 12 票的落地口径**(细节见研究文档 §8.6):①install 必须带 `--ignore-scripts`;②spawn 插件必须带 `--no-install`(关掉 auto-install,fail-closed);③拒绝判据 = build 非零退出,或(用 `--outdir` 时)产物文件数 > 1;④审计素材用 `bun pm ls` + `bun pm untrusted`;⑤时延口径 add ≈ 冷 4s/热 17ms + build 10ms,调用 7–11ms。
