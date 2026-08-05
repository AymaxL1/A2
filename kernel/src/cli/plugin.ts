// `a2 plugin add|list|remove` —— 插件的装载面(11 票)。
//
// 与 `capabilities` 面同一条通路:解析 argv → 走 UDS 问 daemon → `outcomeFromEnvelope` 统一裹结果。
// 本文件**不做任何装载判断**:合不合法、装不装得上,由 daemon 里的插件宿主说了算(CLI 只是又一个客户端)。
//
// 唯一一件 CLI 必须自己做的事:**把路径展开成绝对路径**。daemon 的工作目录与 agent 敲命令的目录
// 不是一回事(它多半是被 launchd/systemd 拉起来的),相对路径发过去会指到别处 —— 而这个错误
// 表现为"文件不存在",最难查。展开在这里做,是因为**只有这个进程知道 agent 站在哪儿**。
//
// 装载之后怎么调?**`a2 capabilities call plugin.<插件名>.<工具名>`** —— 与内置能力同一个调用面
// (ADR 0004)。所以本文件没有 `a2 plugin call`:多一条平行的调用面,就多一处仲裁可能被绕过的地方。

import path from "node:path";
import { callKernel } from "../client/kernel-client.ts";
import {
  Op,
  PluginChangeResultSchema,
  PluginListResultSchema,
  type PluginChangeResult,
  type PluginListResult,
} from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { outcomeFromEnvelope, type CommandOutcome } from "./outcome.ts";
import { PLUGIN_USAGE, helpOutcome, pluginUsageOutcome } from "./usage.ts";

export async function pluginCommand(
  args: string[],
  paths: KernelPaths,
): Promise<CommandOutcome> {
  const [action, ...rest] = args;

  if (action === undefined) {
    return pluginUsageOutcome("plugin 需要一个动作:add <路径> / list / remove <名字>");
  }
  if (action === "help" || action === "-h" || action === "--help") {
    return helpOutcome(PLUGIN_USAGE);
  }

  if (action === "list") {
    if (rest.length > 0) return pluginUsageOutcome(`list 不接受多余参数:${rest.join(" ")}`);
    return outcomeFromEnvelope(
      await callKernel(paths, Op.pluginList),
      "plugin.list",
      PluginListResultSchema,
      renderList,
    );
  }

  if (action === "add") {
    const parsed = parseAddArgs(rest);
    if ("error" in parsed) return pluginUsageOutcome(parsed.error);
    return outcomeFromEnvelope(
      await callKernel(paths, Op.pluginAdd, {
        // 展开成绝对路径:daemon 与 agent 的 cwd 不是一回事(见文件头)。
        path: path.resolve(parsed.path),
        ...(parsed.name === undefined ? {} : { name: parsed.name }),
      }),
      "plugin.add",
      PluginChangeResultSchema,
      renderChange,
    );
  }

  if (action === "remove") {
    const parsed = parsePluginName(rest);
    if ("error" in parsed) return pluginUsageOutcome(parsed.error);
    return outcomeFromEnvelope(
      await callKernel(paths, Op.pluginRemove, { plugin: parsed.name }),
      "plugin.remove",
      PluginChangeResultSchema,
      renderChange,
    );
  }

  return pluginUsageOutcome(`未知的 plugin 动作:${action}`);
}

// MARK: - 人类面
//
// 人类面把**下一步能敲什么**直接写出来(能力 id 全列),而不是让人自己按命名规则拼。

function renderList(result: PluginListResult): string {
  if (result.plugins.length === 0) {
    return `(本内核没有登记任何插件;登记区:${result.directory})`;
  }
  const lines = [`登记区:${result.directory}`];
  for (const plugin of result.plugins) {
    lines.push(`  ${plugin.name}  ${plugin.artifact}  (装于 ${plugin.addedAt})`);
    for (const tool of plugin.tools) {
      const risk = tool.dangerous ? "dangerous" : "normal";
      lines.push(`    plugin.${plugin.name}.${tool.name}  [${risk}]  ${tool.summary}`);
    }
  }
  return lines.join("\n");
}

function renderChange(result: PluginChangeResult): string {
  const verb = result.action === "removed" ? "已卸载" : result.action === "replaced" ? "已替换" : "已装上";
  const lines = [`${verb}插件 ${result.plugin.name}(工件 ${result.plugin.artifact})`];
  if (result.removed.length > 0) lines.push(`  注销能力:${result.removed.join("、")}`);
  for (const descriptor of result.added) {
    lines.push(`  ${descriptor.id}  [${descriptor.risk}]  ${descriptor.summary}`);
  }
  if (result.added.length > 0) {
    lines.push(`  调用:a2 capabilities call ${result.added[0]!.id} --input '{…}' --json`);
  }
  return lines.join("\n");
}

// MARK: - argv

type Parsed<T> = T | { error: string };

function parseAddArgs(args: string[]): Parsed<{ path: string; name?: string }> {
  let target: string | undefined;
  let name: string | undefined;

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] as string;
    if (arg === "--name") {
      const value = args[index + 1];
      // 不吞旗标当值:`--name --json` 是"忘了给值",不是"名字就叫 --json"。
      if (value === undefined || value.startsWith("--")) return { error: "--name 后面缺少值" };
      name = value;
      index += 1;
      continue;
    }
    if (arg.startsWith("--")) return { error: `未知选项:${arg}` };
    if (target !== undefined) return { error: `多余参数:${arg}` };
    target = arg;
  }

  if (target === undefined) return { error: "缺少插件文件路径" };
  return name === undefined ? { path: target } : { path: target, name };
}

function parsePluginName(args: string[]): Parsed<{ name: string }> {
  let name: string | undefined;
  for (const arg of args) {
    if (arg.startsWith("--")) return { error: `未知选项:${arg}` };
    if (name !== undefined) return { error: `多余参数:${arg}` };
    name = arg;
  }
  if (name === undefined) return { error: "缺少插件名" };
  return { name };
}
