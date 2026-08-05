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
import { copyFile, mkdir, rename, rm } from "node:fs/promises";
import path from "node:path";
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
  PLUGIN_DIR_MODE,
  PLUGIN_NAME_PATTERN,
  capabilityIdsOf,
  ensurePluginsDir,
  pluginCapabilities,
  pluginManifestPath,
  pluginsDir,
  readPluginManifest,
  writePluginManifest,
} from "./store.ts";

/** 插件工件允许的扩展名。目录插件(带依赖)是 12 票的活儿,本票遇到它给指引、不半吊子支持。 */
const ARTIFACT_EXTENSIONS = [".ts", ".js"];

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
 * 同名记录只认第一条(清单被手改坏时的兜底):重复 id 会让注册表构造器抛,而**启动不该被外来数据掀翻**。
 */
export function restorePlugins(
  paths: KernelPaths,
  env: Record<string, string | undefined> = process.env,
): RestoredPlugins {
  const read = readPluginManifest(paths);
  if (!read.ok) return { records: [], capabilities: [], problem: read.detail };

  const seen = new Set<string>();
  const records: PluginRecord[] = [];
  const skipped: string[] = [];
  for (const record of read.records) {
    if (seen.has(record.name)) {
      skipped.push(record.name);
      continue;
    }
    seen.add(record.name);
    records.push(record);
  }

  const capabilities = records.flatMap((record) => pluginCapabilities(record, env));
  return {
    records,
    capabilities,
    ...(skipped.length === 0
      ? {}
      : { problem: `插件清单里有重名条目,已只保留首条:${skipped.join("、")}` }),
  };
}

// MARK: - plugin.list

export function listPlugins(context: PluginHostContext): OpOutcome {
  const read = readPluginManifest(context.paths);
  if (!read.ok) return opFailure(manifestBrokenError(context.paths, read.detail));
  return opSuccess(
    payload({ directory: pluginsDir(context.paths), plugins: read.records }),
  );
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
export async function addPlugin(
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
    return opFailure(loadError(`插件文件不存在:${source}`, undefined, source));
  }
  if (stat.isDirectory()) {
    return opFailure(
      loadError(
        `${source} 是一个目录。本版内核只登记**零依赖单文件**插件(.ts / .js)。`,
        "带 npm 依赖的目录插件要在装载期 install + bundle 成单文件工件 —— 那是 12 票的活儿,尚未交付。",
        source,
      ),
    );
  }
  const extension = path.extname(source);
  if (!ARTIFACT_EXTENSIONS.includes(extension)) {
    return opFailure(
      loadError(
        `插件文件的扩展名必须是 ${ARTIFACT_EXTENSIONS.join(" 或 ")}(收到 ${JSON.stringify(extension)})。`,
        undefined,
        source,
      ),
    );
  }

  const name = params.name ?? path.basename(source, extension);
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
  await mkdir(directory, { recursive: true, mode: PLUGIN_DIR_MODE });
  const artifact = path.join(directory, `${name}${extension}`);
  const staging = path.join(directory, `.staging-${name}-${crypto.randomUUID()}${extension}`);

  try {
    await copyFile(source, staging);
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
  const previous = read.records.find((record) => record.name === name);
  try {
    await rename(staging, artifact);
  } catch (error) {
    await rm(staging, { force: true }).catch(() => {});
    return opFailure(loadError(`工件就位失败:${String(error)}`, undefined, source));
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

  const records = read.records.filter((entry) => entry.name !== name);
  records.push(record);
  try {
    await writePluginManifest(context.paths, records);
  } catch (error) {
    // 清单没落盘 = 重启就没了。与其留一个"这次能用、下次消失"的幽灵,不如当场退回去。
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
      `装载零闸:本次没有经过任何确认(ADR 0011)。`,
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

// MARK: - plugin.remove

export async function removePlugin(
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
      summary: "插件 = 一个零依赖单文件 .ts,现场写完直接装,不需要任何构建步骤。",
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
