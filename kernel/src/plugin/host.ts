// 插件宿主:`plugin.add` / `plugin.list` / `plugin.remove` 三条 op 的编排(11 票)。
//
// 一条贯穿本文件的裁决(ADR 0011,不是本票新裁的):**装载零闸、调用层唯一仲裁**。
// `a2 plugin add` 不问任何人、不等任何人 —— 依据是同 UID 威胁模型:能敲 `a2 plugin add` 的 agent
// 本来就能在用户身份下直接跑任意代码,装载闸不新增任何防御,只给「agent 现场写插件」加摩擦。
// 于是这条路上唯一的可审计物就是**审计事件**(`plugin_added` / `plugin_removed`):
// 它必须发得出去(推给确认器与订阅者)、写得进 NDJSON 日志。这是本文件里唯一不许省的一步。
//
// 危险性的把关全在**调用层**:`describe` 里声明了 dangerous 的工具,登记成 dangerous 档能力,
// 被调用时自动走 08 票的三层仲裁 —— 那段代码在 `capability/registry.ts` 里,本文件一行都不必写。
// 「插件工具的仲裁不用做任何事」这句话能成立,靠的是插件能力与内置能力**是同一种东西**。

import { statSync } from "node:fs";
import { copyFile, rename, rm } from "node:fs/promises";
import path from "node:path";
import { bundleDirectoryPlugin, type BundleReport } from "./bundle.ts";
import type { Capability, CapabilityRegistry } from "../capability/registry.ts";
import {
  ErrorCode,
  opFailure,
  opSuccess,
  payload,
  type CapabilityDescriptor,
  type OpOutcome,
  type PluginAction,
  type PluginRecord,
  type PluginToolSpec,
  type WireError,
} from "../contract/wire.ts";
import type { AuditLog } from "../daemon/audit.ts";
import type { ClientHub } from "../daemon/hub.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { describePlugin } from "./protocol.ts";
import {
  PLUGIN_NAME_PATTERN,
  STAGING_PREFIX,
  capabilityIdsOf,
  ensurePluginsDir,
  pluginCapabilities,
  pluginManifestPath,
  pluginsDir,
  readPluginManifest,
  sanitizeRecords,
  sweepStagingArtifacts,
  writePluginManifest,
} from "./store.ts";

/** 单文件插件允许的扩展名。目录插件走 12 票的装载期流水线,产物恒为 `.js`。 */
const ARTIFACT_EXTENSIONS = [".ts", ".js"];

/**
 * **装载面的写操作全部串行**(11 票 CR 尾款 a)。
 *
 * 为什么必须有:`add` 的头是"读清单"、尾是"写清单",中间隔着一次最长 15 秒的 describe
 * (目录插件还要隔一次可能几十秒的 install+build)。两个 `add` 并发时,后写的那份清单是基于
 * **它自己进门时读到的**那份算出来的 —— 先写的那条记录就这么被覆盖没了,而它的能力还在注册表里。
 * 结果是注册表与清单分叉:`capabilities list` 里有的东西,重启之后消失。
 *
 * 修法取最简的那个:进程内一条 promise 链。daemon 是单进程单事件循环,装载又是**人/agent 手动**
 * 触发的低频操作(不是热路径),排队几秒钟没有任何代价;换成"写前重读合并"则要在每一处
 * 想清楚"合并谁赢",而那正是分叉的来源。
 */
let mutations: Promise<unknown> = Promise.resolve();
function serializeMutation<T>(task: () => Promise<T>): Promise<T> {
  // 前一个失败也要接着排下一个 —— 队列不能被一次装载失败卡死。
  const run = mutations.then(task, task);
  mutations = run.then(
    () => undefined,
    () => undefined,
  );
  return run;
}

export interface PluginHostContext {
  paths: KernelPaths;
  registry: CapabilityRegistry;
  audit: AuditLog;
  hub: ClientHub;
  env: Record<string, string | undefined>;
}

// MARK: - 启动时的还原

export interface RestoredPlugins {
  records: PluginRecord[];
  /** 还原出来的能力(直接喂给注册表构造器,与内置能力同列)。 */
  capabilities: Capability[];
  /** 清单读不了/坏了时的说明(daemon 照常启动,但一个插件都不装 —— 见 `store.ts` 的处置口径)。 */
  problem?: string;
}

/**
 * daemon 启动时把已登记的插件还原出来。
 *
 * **不重新 describe**:登记的是 add 那一刻的快照,工件在我们自己的登记区里、只有 add 会动它。
 * 重新问一遍既不会更真,又会让启动时间随插件数线性增长、还多出一条"启动时插件炸了怎么办"的分支。
 *
 * **但每一条都要复验取值域**(11 票 CR 尾款 e):清单是盘上的一个 JSON 文件,谁都能手改。
 * 塞一条名字带点的记录进去,派生出的能力 id 就会与别的撞上、注册表构造器当场抛 —— 于是
 * **手改一个文件就能让 daemon 起不来**。还原时逐条按 `PLUGIN_NAME_PATTERN` 复验,坏条目单条拒绝,
 * daemon 照起、别的插件照用。这与"清单整个读不了就一个都不装"是同一条精神:
 * **启动永远不该被外来数据掀翻**。
 */
export function restorePlugins(
  paths: KernelPaths,
  env: Record<string, string | undefined> = process.env,
): RestoredPlugins {
  const read = readPluginManifest(paths);
  if (!read.ok) return { records: [], capabilities: [], problem: read.detail };

  const { records, problem } = sanitizeRecords(read.records);
  const capabilities = records.flatMap((record) => pluginCapabilities(record, env));
  return { records, capabilities, ...(problem === undefined ? {} : { problem }) };
}

// MARK: - plugin.list

/**
 * 列已登记插件。
 *
 * 用的是与 `restorePlugins` **同一道**复验:list 说的必须是"此刻真的在能力面上的那些"。
 * 若清单里有被拒的坏条目,它不出现在这里 —— 于是 `plugin list` 与 `capabilities list`
 * 永远对得上,而不是让 agent 看见一条"列得出来、调不动"的幽灵记录。
 */
export function listPlugins(context: PluginHostContext): OpOutcome {
  const read = readPluginManifest(context.paths);
  if (!read.ok) return opFailure(manifestBrokenError(context.paths, read.detail));
  const { records } = sanitizeRecords(read.records);
  return opSuccess(payload({ directory: pluginsDir(context.paths), plugins: records }));
}

// MARK: - plugin.add

export interface AddPluginParams {
  /** 源文件的**绝对路径**(CLI 侧按自己的 cwd 展开后再发 —— daemon 的 cwd 与 agent 的不是一回事)。 */
  path: string;
  name?: string;
}

/**
 * 装一个零依赖单文件插件。顺序即语义:
 *   ①校验入参与文件 → ②复制进登记区的**暂存名** → ③对暂存工件 `describe`(问的就是将来会被调用的那一份)
 *   → ④成清单与能力 → ⑤注册表热更新(全或无,失败即回滚)→ ⑥落清单 → ⑦审计留痕 + 推增量。
 *
 * ③ 为什么要先复制再 describe:调用时插件跑在登记区里(`cwd` 与 `--no-install` 都钉死了),
 * 那么"它说自己有哪些工具"这句话也该在**同一个环境**下问出来。在源目录里问、到登记区里跑,
 * 中间隔着一层可能不一样的祖先目录(比如源目录旁边有个 `node_modules`)—— 那正是静默漂移的温床。
 */
export function addPlugin(
  context: PluginHostContext,
  params: AddPluginParams,
): Promise<OpOutcome> {
  return serializeMutation(() => addPluginSerially(context, params));
}

async function addPluginSerially(
  context: PluginHostContext,
  params: AddPluginParams,
): Promise<OpOutcome> {
  const read = readPluginManifest(context.paths);
  if (!read.ok) return opFailure(manifestBrokenError(context.paths, read.detail));

  const source = params.path;
  if (!path.isAbsolute(source)) {
    return opFailure(
      loadError(
        `插件路径必须是绝对路径(收到 ${JSON.stringify(source)})。`,
        "daemon 的工作目录与你敲命令的目录不是一回事,相对路径会指到别处;`a2 plugin add` 会替你展开。",
      ),
    );
  }

  const stat = statOf(source);
  if (stat === undefined) {
    return opFailure(loadError(`插件路径不存在:${source}`, undefined, source));
  }

  // 两种形态在这里分叉,**而且只在这里分叉**:目录插件多一段装载期流水线(install+bundle),
  // 之后交出的同样是"一个待登记的单文件",后面每一步都不知道它是打出来的还是手写的。
  const isDirectory = stat.isDirectory();
  const extension = isDirectory ? ".js" : path.extname(source);
  if (!isDirectory && !ARTIFACT_EXTENSIONS.includes(extension)) {
    return opFailure(
      loadError(
        `插件文件的扩展名必须是 ${ARTIFACT_EXTENSIONS.join(" 或 ")}(收到 ${JSON.stringify(extension)})。`,
        "带依赖的插件请交一个**目录**(入口 + package.json),内核会在装载期把它打成单文件。",
        source,
      ),
    );
  }

  const name =
    params.name ?? (isDirectory ? path.basename(source) : path.basename(source, extension));
  if (!PLUGIN_NAME_PATTERN.test(name)) {
    return opFailure(
      loadError(
        `插件名不合法:${JSON.stringify(name)}。`,
        `取值域是 ${PLUGIN_NAME_PATTERN.source} —— 它要拼进能力 id(plugin.<插件名>.<工具名>),` +
          "所以只收小写字母、数字、下划线与短横。用 --name 指定一个合法名字即可。",
        source,
      ),
    );
  }

  const directory = ensurePluginsDir(context.paths);
  // 上一次崩在半路留下的暂存工件,在这里清掉(登记区里只该有正式工件与清单)。
  await sweepStagingArtifacts(context.paths);

  // **装载期流水线**:目录插件在这里被打成单文件(12 票)。临时工作区在系统临时目录下,
  // 用完即弃 —— `~/.a2` 里永远不会出现 node_modules。
  let bundle: BundleReport | undefined;
  if (isDirectory) {
    const bundled = await bundleDirectoryPlugin(source, { env: context.env });
    if (!bundled.ok) return opFailure(bundled.error);
    bundle = bundled.value;
  }

  try {
    return await registerArtifact(context, {
      source,
      name,
      extension,
      directory,
      // 要登记的那份字节:单文件插件是源文件本身,目录插件是刚打出来的产物。
      artifactSource: bundle?.artifact ?? source,
      previousRecords: read.records,
      ...(bundle === undefined ? {} : { bundle }),
    });
  } finally {
    // 临时工作区(含 node_modules)一律在这里消失,不管上面是成是败。
    await bundle?.dispose();
  }
}

interface RegisterParams {
  source: string;
  name: string;
  extension: string;
  directory: string;
  artifactSource: string;
  previousRecords: PluginRecord[];
  bundle?: BundleReport;
}

/** 体检 → 就位 → 注册表热更新 → 落清单 → 留痕。**两种形态在这里已经合流,一份代码。** */
async function registerArtifact(
  context: PluginHostContext,
  params: RegisterParams,
): Promise<OpOutcome> {
  const { source, name, extension, directory, artifactSource, previousRecords, bundle } = params;
  const artifact = path.join(directory, `${name}${extension}`);
  // 前缀取自 `store.ts` 的常量:**造暂存件的人与扫暂存件的人必须认同一个前缀**,
  // 各写各的字面量就会出现"扫不到的遗留物"(而那正是尾款 d 要根治的东西)。
  const staging = path.join(directory, `${STAGING_PREFIX}${name}-${crypto.randomUUID()}${extension}`);

  try {
    await copyFile(artifactSource, staging);
  } catch (error) {
    return opFailure(loadError(`复制插件到登记区失败:${String(error)}`, undefined, source));
  }

  const described = await describePlugin(staging, { env: context.env, cwd: directory });
  if (!described.ok) {
    await rm(staging, { force: true }).catch(() => {});
    return opFailure(described.error);
  }

  const badTool = described.value.tools.find((tool) => !PLUGIN_NAME_PATTERN.test(tool.name));
  if (badTool) {
    await rm(staging, { force: true }).catch(() => {});
    return opFailure(
      loadError(
        `工具名不合法:${JSON.stringify(badTool.name)}。`,
        `取值域是 ${PLUGIN_NAME_PATTERN.source}(与插件名同一条规则,理由也一样:它要拼进能力 id)。`,
        source,
      ),
    );
  }
  const duplicateTool = firstDuplicate(described.value.tools);
  if (duplicateTool !== undefined) {
    await rm(staging, { force: true }).catch(() => {});
    return opFailure(
      loadError(
        `describe 的清单里有重名工具:${duplicateTool}。`,
        "同一个插件里工具名必须互不相同 —— 否则两条工具会派生出同一个能力 id。",
        source,
      ),
    );
  }

  // 暂存工件通过了体检,这才让它就位(同名即替换:旧那份被原子覆盖)。
  const previous = previousRecords.find((record) => record.name === name);
  try {
    await rename(staging, artifact);
  } catch (error) {
    await rm(staging, { force: true }).catch(() => {});
    return opFailure(loadError(`工件就位失败:${String(error)}`, undefined, source));
  }
  // **跨扩展名替换要收尸**(11 票 CR 尾款 d):`hello.ts` 换成 `hello.js`(或目录插件打出来的 `.js`)
  // 时,rename 覆盖的是新那个路径,旧工件原地不动 —— 留在登记区里成了一份**再也不会被调用、
  // 却随时可能被误当成"这个插件的代码"**的死文件。替换一律删掉前一份工件。
  if (previous !== undefined && previous.artifact !== artifact) {
    await rm(previous.artifact, { force: true }).catch(() => {});
  }

  const record: PluginRecord = {
    name,
    artifact,
    source,
    addedAt: new Date().toISOString(),
    tools: described.value.tools,
    capabilities: [],
  };
  record.capabilities = capabilityIdsOf(record);

  // 注册表热更新:先摘旧(替换的情形),再上新。**全或无** —— 上不去就把旧的原样放回去。
  const removedIds = previous ? capabilityIdsOf(previous) : [];
  const removedDescriptors = context.registry.unregister(removedIds);
  const capabilities = pluginCapabilities(record, context.env);
  const clash = context.registry.register(capabilities);
  if (clash) {
    if (previous) context.registry.register(pluginCapabilities(previous, context.env));
    return opFailure(clash);
  }

  const records = previousRecords.filter((entry) => entry.name !== name);
  records.push(record);
  try {
    await writePluginManifest(context.paths, records);
  } catch (error) {
    // 清单没落盘 = 重启就没了。与其留一个"这次能用、下次消失"的幽灵,不如当场退回去。
    // **诚实记账**:注册表退得回去,但同名替换时**盘上那份旧工件已经被覆盖**(rename 是原子的、
    // 也是不可逆的)。所以退回去的那条旧记录此刻指着新内容 —— 这条路径只在写盘失败(盘满/只读)
    // 时走到,那种时候用户要做的本来就是先修盘再重装,不值得为它把旧工件也备份一份。
    context.registry.unregister(record.capabilities);
    if (previous) context.registry.register(pluginCapabilities(previous, context.env));
    return opFailure(loadError(`写插件清单失败:${String(error)}`, undefined, source));
  }

  const action: PluginAction = previous ? "replaced" : "added";
  const added = capabilities.map((capability) => capability.descriptor);
  announce(context, {
    auditAction: "plugin_added",
    detail:
      `插件 ${name} ${previous ? "替换登记" : "登记"}成功,工件 ${artifact},` +
      `工具 ${record.tools.length} 个(${record.capabilities.join("、")})。` +
      `装载零闸:本次没有经过任何确认(ADR 0011)。` +
      (bundle === undefined ? "" : bundleAudit(bundle)),
    event: {
      action,
      plugin: name,
      added,
      removed: removedDescriptors.map((descriptor) => descriptor.id),
      capabilities: context.registry.list(),
    },
  });

  return opSuccess(
    payload({
      action,
      plugin: record,
      added,
      removed: removedDescriptors.map((descriptor) => descriptor.id),
    }),
  );
}

/**
 * 目录插件那一段的审计文本(12 票验收框:**依赖清单进审计事件**)。
 *
 * 装载零闸下审计是这条路上唯一的可审计物,而"这个插件把什么代码内联进了工件"正是事后复盘时
 * 唯一还问得出答案的地方 —— 工件是打包产物,`node_modules` 早就没了。
 *
 * 被 `--ignore-scripts` 拦下的 lifecycle scripts 也记:02 票 spike 实测,插件目录**自己**的
 * `preinstall`/`postinstall` 在没有这个 flag 时会照跑。记下"它声明了、我们没跑",既是留痕,
 * 也是"这个插件试图在装载期执行命令"这件事的唯一记录。
 */
function bundleAudit(bundle: BundleReport): string {
  const parts = [
    `目录插件装载期打包:入口 ${bundle.entry},工件 ${bundle.bytes} 字节` +
      `(install ${bundle.installMs}ms + build ${bundle.buildMs}ms)。`,
    bundle.dependencies.length === 0
      ? "依赖:无。"
      : `依赖(${bundle.dependencies.length} 条):${bundle.dependencies.join("、")}。`,
    bundle.blockedScripts.length === 0
      ? "install 带 --ignore-scripts,lifecycle scripts 全程未执行。"
      : `install 带 --ignore-scripts:该插件目录声明的 ${bundle.blockedScripts.join("、")} ` +
        "未被执行(依赖的 lifecycle scripts 同样跳过)。",
  ];
  return ` ${parts.join("")}`;
}

// MARK: - plugin.remove

export function removePlugin(context: PluginHostContext, name: string): Promise<OpOutcome> {
  return serializeMutation(() => removePluginSerially(context, name));
}

async function removePluginSerially(
  context: PluginHostContext,
  name: string,
): Promise<OpOutcome> {
  const read = readPluginManifest(context.paths);
  if (!read.ok) return opFailure(manifestBrokenError(context.paths, read.detail));

  const record = read.records.find((entry) => entry.name === name);
  if (!record) {
    return opFailure({
      code: ErrorCode.unknownPlugin,
      message: `没有登记过名为 ${name} 的插件。`,
      detail:
        read.records.length === 0
          ? "本内核当前一个插件都没装。"
          : `已登记的插件:${read.records.map((entry) => entry.name).join("、")}`,
      guidance: {
        summary: "先看看装了什么,再按名字卸载。",
        steps: [{ description: "列出已登记插件", command: "a2 plugin list --json" }],
      },
    });
  }

  const removedDescriptors = context.registry.unregister(capabilityIdsOf(record));
  await writePluginManifest(
    context.paths,
    read.records.filter((entry) => entry.name !== name),
  );
  // 工件删不掉不该让卸载失败(它已经不在清单里、也不在注册表里了)——留个孤儿文件比留个半卸状态强。
  await rm(record.artifact, { force: true }).catch(() => {});

  announce(context, {
    auditAction: "plugin_removed",
    detail: `插件 ${name} 已卸载,注销能力 ${removedDescriptors.length} 条(${record.capabilities.join("、")})。`,
    event: {
      action: "removed",
      plugin: name,
      added: [],
      removed: removedDescriptors.map((descriptor) => descriptor.id),
      capabilities: context.registry.list(),
    },
  });

  return opSuccess(
    payload({
      action: "removed" as PluginAction,
      plugin: record,
      added: [],
      removed: removedDescriptors.map((descriptor) => descriptor.id),
    }),
  );
}

// MARK: - 留痕与推送

interface Announcement {
  auditAction: "plugin_added" | "plugin_removed";
  detail: string;
  event: {
    action: PluginAction;
    plugin: string;
    added: CapabilityDescriptor[];
    removed: string[];
    capabilities: CapabilityDescriptor[];
  };
}

/**
 * 一次变化,两件事:**留痕**(NDJSON 日志 + 内存最近事件 + 推给在场的长连接)与
 * **推能力全集增量**(订阅者据此整份替换自己那张表)。
 *
 * 两件事都发,不是重复:审计回答"谁在什么时候装了什么"(事后复盘),
 * 能力事件回答"我现在能调什么"(此刻的投影)。壳可能只关心后者,审计日志只留前者。
 */
function announce(context: PluginHostContext, announcement: Announcement): void {
  context.audit.record({
    action: announcement.auditAction,
    detail: announcement.detail,
  });
  context.hub.broadcast({
    kind: "capability-set",
    at: new Date().toISOString(),
    capabilities: announcement.event,
  });
}

// MARK: - 报文零件

function manifestBrokenError(paths: KernelPaths, detail: string): WireError {
  return {
    code: ErrorCode.pluginLoadFailed,
    message: "插件清单读不了,已拒绝读写以免覆盖既有数据。",
    detail,
    guidance: {
      summary: "先把清单文件修好(或删掉它重新装插件),内核不会擅自重写它。",
      steps: [
        { description: "看看清单现在长什么样", command: `cat ${pluginManifestPath(paths)}` },
        { description: "确认没救就删掉它,然后重新逐个装", command: `rm ${pluginManifestPath(paths)}` },
      ],
      context: { manifest: pluginManifestPath(paths) },
    },
  };
}

function loadError(message: string, detail?: string, source?: string): WireError {
  return {
    code: ErrorCode.pluginLoadFailed,
    message,
    ...(detail === undefined ? {} : { detail }),
    guidance: {
      summary:
        "两种形态都收:①零依赖单文件 .ts —— 现场写完直接装,没有任何构建步骤;" +
        "②带 npm 依赖的目录 —— 交目录本身,内核在装载期替你 install + bundle 成单文件。",
      steps: [
        { description: "看插件协议与一个可直接抄的最小例子", command: "a2 plugin --help" },
        { description: "看看现在都装了什么", command: "a2 plugin list --json" },
      ],
      ...(source === undefined ? {} : { context: { path: source } }),
    },
  };
}

function statOf(target: string): ReturnType<typeof statSync> | undefined {
  try {
    return statSync(target);
  } catch {
    return undefined;
  }
}

function firstDuplicate(tools: PluginToolSpec[]): string | undefined {
  const seen = new Set<string>();
  for (const tool of tools) {
    if (seen.has(tool.name)) return tool.name;
    seen.add(tool.name);
  }
  return undefined;
}
