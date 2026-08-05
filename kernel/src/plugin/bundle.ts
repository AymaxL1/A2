// 目录插件的装载期流水线:**临时目录里 install + bundle,产出一个单文件工件**(12 票,ADR 0011)。
//
// ============================================================================
// 一句话:带依赖的插件在 `a2 plugin add` 那一刻被打成单文件,之后运行期与零依赖插件**没有区别**
// ============================================================================
// 于是 `~/.a2/plugins/` 里永远只有一堆单文件工件:没有 `node_modules`、没有 lockfile、没有
// "这个插件当初是怎么装的"这种需要记账的历史。11 票铺的登记区一行都不用改,`store.ts` / `protocol.ts`
// 更是完全不知道有"目录插件"这回事 —— 这正是本票想要的形状。
//
// ============================================================================
// 四条纪律,全部来自 02 票 spike 的实测(`docs/research/ts-kernel-runtime-bun.md` §8)
// ============================================================================
//   ① **install 必带 `--ignore-scripts`**(§8.1,本票最重要的安全项)。"bun install 默认不跑
//      lifecycle scripts"这句话**只对依赖成立**:被装的那个工程(= 用户/agent 交来的、未经审查的
//      插件目录)自己 `package.json` 里的 `preinstall`/`postinstall`/`prepare` **照跑**。
//      也就是说,没有这个 flag,`a2 plugin add <目录>` 就等于"当场以用户身份执行目录里写的任意命令"。
//      装载零闸(ADR 0011)的前提是"装载本身不执行插件代码",这个 flag 就是那个前提本身。
//   ② **build 用 `--outdir` 而不是 `--outfile`**(§8.4)。native addon(`.node`)在 `--outfile` 下
//      让 build 失败、在 `--outdir` 下让 build **成功**并多吐一个 `.node` 文件。所以判据不能是退出码,
//      只能是**产物文件数**:>1 即"这不是一个单文件插件",连同任何被外置的资源一起落进同一条拒绝。
//   ③ **临时目录,不是源目录**。install 会在工程目录里造 `node_modules` 与 lockfile —— 那是用户的目录,
//      内核没有资格往里写。整棵源码先复制进临时工作区,装/打全在那儿发生,完事整个删掉。
//      于是"node_modules 即用即弃"不是一句口号,而是"它压根没在别处存在过"。
//   ④ **工具链的环境是白名单**,与插件子进程同一条红线:`A2_*` 一个都不递。区别只有两处,
//      而且都有必须的理由:给 `HOME`(bun 的包缓存默认在 `~/.bun/install/cache`,不给就每次冷装)
//      与代理变量(用户多半就是靠代理才能连上 registry —— 这是个代理管理器,这条尤其现实)。
//
// ============================================================================
// 拒绝面(**能在 add 期检出的那些**)
// ============================================================================
// 入口找不到 / package.json 坏了 / 源目录大得离谱 / install 失败 / build 失败 / 产物不止一个文件。
// 每一条都是**结构化拒绝 + 指引**,而不是半吊子支持。
// 检不出的那一类(动态 `require(变量)`,spike 实测打包期 exit=0 且零告警)由运行期的 `--no-install`
// 兜底 —— 那段在 `protocol.ts` 的 `missingPackageOf`,报错时告诉 agent 该改哪儿。
//
// **为什么不额外"消毒"源目录**(比如删掉 `bunfig.toml`):12 票现场实测(bun 1.3.14)——
// `bunfig.toml` 的 `preload` 在 `bun install --ignore-scripts` 与 `bun build` 下**都不执行**,
// 只有 `bun run` 会跑它;而我们这条流水线一次 `bun run` 都没有。所以纪律①(不执行插件代码)
// 靠 `--ignore-scripts` 就已经完整,再删用户的配置文件只会让"为什么我的配置没生效"变成谜。

import { mkdtemp, readFile, readdir, rm, stat } from "node:fs/promises";
import { copyFileSync, mkdirSync, readdirSync, statSync, type Dirent } from "node:fs";
import os from "node:os";
import path from "node:path";
import { ErrorCode, type Guidance, type WireError } from "../contract/wire.ts";
import { OUTPUT_LIMIT_BYTES, captureProcess, type CaptureResult } from "./spawn.ts";

/**
 * 装载期工具链(install / build)的超时窗口。
 *
 * **有意不复用 `A2_PLUGIN_TIMEOUT_MS`**:那是"一次 describe/call 的往返"(spike 实测 7–11ms,
 * 默认窗口 15 秒);这里是"冷缓存下从 registry 拉一棵依赖树"(spike 实测冷 3.4 秒,坏网络下几十秒
 * 都不奇怪)。两件事的时间尺度差两个数量级,共用一个旋钮只会逼人把调用超时也一起放宽。
 */
export const BUILD_TIMEOUT_ENV = "A2_PLUGIN_BUILD_TIMEOUT_MS";
const DEFAULT_BUILD_TIMEOUT_MS = 180_000;

/**
 * 临时工作区的名字前缀。**造它的人与扫它的人必须认同一个常量**(与登记区的 `STAGING_PREFIX`
 * 同一条教训:各写各的字面量就会出现"扫不到的遗留物")。
 */
export const BUILD_AREA_PREFIX = "a2-plugin-build-";

/**
 * 多老的构建区算"遗留"(13 票补的 12 票 CR 尾款 a)。
 *
 * 判据必须是**年龄**,不能是"存在即删":同一台机器上可能有另一个 daemon(另一个 `A2_HOME`)
 * 此刻正在用它自己的构建区装依赖 —— 系统临时目录是共享的,而我们没有"这是我的"这种标记
 * (进程可能已经被 SIGKILL 了,标记本身也会成为遗留物)。
 * 一小时是 `A2_PLUGIN_BUILD_TIMEOUT_MS` 默认值(180 秒)的 20 倍:任何**还在飞**的构建都比它年轻,
 * 而任何进程被杀留下的残骸最终都会比它老。
 */
export const STALE_BUILD_AREA_MS = 60 * 60 * 1000;

/** 入口候选(package.json 的 `main` / `module` 优先,都没有才按约定找)。 */
const ENTRY_CANDIDATES = ["index.ts", "index.js", "index.mts", "index.mjs", "main.ts", "main.js"];

/** 复制源目录时跳过的东西:它们要么由 install 重新产出,要么与构建无关且可能巨大。 */
const SKIPPED_ENTRIES = new Set(["node_modules", ".git", ".jj", ".hg", ".svn", ".DS_Store"]);

/** 源目录体量的 sanity 上限。拦的是"手滑把家目录 add 进来"这种事,不是正经插件。 */
const MAX_SOURCE_FILES = 4_000;
const MAX_SOURCE_BYTES = 64 * 1024 * 1024;

/** 审计事件里最多列多少个依赖(全量在插件目录自己的 lockfile 里,审计只需要"装了些什么")。 */
const MAX_AUDITED_DEPENDENCIES = 60;

/** 插件目录**自己**声明的这些脚本会被 `--ignore-scripts` 拦下 —— 拦下这件事本身要进审计。 */
const LIFECYCLE_SCRIPTS = [
  "preinstall",
  "install",
  "postinstall",
  "prepare",
  "preprepare",
  "postprepare",
  "prepack",
  "postpack",
];

export interface BundleOptions {
  /** daemon 的环境(工具链子进程从它派生,经白名单过滤)。 */
  env: Record<string, string | undefined>;
  /** 覆写工具链超时(测试用;缺省读 `A2_PLUGIN_BUILD_TIMEOUT_MS`)。 */
  timeoutMs?: number;
  /** 覆写工具链输出上限(测试用;缺省 `OUTPUT_LIMIT_BYTES` = 4MiB)。 */
  limitBytes?: number;
}

/** 打包成功后交给调用方的一切。**`dispose()` 必须被调用** —— 临时工作区里躺着一整棵 node_modules。 */
export interface BundleReport {
  /** 临时工作区里那个单文件产物的绝对路径(调用方把它复制进登记区)。 */
  artifact: string;
  /** 入口文件(相对源目录,进审计与报错文本)。 */
  entry: string;
  /** 装出来的依赖清单(审计素材,来自 `bun pm ls`)。 */
  dependencies: string[];
  /** 插件目录自己声明、并被 `--ignore-scripts` 拦下的 lifecycle scripts。 */
  blockedScripts: string[];
  installMs: number;
  buildMs: number;
  bytes: number;
  /** 删掉整个临时工作区(含 node_modules)。 */
  dispose(): Promise<void>;
}

export type BundleOutcome = { ok: true; value: BundleReport } | { ok: false; error: WireError };

/**
 * 把一个目录插件打成单文件工件。
 *
 * 顺序即语义:①复制进临时工作区(源目录一个字节都不写)→ ②读 package.json、定入口 →
 * ③`bun install --ignore-scripts`(有依赖才装)→ ④`bun pm ls` 取审计素材 →
 * ⑤`bun build --target=bun --outdir` → ⑥**产物必须恰好一个文件**。任何一步失败即结构化拒绝,
 * 并把临时工作区删干净。
 */
export async function bundleDirectoryPlugin(
  source: string,
  options: BundleOptions,
): Promise<BundleOutcome> {
  // 临时工作区一律在系统临时目录下 —— **绝不在 `~/.a2`**:登记区是持久区,node_modules 不配进去。
  const workdir = await mkdtemp(path.join(os.tmpdir(), BUILD_AREA_PREFIX));
  const dispose = async () => {
    await rm(workdir, { recursive: true, force: true }).catch(() => {});
  };

  // **工作区的生死只在这一层决定**(13 票补的 12 票 CR 尾款 a):
  //   * 失败 → 就地删掉(流水线自己不必记得收尾,每条拒绝分支只管返回报文);
  //   * 抛出 → 同样删掉,并翻成结构化拒绝(与"router 永不抛"同一条口径)——
  //     此前这条路没有任何分支可走,一次意料之外的异常就永久漏一个几十 MiB 的目录在 /tmp 里;
  //   * 成功 → **不删**,工作区连同产物一起交给调用方(`BundleReport.dispose`)。
  try {
    const outcome = await runBundlePipeline(source, options, workdir, dispose);
    if (!outcome.ok) await dispose();
    return outcome;
  } catch (error) {
    await dispose();
    return {
      ok: false,
      error: loadError(
        `打包插件时出了意料之外的错:${source}`,
        String(error),
        source,
        buildGuidance(source),
      ),
    };
  }
}

/** 流水线本体。每条拒绝分支只管返回报文 —— 工作区的清理归上面那层。 */
async function runBundlePipeline(
  source: string,
  options: BundleOptions,
  workdir: string,
  dispose: () => Promise<void>,
): Promise<BundleOutcome> {
  const timeoutMs = options.timeoutMs ?? readBuildTimeout(options.env);
  const limitBytes = options.limitBytes ?? OUTPUT_LIMIT_BYTES;
  const env = toolchainEnv(options.env);
  const project = path.join(workdir, "project");
  const outdir = path.join(workdir, "out");
  const fail = (error: WireError): BundleOutcome => ({ ok: false, error });

  // ── ① 复制源码进临时工作区 ────────────────────────────────────────────────
  const copied = copyTree(source, project);
  if (!copied.ok) return fail(copied.error);

  // ── ② package.json 与入口 ─────────────────────────────────────────────────
  const manifest = await readPackageJson(project);
  if (!manifest.ok) return fail(manifest.error);

  const entry = resolveEntry(project, manifest.value);
  if (entry === undefined) {
    return fail(
      loadError(
        `目录插件 ${source} 里找不到入口文件。`,
        `找过:package.json 的 main/module 字段,以及 ${ENTRY_CANDIDATES.join(" / ")}。`,
        source,
        buildGuidance(source),
      ),
    );
  }

  // ── ③ install(有声明依赖才装;必带 --ignore-scripts)──────────────────────
  const blockedScripts = LIFECYCLE_SCRIPTS.filter(
    (name) => typeof manifest.value.scripts?.[name] === "string",
  );
  let installMs = 0;
  if (hasDependencies(manifest.value)) {
    const install = await captureProcess(
      [process.execPath, "install", "--ignore-scripts"],
      { cwd: project, env, timeoutMs, limitBytes },
    );
    installMs = install.ms;
    if (install.timedOut) {
      return fail(
        loadError(
          `装依赖超时(${timeoutMs}ms):${source}`,
          tail(install.stderr || install.stdout),
          source,
          timeoutGuidance(timeoutMs),
        ),
      );
    }
    if (install.overflow) {
      return fail(overflowError("装依赖", install, limitBytes, source));
    }
    if (install.exitCode !== 0) {
      return fail(
        loadError(
          `装依赖失败(exit=${install.exitCode}):${source}`,
          tail(install.stderr || install.stdout),
          source,
          installGuidance(source),
        ),
      );
    }
  }

  // ── ④ 审计素材:依赖清单(取不到不算失败 —— 审计缺一行,不该让装载失败)────
  const dependencies = await listDependencies(project, env, timeoutMs, limitBytes);

  // ── ⑤ build ───────────────────────────────────────────────────────────────
  const build = await captureProcess(
    [process.execPath, "build", `./${entry}`, "--target=bun", "--outdir", outdir],
    { cwd: project, env, timeoutMs, limitBytes },
  );
  if (build.timedOut) {
    return fail(
      loadError(
        `打包超时(${timeoutMs}ms):${source}`,
        tail(build.stderr || build.stdout),
        source,
        timeoutGuidance(timeoutMs),
      ),
    );
  }
  if (build.overflow) {
    return fail(overflowError("打包", build, limitBytes, source));
  }
  if (build.exitCode !== 0) {
    return fail(
      loadError(
        `打包失败(exit=${build.exitCode}):${source}`,
        // 打包器的原文就是最好的 detail —— 它带着文件、行号与"到底哪个 import 解析不了"。
        tail(build.stderr || build.stdout),
        source,
        buildGuidance(source),
      ),
    );
  }

  // ── ⑥ 产物必须恰好一个文件(native addon / 外带资源都栽在这条上)──────────
  const produced = listFiles(outdir);
  if (produced.length !== 1) {
    return fail(
      loadError(
        produced.length === 0
          ? `打包没有产出任何文件:${source}`
          : `打包产出了 ${produced.length} 个文件,不是单文件插件:${source}`,
        produced.length === 0
          ? tail(build.stderr || build.stdout)
          : `产物:${produced.join("、")}`,
        source,
        multiFileGuidance(source, produced),
      ),
    );
  }

  const artifact = path.join(outdir, produced[0] as string);
  return {
    ok: true,
    value: {
      artifact,
      entry,
      dependencies,
      blockedScripts,
      installMs,
      buildMs: build.ms,
      bytes: statSync(artifact).size,
      dispose,
    },
  };
}

/**
 * 扫掉系统临时目录里**遗留的**构建区(13 票补的 12 票 CR 尾款 a)。
 *
 * 正常路径上每一条分支都会 `dispose()`,异常路径由上面那层 try 兜着 —— 但 `SIGKILL` / 掉电
 * 没有任何分支可走,而每个构建区里都可能躺着一棵 node_modules。登记区的 `.staging-*` 早就有这道
 * 清扫(11 票 CR 尾款 d),构建区此前没有:这里补上,判据是**年龄**(见 `STALE_BUILD_AREA_MS`)。
 *
 * best-effort:删不动就算了,卫生问题不该拦住装载(与 `sweepStagingArtifacts` 同一口径)。
 */
export async function sweepStaleBuildAreas(
  options: { now?: number; olderThanMs?: number; tmpDir?: string } = {},
): Promise<string[]> {
  const dir = options.tmpDir ?? os.tmpdir();
  const now = options.now ?? Date.now();
  const olderThanMs = options.olderThanMs ?? STALE_BUILD_AREA_MS;
  let entries: Dirent[];
  try {
    // **异步**读目录:这条扫描在 daemon 启动那一刻跑,而系统临时目录可能有几千个条目 ——
    // 用同步版就是在启动路径上插一段阻塞(卫生问题不该让内核晚一毫秒答话)。
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return [];
  }
  const swept: string[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !entry.name.startsWith(BUILD_AREA_PREFIX)) continue;
    const target = path.join(dir, entry.name);
    try {
      // mtime 而不是 birthtime:构建区在整个装/打过程中一直被写,所以"最后一次动它是什么时候"
      // 才是"还在不在飞"的信号(birthtime 会把一次 10 分钟的冷装误判成遗留)。
      if (now - (await stat(target)).mtimeMs < olderThanMs) continue;
      await rm(target, { recursive: true, force: true });
      swept.push(target);
    } catch {
      // 别人的目录(权限)或正好被人删了 —— 都不是我们的事。
    }
  }
  return swept;
}

// MARK: - 工具链环境

/**
 * 装载期工具链的环境**白名单**。与插件子进程(`pluginEnv`)同一条红线:内核的坐标(`A2_*`)一个不递。
 *
 * 比 `pluginEnv` 多两样,各有各的必须:
 *   * `HOME` —— bun 的包缓存默认在 `~/.bun/install/cache`。不给它,每装一个插件都是冷缓存
 *     (spike 实测 3.4 秒 vs 19 毫秒)。`BUN_INSTALL_CACHE_DIR` 在场时以它为准(测试就是这么把
 *     缓存钉在临时目录里、绝不写用户那份的)。
 *   * 代理变量 —— 用户多半正是**靠代理**才连得上 registry。a2 自己就是个代理管理器,
 *     在这件事上装看不见尤其说不过去。
 *
 * 注意这个环境**不会**跑到插件代码上:install 带 `--ignore-scripts`(插件目录自己的脚本也被拦),
 * build 只做静态打包。真正执行插件的那条路仍然只认 `pluginEnv`。
 */
export function toolchainEnv(
  env: Record<string, string | undefined> = process.env,
): Record<string, string> {
  const allowed = [
    "PATH",
    "HOME",
    "TMPDIR",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TZ",
    "BUN_INSTALL_CACHE_DIR",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "NO_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
    "no_proxy",
  ];
  const picked: Record<string, string> = {};
  for (const key of allowed) {
    const value = env[key];
    if (value !== undefined) picked[key] = value;
  }
  // 编译产物要靠它切换成"我是 bun"(源码模式下跑的本来就是 bun,带着也无害)。
  picked["BUN_BE_BUN"] = "1";
  return picked;
}

function readBuildTimeout(env: Record<string, string | undefined>): number {
  const raw = env[BUILD_TIMEOUT_ENV];
  if (raw === undefined) return DEFAULT_BUILD_TIMEOUT_MS;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_BUILD_TIMEOUT_MS;
}

// MARK: - 源码复制

interface PackageJson {
  main?: string;
  module?: string;
  scripts?: Record<string, unknown>;
  dependencies?: Record<string, unknown>;
  devDependencies?: Record<string, unknown>;
  peerDependencies?: Record<string, unknown>;
  optionalDependencies?: Record<string, unknown>;
}

type Attempt<T> = { ok: true; value: T } | { ok: false; error: WireError };

/**
 * 递归复制(同步:一棵插件源码通常几十个文件,异步只会让"超限就停"这件事变绕)。
 *
 * **跳过 `node_modules`**:装依赖是下一步的事,把用户那棵搬过来只会让"工件里到底装的是什么"
 * 取决于他上次装了什么。跳过 `.git` 同理 —— 与构建无关,而且往往比源码大一个数量级。
 */
function copyTree(source: string, destination: string): Attempt<{ files: number; bytes: number }> {
  let files = 0;
  let bytes = 0;
  const overflow = (): WireError =>
    loadError(
      `目录插件太大(超过 ${MAX_SOURCE_FILES} 个文件或 ${MAX_SOURCE_BYTES / 1024 / 1024}MiB):${source}`,
      "内核要把整棵源码复制进临时工作区才动手装/打 —— 这个体量多半不是一个插件目录。",
      source,
      buildGuidance(source),
    );

  const walk = (from: string, to: string): WireError | undefined => {
    mkdirSync(to, { recursive: true, mode: 0o700 });
    let entries: Dirent[];
    try {
      entries = readdirSync(from, { withFileTypes: true });
    } catch (error) {
      return loadError(`读不了目录 ${from}:${String(error)}`, undefined, source);
    }
    for (const entry of entries) {
      if (SKIPPED_ENTRIES.has(entry.name)) continue;
      const child = path.join(from, entry.name);
      const target = path.join(to, entry.name);
      if (entry.isDirectory()) {
        const failure = walk(child, target);
        if (failure) return failure;
        continue;
      }
      // 只搬普通文件:符号链接/设备/socket 都不该是插件源码的一部分,搬过去只会带来惊喜。
      if (!entry.isFile()) continue;
      files += 1;
      try {
        bytes += statSync(child).size;
      } catch {
        // 统计不到就不统计,别让体检拦住正经文件。
      }
      if (files > MAX_SOURCE_FILES || bytes > MAX_SOURCE_BYTES) return overflow();
      try {
        copyFileSync(child, target);
      } catch (error) {
        return loadError(`复制 ${child} 失败:${String(error)}`, undefined, source);
      }
    }
    return undefined;
  };

  const failure = walk(source, destination);
  return failure ? { ok: false, error: failure } : { ok: true, value: { files, bytes } };
}

async function readPackageJson(project: string): Promise<Attempt<PackageJson>> {
  let raw: string;
  try {
    raw = await readFile(path.join(project, "package.json"), "utf8");
  } catch {
    // 没有 package.json 也可以是个目录插件(几个 .ts 文件互相 import,零依赖)。
    return { ok: true, value: {} };
  }
  try {
    const parsed = JSON.parse(raw) as PackageJson;
    return { ok: true, value: parsed && typeof parsed === "object" ? parsed : {} };
  } catch (error) {
    return {
      ok: false,
      error: loadError(
        "目录插件的 package.json 不是合法 JSON。",
        String(error),
        project,
        buildGuidance(project),
      ),
    };
  }
}

function hasDependencies(manifest: PackageJson): boolean {
  return [
    manifest.dependencies,
    manifest.devDependencies,
    manifest.peerDependencies,
    manifest.optionalDependencies,
  ].some((group) => group !== undefined && Object.keys(group).length > 0);
}

/** 入口:package.json 说了算;没说就按约定找。返回**相对路径**(要拼进 build 的 argv)。 */
function resolveEntry(project: string, manifest: PackageJson): string | undefined {
  const declared = [manifest.module, manifest.main].filter(
    (value): value is string => typeof value === "string" && value.length > 0,
  );
  for (const candidate of [...declared, ...ENTRY_CANDIDATES]) {
    const normalized = candidate.replace(/^\.\//, "");
    // 声明的入口只认工程**内部**的相对路径:`../` 或绝对路径都是在指工作区外面。
    if (path.isAbsolute(normalized) || normalized.split(path.sep).includes("..")) continue;
    try {
      if (statSync(path.join(project, normalized)).isFile()) return normalized;
    } catch {
      continue;
    }
  }
  return undefined;
}

/**
 * 依赖清单(审计素材,02 票 spike §8.6.5:`bun pm ls`)。
 * 取不到就返回空 —— 审计少一行不该让一个本来能装的插件装不上。
 */
async function listDependencies(
  project: string,
  env: Record<string, string>,
  timeoutMs: number,
  limitBytes: number,
): Promise<string[]> {
  const listed = await captureProcess([process.execPath, "pm", "ls"], {
    cwd: project,
    env,
    timeoutMs,
    limitBytes,
  });
  // 超限在这里与"没跑成"同档:审计素材缺一行不该让一个本来能装的插件装不上。
  if (listed.timedOut || listed.overflow !== undefined || listed.exitCode !== 0) return [];
  const names: string[] = [];
  for (const line of stripAnsi(listed.stdout).split("\n")) {
    // `bun pm ls` 的树形输出:`├── picocolors@1.1.1`。只取"名字@版本"那一截。
    const match = /([@a-zA-Z0-9][^\s]*@[^\s]+)\s*$/.exec(line.trim());
    if (match) names.push(match[1] as string);
    if (names.length >= MAX_AUDITED_DEPENDENCIES) break;
  }
  return names;
}

/**
 * 产物目录里的**全部**文件(递归,相对路径)。
 *
 * 递归是必须的:code splitting 关着的时候产物是平的,但 `.node` / 资源文件可能被放进子目录,
 * 而"产物文件数 > 1 即拒绝"这条判据只要漏数一个就白立了。
 */
function listFiles(directory: string, prefix = ""): string[] {
  let entries: Dirent[];
  try {
    entries = readdirSync(directory, { withFileTypes: true });
  } catch {
    return [];
  }
  const found: string[] = [];
  for (const entry of entries) {
    const relative = prefix.length === 0 ? entry.name : `${prefix}/${entry.name}`;
    if (entry.isDirectory()) {
      found.push(...listFiles(path.join(directory, entry.name), relative));
    } else {
      found.push(relative);
    }
  }
  return found.sort();
}

// MARK: - 报文零件

function loadError(
  message: string,
  detail: string | undefined,
  source: string,
  guidance?: Guidance,
): WireError {
  return {
    code: ErrorCode.pluginLoadFailed,
    message,
    ...(detail === undefined || detail.length === 0 ? {} : { detail }),
    guidance: guidance ?? buildGuidance(source),
  };
}

function buildGuidance(source: string): Guidance {
  return {
    summary:
      "目录插件在 add 那一刻被打成**单文件**工件;打不进去的东西内核不做半吊子支持,当场说清楚。",
    steps: [
      {
        description:
          "目录插件的最小形状:一个入口(index.ts,或 package.json 的 main 指着的那个)+ " +
          "可选的 package.json 依赖声明。装依赖与打包都由内核代劳,你不需要自己 bun install。",
      },
      { description: "看插件协议与一个可直接抄的最小例子", command: "a2 plugin --help" },
      { description: "改完重新登记(同名即替换)", command: "a2 plugin add <你的插件目录>" },
    ],
    context: { path: source },
  };
}

/**
 * 工具链输出撞上限(13 票补的 12 票 CR 尾款 b)。
 *
 * 撞上限时 `captureProcess` 会 SIGKILL 子进程,于是 `exitCode` 是 -1 —— 若照"退出码非 0"那条分支
 * 报,agent 读到的是「装依赖失败(exit=-1)」加一段被截断的原文,**完全看不出真正发生了什么**
 * (而 -1 在任何退出码词表里都不存在)。所以超限要有自己的报文:说清是哪条流、上限是多少、
 * 以及一条能自己走通的替代路。
 */
function overflowError(
  step: string,
  result: CaptureResult,
  limitBytes: number,
  source: string,
): WireError {
  const which = result.overflow === "stderr" ? "stderr" : "stdout";
  return loadError(
    `${step}时工具链输出超过上限(${which} 超过 ${Math.round(limitBytes / 1024)}KiB):${source}`,
    tail(result.stderr || result.stdout),
    source,
    {
      summary:
        `内核给工具链的两条流各设了 ${Math.round(limitBytes / 1024)}KiB 上限 —— ` +
        "输出到这个量级说明装/打过程本身出了不对劲的事(死循环的 postinstall、把整棵依赖树打印出来的构建脚本…)," +
        "而不是「输出多了一点」。到顶即杀,内核不会把自己的内存交给一个插件的构建过程说了算。",
      steps: [
        {
          description:
            "先在你自己的目录里手跑一遍看它到底在吐什么:bun install --ignore-scripts 与 " +
            "bun build <入口> --target=bun --outdir /tmp/out",
        },
        { description: "看插件协议与目录插件的形状", command: "a2 plugin --help" },
        { description: "收拾干净之后重新登记", command: `a2 plugin add ${source}` },
      ],
      context: { path: source, stream: which, limitBytes: String(limitBytes) },
    },
  );
}

function installGuidance(source: string): Guidance {
  return {
    summary: "依赖没装成,插件就不可能被打成单文件 —— 先让 install 过。",
    steps: [
      { description: "对着上面的原文查:包名拼错、版本不存在、或者这台机器连不上 registry。" },
      {
        description:
          "内核装依赖时**恒带 --ignore-scripts**(连你自己 package.json 里的 preinstall/postinstall " +
          "一起拦),所以靠 lifecycle script 才能装好的依赖在这里必然失败 —— 这是有意的。",
      },
      { description: "看插件协议与目录插件的形状", command: "a2 plugin --help" },
    ],
    context: { path: source },
  };
}

function multiFileGuidance(source: string, produced: string[]): Guidance {
  const nativeAddons = produced.filter((name) => name.endsWith(".node"));
  return {
    summary:
      "运行期全员单文件(ADR 0011)。打包产物不止一个文件,就说明有东西打不进去 —— 内核不登记它。",
    steps: [
      {
        description:
          nativeAddons.length > 0
            ? `产物里有 native addon:${nativeAddons.join("、")}。原生扩展(.node)不支持 —— ` +
              "它是一个平台相关的二进制,内联不进单文件工件。"
            : "多出来的文件多半是被外置的资源(.node / .wasm / 数据文件)。",
      },
      {
        description:
          "可行的替代:①换一个纯 JS/TS 的同类包;②改用 Bun 内置 API(文件、SQLite、加解密、" +
          "子进程都有内置面,零依赖插件能做的事比想象中多);③把资源用 base64 之类的方式内联进源码。",
      },
      { description: "看插件协议与目录插件的形状", command: "a2 plugin --help" },
    ],
    context: { path: source, produced: produced.join("、") },
  };
}

function timeoutGuidance(timeoutMs: number): Guidance {
  return {
    summary: `装载期工具链的窗口是 ${timeoutMs}ms(与调用超时是两个旋钮,别混用)。`,
    steps: [
      { description: "冷缓存下从 registry 拉一棵大依赖树是会花时间的,先确认网络/代理是通的。" },
      {
        description: "临时放宽窗口再试",
        command: `${BUILD_TIMEOUT_ENV}=600000 a2 plugin add <你的插件目录>`,
      },
    ],
  };
}

/** 工具链输出进 detail 时的截断(排错够用,又不至于让一条错误报文变成日志倾倒场)。 */
function tail(text: string): string {
  const trimmed = stripAnsi(text).trim();
  const limit = 2_000;
  if (trimmed.length <= limit) return trimmed;
  return `…(已截断,共 ${trimmed.length} 字节)\n${trimmed.slice(trimmed.length - limit)}`;
}

/** bun 的输出带颜色转义;进报文之前去掉 —— 那是给终端看的,不是给 agent 读的。 */
function stripAnsi(text: string): string {
  return text.replace(/\u001b\[[0-9;]*m/g, "");
}
