# 12 — 插件依赖流:装载期 install+bundle,运行期全员单文件

**What to build:** 带 npm 依赖的插件(目录 + package.json)在 `a2 plugin add` 时由内核经 `BUN_BE_BUN` 临时 `bun install --ignore-scripts`(02 票实测:默认只跳过**依赖**的 lifecycle scripts,插件目录自己的照跑,见验收框)+ `bun build --target=bun` 打成单文件 JS 工件登记,node_modules 即用即弃;运行期一律单文件。打不进的怪包(native addon、动态 require、外带资源)得到结构化拒绝+指引。若 02 票 spike 翻车,按其记录的备选方案实现,协议面不变。

**Blocked by:** 11(插件宿主)。

**Status:** done — cbc27dd(主体 + 尾款)+ 93edca9(收口)

- [x] 目录插件 add 时自动 install+bundle 成单文件工件并登记;构建用临时目录,node_modules 不落入 `~/.a2` 持久区
      → `kernel/src/plugin/bundle.ts`(新)。临时工作区在 `os.tmpdir()` 下 `a2-plugin-build-*`,`dispose()` 无论成败都删。断言:登记区 `readdirSync` 恰好 `["depplug.js","plugins.json"]`、源目录一个字节没被写、`/tmp` 里构建工作区数量前后不变(`cli-plugin-bundle.test.ts` 第 1 条 + e2e 6-3/6-4)。
- [x] bundle 后的插件与零依赖插件走完全相同的 describe/call 运行路径(运行期无差别)
      → 两种形态在 `host.ts` 只在"怎么产出待登记的那份字节"上分叉,之后 describe/就位/热更新/留痕/调用是同一份代码。断言:同一台 daemon 上两个插件回报的进程事实逐项相同(pid≠内核、`a2env=[]`、cwd 同为登记区 realpath)。
- [x] **add 期能检出的**打不进面 —— native addon(`.node`)与打包失败 —— 结构化拒绝并附指引(说明不支持面与可行替代)。判据:`bun build` 非零退出即拒绝(错误原文进 `detail`);用 `--outdir` 时判据是「产物文件数 > 1」
      → 判据就是 `listFiles(outdir).length !== 1`(递归数);实测本机 `.node` 走的正是 exit=0 + 2 个文件那条路。指引点名 `.node` 不支持并给三条替代。另加四条拒绝面:入口找不到 / package.json 坏 / install 失败 / 源目录体量超限。
- [x] **动态 require 走运行期兜底**:内核 spawn 插件必须带 `--no-install`,调用报错转成结构化错误 + 指引
      → `--no-install` 是 11 票就带的;12 票加的是**认出那句硬错**:`protocol.ts` 的 `missingPackageOf()` 把 `Cannot find package 'x'` 翻成"依赖没打进工件 / 多半是动态 require / 改成静态 import 后重新 add",并把包名放进 `guidance.context.missingPackage`。断言:同一个插件 add 期 exit=0(检不出)、调用期 exit=5 + 指引带"动态 require"与"--no-install"。
- [x] `bun install` 跳过 lifecycle scripts 并在审计事件中记录依赖清单;**install 必须带 `--ignore-scripts`**
      → 审计 detail 里三样:依赖清单(`bun pm ls` 解析,上限 60 条)、入口与耗时、"该插件目录声明的 preinstall、postinstall 未被执行"。断言:插件目录自己的三个 lifecycle scripts 一个标记文件都没落地(源目录与登记区都查)。
- [x] 端到端验收:一个带真实 npm 依赖的示例插件 add 后离线可调(删除源目录后仍正常运行)
      → 门禁内(`bun test` + 插件 e2e 幕⑥)用**本地 npm tarball**(测试自己 `tar -czf` 打的 `package/` 根,`file:` 依赖)——不出网、可复现。**另做一次真 registry 实测**(off-gate,见下)证明"真实 npm 依赖"这半句:`picocolors@1.1.1` 冷缓存 1581ms 装成、删源目录后照调、`BUN_INSTALL_CACHE_DIR` 隔离到临时目录、用户 `~/.bun/install/cache` 条目数前后同为 22。

## 11 票 CR 尾款九项的处置

| | 项 | 处置 |
|---|---|---|
| a | 并发 add 丢更新竞态 | **修**:`host.ts` 的 `serializeMutation()` —— add/remove 排进一条进程内 promise 链(前一个失败也接着排下一个)。断言:两次 `plugin add` 并发 → **重启 daemon 后**两个插件都还在(清单是唯一跨重启的记账,分叉了这里就会少一个)。 |
| b | 孙进程挂死 | **修**:新 `plugin/spawn.ts`,读流与超时/超限 `Promise.race` —— 时钟一到带着已收到的部分返回。措辞改诚实:删掉"不留孤儿",超时指引改成"内核杀得掉插件本身、杀不掉它的子孙(没有进程组的口子),派生的进程请自己收尾"。Bun.spawn 无 detached/进程组口子,**不强求**那条按票面处理。断言:插件 spawn 一个继承 stdout 的 `sleep 5` 后立刻自退 → 内核在 800ms 窗口内交出 `plugin_timeout`,整条调用 < 4s 返回。 |
| c | stdout 无上限 | **修**:stdout/stderr 各 4MiB 上限(`OUTPUT_LIMIT_BYTES`),撞上即杀 + `plugin_protocol_error` + "大东西请写文件回路径"的指引;describe 的工具数上限 128(`MAX_TOOLS_PER_PLUGIN`)。两条各一断言。 |
| d | 登记区卫生 | **修**:①跨扩展名替换(`hello.ts`→`hello.js`)一律 `rm` 掉 `previous.artifact`;②`sweepStagingArtifacts()` 在 **daemon 启动**与**每次 add 前**各扫一次 `.staging-*`。三条断言(旧工件收尸 / add 时清扫 / 启动时清扫)。 |
| e | 清单伪造掀翻 daemon | **修**:`store.ts` 的 `sanitizeRecords()` 逐条复验 `PLUGIN_NAME_PATTERN`(插件名 + 工具名 + 工具重名 + 记录重名),坏条目单条拒绝;`restorePlugins` 与 `listPlugins` 用**同一道**复验(于是 list 与能力面口径一致,不留"列得出、调不动"的幽灵);降级落 stderr(`plugins.restore.degraded`)。断言:手改清单塞一条 `name:"hello.greet"` → daemon 照起、好插件照用、list 不列它、stderr 有痕。 |
| f | 门禁新鲜度守卫补漏 | **修**:`check.sh` ②b 改**恒重建**(理由写进注释:删文件不触发、tsconfig 不在比对内、mtime 本就不是内容的可靠代理——补一条漏一条,不如认下这十几秒)。 |
| g | 红线④断言补全 | **修**:除静态扫 `BUILTIN_CAPABILITIES` 外,新增**活体**扫描 —— 起一台真 daemon 取整张能力表,先断言它确实比自检样本族长、且 `proxy.*` / `arbitration.*` 都在场,再断言无一条以 `plugin.` 开头。 |
| h | 「被拒时插件没被拉起」断言收紧 | **修**:插件的 call 分支一被执行就 `Bun.write` 一个标记文件(路径在生成插件源码时嵌入),dangerous 默拒后断言**该文件不存在**(顺带断言 describe 那一趟也没碰它)。间接证明保留作辅助。 |
| i | ADR 0011 字面漂移 | **修**:「agent 用 `a2 plugin …` 系列命令像用内置能力一样用插件」→「经**同一个** `a2 capabilities call plugin.<插件名>.<工具名>`……`a2 plugin add\|list\|remove` 只是装载面,没有 `a2 plugin call` 这回事」。**顺带**(12 票主题范围内)据 02 spike 实测收紧了两处口径:lifecycle scripts「默认不跑」→「必带 `--ignore-scripts`,根工程的默认照跑」;拒绝面补上「add 期能检出 vs 检不出」的分野与 `--outdir` 判据;Consequences 里"spike 未实测"那条改写为"已实测通过"。 |

## 门禁

`bash Scripts/check.sh` → **步 PASS=8 FAIL=0**(bun test **318** / swift test 101 / 旗舰 e2e 46 / **插件 e2e 50**(34→50)/ .app 出包);tsc 干净;swift build 零 warning。e2e 的被测体是 `kernel/dist/a2`(**编译产物**)—— 也就是说"编译出来的单文件 bin 用 `BUN_BE_BUN` 自举 install+build"这条真实生产路径被门禁真的跑过。

## 缓存隔离自查

- 本票所有 `bun install` 都把 `BUN_INSTALL_CACHE_DIR` 指向临时目录:`bun test` 里 `startWithCache()` 每个用例一个;插件 e2e 里 `BOX_ENV` 带 `BUN_INSTALL_CACHE_DIR="$BOX/bun-cache"`。
- 用户 `~/.bun/install/cache`:开工前 22 条目、跑完全部实验与三轮门禁后仍 **22 条目**,目录 mtime 停在 `8/5 00:45`(早于本票第一次 install 的 11:00)。
- 产品口径(**不是**测试口径):内核不强制覆写缓存目录 —— 缺省就是用户自己的 `~/.bun/install/cache`(不给 `HOME` 会让每次 add 都冷装,spike 实测 3.4s vs 19ms)。`toolchainEnv()` 只是把它与代理变量放进白名单,`A2_*` 一个不递。

## 偏差

1. **未新增任何错误码/事件/契约字段**。目录插件的全部拒绝面复用 `plugin_load_failed`(CLI 退出码 5),运行期兜底复用 `plugin_failed`,依赖清单进既有 `plugin_added` 审计事件的 `detail`。理由:三样东西都已经有确切语义,加新码只会让 Swift 镜像/金标/词表对账多三处账而 agent 的分支一处都不变。**于是本票 0 改动契约面、0 改动 Swift 侧**。
2. **"真实 npm 依赖"分两处兑现**:门禁内不出网(本地 tarball),真 registry 那次是 off-gate 一次性实测并记账。理由是编排口径明写"e2e 进门禁的部分不出网"。
3. **主体与尾款同一个提交**。两者在 `host.ts` / `protocol.ts` / `cli-plugin.test.ts` 三个文件里交织(尾款 b/c 的 `spawn.ts` 正是主体 install/build 复用的那段),拆开会留下编译不过的中间提交。提交信息里分节列清。
