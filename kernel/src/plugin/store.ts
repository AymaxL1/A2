// 插件登记区:`<A2_HOME>/plugins/`(工件 + 一份清单),以及「一条记录 → 若干条能力」的适配。
//
// 为什么把工件**复制**进登记区,而不是记住源文件路径:
//   * 登记的是 **add 那一刻的 describe 快照**。源文件被改了、被删了、被移走了,已经装上的插件照常工作;
//     要让改动生效就重新 `a2 plugin add`(同名即替换)。于是"内核此刻提供哪些能力"这句话永远有确定答案。
//   * 12 票的目录插件会把 `bun build` 的产物登记进**同一个**登记区,运行期两种插件走完全相同的路径
//     (ADR 0011:「运行期全员单文件」)。本票先把这块地铺好,12 票只需换一种"怎么产出工件"。
//
// 清单损坏时的处置**照抄订阅清单那条**(07 票):**拒绝读写**,不覆盖 —— 盘上那份东西可能是用户
// 唯一能救回插件列表的线索,内核宁可什么都不装也不擅自重写它。

import { mkdirSync, readFileSync, readdirSync } from "node:fs";
import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";
import { CapabilityFailedError, type Capability } from "../capability/registry.ts";
import {
  PluginRecordSchema,
  type ErrorCode,
  type JsonValue,
  type PluginRecord,
} from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { callPluginTool } from "./protocol.ts";

/** 清单文件的形状。它就是一组 `PluginRecord`,外面套一层好让将来加字段不必改文件格式。 */
const ManifestSchema = z.object({
  plugins: z.array(PluginRecordSchema),
});

/** 登记区目录名与清单文件名(禁止各处各拼)。 */
export const PLUGIN_DIR_NAME = "plugins";
export const PLUGIN_MANIFEST_NAME = "plugins.json";
/** 登记区权限:与 `run/` 同一口径(0700,别的用户连列目录都不该能)。 */
export const PLUGIN_DIR_MODE = 0o700;

/** 插件名与工具名的取值域。**收得紧**是有意的:它们要拼进能力 id,而能力 id 是 agent 天天敲的东西。 */
export const PLUGIN_NAME_PATTERN = /^[a-z0-9][a-z0-9_-]*$/;

export function pluginsDir(paths: KernelPaths): string {
  return path.join(paths.home, PLUGIN_DIR_NAME);
}

export function pluginManifestPath(paths: KernelPaths): string {
  return path.join(pluginsDir(paths), PLUGIN_MANIFEST_NAME);
}

/** 能力 id 的命名规则(**唯一出处**):`plugin.<插件名>.<工具名>`。 */
export function capabilityIdFor(plugin: string, tool: string): string {
  return `${CAPABILITY_NAMESPACE}${plugin}.${tool}`;
}

/**
 * 插件能力的命名空间前缀。**内置能力永远不以它开头**(有断言守着),于是:
 *   * 插件永远撞不掉内置能力(命名空间隔离,而不是靠先来后到);
 *   * agent 一眼能看出"这条是插件给的"。
 */
export const CAPABILITY_NAMESPACE = "plugin.";

export type ManifestRead =
  | { ok: true; records: PluginRecord[] }
  | { ok: false; detail: string };

/**
 * 读清单。文件不在 = 一个插件都没装(**不是错**);内容坏了 = 拒绝读写并把细节交回去。
 * 同步读:文件只有几 KB,而 daemon 启动那一刻还没有任何并发,异步在这儿只会让装配变复杂。
 */
export function readPluginManifest(paths: KernelPaths): ManifestRead {
  const file = pluginManifestPath(paths);
  let raw: string;
  try {
    raw = readFileSync(file, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return { ok: true, records: [] };
    return { ok: false, detail: `读不了插件清单 ${file}:${String(error)}` };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    return { ok: false, detail: `插件清单 ${file} 不是合法 JSON:${String(error)}` };
  }

  const shaped = ManifestSchema.safeParse(parsed);
  if (!shaped.success) {
    return { ok: false, detail: `插件清单 ${file} 不符合契约:${shaped.error.message}` };
  }
  return { ok: true, records: shaped.data.plugins };
}

/** 写清单。**先写临时文件再改名**:写到一半断电也不会留下一份半截的清单(那会让下次启动一个插件都不装)。 */
export async function writePluginManifest(
  paths: KernelPaths,
  records: PluginRecord[],
): Promise<void> {
  const dir = pluginsDir(paths);
  await mkdir(dir, { recursive: true, mode: PLUGIN_DIR_MODE });
  const file = pluginManifestPath(paths);
  const staging = `${file}.staging`;
  await writeFile(staging, `${JSON.stringify({ plugins: records }, null, 2)}\n`, { mode: 0o600 });
  await rename(staging, file);
}

/** 建登记区(同步版,给 daemon 启动那一刻用)。 */
export function ensurePluginsDir(paths: KernelPaths): string {
  const dir = pluginsDir(paths);
  mkdirSync(dir, { recursive: true, mode: PLUGIN_DIR_MODE });
  return dir;
}

/** 暂存工件的文件名前缀(add 的中间态;正式工件永远不以点开头)。 */
export const STAGING_PREFIX = ".staging-";

/**
 * 清掉登记区里遗留的暂存工件(11 票 CR 尾款 d)。
 *
 * add 的路径上每一条失败分支都会自己删暂存件,但**进程被杀 / 掉电**时没有分支可走 ——
 * 于是登记区里会攒下 `.staging-xxx-<uuid>.ts` 这种谁也不会再看一眼的文件,一份 add 一个。
 * 启动时与每次 add 前各扫一次:装载面的写操作是串行的(见 `host.ts` 的 `serializeMutation`),
 * 所以这里绝不会误删"另一次 add 正在用的那份"。
 *
 * best-effort:扫不动(权限/竞态)就算了 —— 卫生问题不该拦住装载。
 */
export async function sweepStagingArtifacts(paths: KernelPaths): Promise<string[]> {
  const dir = pluginsDir(paths);
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return [];
  }
  const swept: string[] = [];
  for (const name of names) {
    if (!name.startsWith(STAGING_PREFIX)) continue;
    try {
      await rm(path.join(dir, name), { force: true });
      swept.push(name);
    } catch {
      // 删不掉就留着,下次再说。
    }
  }
  return swept;
}

/**
 * 清单里的记录逐条复验(11 票 CR 尾款 e)。
 *
 * 清单是盘上一个普通 JSON 文件,谁都能手改。schema 只管形状("name 是个非空字符串"),
 * 管不到**取值域** —— 而能力 id 是靠插件名与工具名拼出来的:一条名字带点的记录
 * (`{"name":"a.b"}` 配上工具 `c`)就能拼出与另一条插件的 id 一模一样的能力 id,
 * 于是注册表构造器在 daemon **启动那一刻**抛出重复 id —— **手改一个文件掀翻整个内核**。
 *
 * 处置:坏条目单条拒绝(重名同理,只认首条),好条目照常还原,问题写成一句话交给调用方
 * (daemon 落 stderr,`plugin list` 里那条记录直接不出现)。
 */
export function sanitizeRecords(records: PluginRecord[]): {
  records: PluginRecord[];
  problem?: string;
} {
  const seen = new Set<string>();
  const kept: PluginRecord[] = [];
  const rejected: string[] = [];

  for (const record of records) {
    if (!PLUGIN_NAME_PATTERN.test(record.name)) {
      rejected.push(`${JSON.stringify(record.name)}(插件名不合取值域)`);
      continue;
    }
    const badTool = record.tools.find((tool) => !PLUGIN_NAME_PATTERN.test(tool.name));
    if (badTool) {
      rejected.push(`${record.name}(工具名 ${JSON.stringify(badTool.name)} 不合取值域)`);
      continue;
    }
    if (new Set(record.tools.map((tool) => tool.name)).size !== record.tools.length) {
      rejected.push(`${record.name}(清单里有重名工具)`);
      continue;
    }
    if (seen.has(record.name)) {
      rejected.push(`${record.name}(重名条目,只认首条)`);
      continue;
    }
    seen.add(record.name);
    kept.push(record);
  }

  return {
    records: kept,
    ...(rejected.length === 0
      ? {}
      : {
          problem:
            `插件清单里有 ${rejected.length} 条记录没通过复验,已逐条拒绝(其余插件照常可用):` +
            rejected.join("、"),
        }),
  };
}

/**
 * 一条记录 → 若干条能力(**内置能力与插件工具在注册表眼里没有区别**,这正是 ADR 0004 那条
 * 「唯一调用面」的意义:仲裁、参数校验、事件广播全都不必为插件写第二遍)。
 *
 * 风险映射只有一条规则:**声明了 dangerous 就是 dangerous,没声明就是 `normal`**。
 * 不映射到 `safe` 的理由写在 `PluginToolSpecSchema` 的头注里(内核无从知道一个插件工具是不是只读)。
 */
export function pluginCapabilities(
  record: PluginRecord,
  env: Record<string, string | undefined> = process.env,
): Capability[] {
  return record.tools.map((tool) => ({
    descriptor: {
      id: capabilityIdFor(record.name, tool.name),
      risk: tool.dangerous ? ("dangerous" as const) : ("normal" as const),
      summary: tool.summary,
      parameters: tool.parameters,
    },
    handler: async (input: Record<string, JsonValue>) => {
      const outcome = await callPluginTool(record.artifact, tool.name, input, {
        env,
        // 工作目录固定在登记区:插件每次被调用看到的环境都一样(与 `--no-install` 一起,
        // 把"祖先目录里有没有 node_modules"这种会飘的因素钉死)。
        cwd: path.dirname(record.artifact),
      });
      if (outcome.ok) return outcome.value;
      // 注册表的铁律是 invoke 永不抛,而 handler 表达失败的唯一方式就是抛这个 ——
      // 插件的失败到这里被翻成与内置能力**同一种**结构化失败(code / detail / guidance 全保留)。
      throw new CapabilityFailedError(outcome.error.message, outcome.error.detail, {
        code: outcome.error.code as ErrorCode,
        ...(outcome.error.guidance === undefined ? {} : { guidance: outcome.error.guidance }),
      });
    },
  }));
}

/** 派生这条记录会占用的能力 id(卸载与 list 都用它,规则只写一次)。 */
export function capabilityIdsOf(record: Pick<PluginRecord, "name" | "tools">): string[] {
  return record.tools.map((tool) => capabilityIdFor(record.name, tool.name));
}
