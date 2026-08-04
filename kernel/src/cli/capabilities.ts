// `a2 capabilities list|describe|call` —— agent 用的能力面。
//
// 三条命令共用一条通路:解析 argv → 走 UDS 问 daemon → `outcomeFromEnvelope` 统一裹结果。
// 本文件**不做任何仲裁判断**:dangerous 该不该拦,由内核的注册表说了算(CLI 只是又一个客户端,
// 它的判断不算数)—— 所以这里看不到 risk 的分支,那是故意的。

import { callKernel } from "../client/kernel-client.ts";
import {
  CapabilityCallResultSchema,
  CapabilityDescribeResultSchema,
  CapabilityListResultSchema,
  Op,
  type CapabilityDescriptor,
  type JsonValue,
} from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { outcomeFromEnvelope, type CommandOutcome } from "./outcome.ts";
import { CAPABILITIES_USAGE, capabilitiesUsageOutcome, helpOutcome } from "./usage.ts";

export async function capabilitiesCommand(
  args: string[],
  paths: KernelPaths,
): Promise<CommandOutcome> {
  const [action, ...rest] = args;

  if (action === undefined) {
    return capabilitiesUsageOutcome("capabilities 需要一个动作:list / describe <id> / call <id>");
  }
  if (action === "help" || action === "-h" || action === "--help") {
    return helpOutcome(CAPABILITIES_USAGE);
  }

  if (action === "list") {
    if (rest.length > 0) return capabilitiesUsageOutcome(`list 不接受多余参数:${rest.join(" ")}`);
    return await listCommand(paths);
  }

  if (action === "describe") {
    const parsed = parseCapabilityId(rest);
    if ("error" in parsed) return capabilitiesUsageOutcome(parsed.error);
    return await describeCommand(paths, parsed.id);
  }

  if (action === "call") {
    const parsed = parseCallArgs(rest);
    if ("error" in parsed) return capabilitiesUsageOutcome(parsed.error);
    return await callCommand(paths, parsed.id, parsed.input);
  }

  return capabilitiesUsageOutcome(`未知的 capabilities 动作:${action}`);
}

async function listCommand(paths: KernelPaths): Promise<CommandOutcome> {
  return outcomeFromEnvelope(
    await callKernel(paths, Op.capabilitiesList),
    "capabilities.list",
    CapabilityListResultSchema,
    ({ capabilities }) =>
      capabilities.length === 0
        ? "(本内核未登记任何能力)"
        : capabilities.map((d) => `  ${d.id}  [${d.risk}]  ${d.summary}`).join("\n"),
  );
}

async function describeCommand(paths: KernelPaths, id: string): Promise<CommandOutcome> {
  return outcomeFromEnvelope(
    await callKernel(paths, Op.capabilitiesDescribe, { capability: id }),
    "capabilities.describe",
    CapabilityDescribeResultSchema,
    ({ descriptor }) => renderDescriptor(descriptor),
  );
}

async function callCommand(
  paths: KernelPaths,
  id: string,
  input: Record<string, JsonValue> | undefined,
): Promise<CommandOutcome> {
  const params: Record<string, JsonValue> =
    input === undefined ? { capability: id } : { capability: id, input };
  return outcomeFromEnvelope(
    await callKernel(paths, Op.capabilitiesCall, params),
    "capabilities.call",
    CapabilityCallResultSchema,
    ({ output }) => JSON.stringify(output, null, 2),
  );
}

function renderDescriptor(descriptor: CapabilityDescriptor): string {
  const lines = [`${descriptor.id}  [${descriptor.risk}]`, `  ${descriptor.summary}`];
  if (descriptor.parameters.length === 0) {
    lines.push("  (无入参)");
    return lines.join("\n");
  }
  lines.push("  参数:");
  for (const spec of descriptor.parameters) {
    const allowed = spec.allowedValues ? `,取值 ${spec.allowedValues.join("|")}` : "";
    lines.push(
      `    ${spec.name}: ${spec.type}${spec.required ? "(必填)" : "(可选)"}${allowed} —— ${spec.description}`,
    );
  }
  return lines.join("\n");
}

type Parsed<T> = T | { error: string };

/**
 * `describe` 的参数:恰好一个裸 token 当能力 id。
 * 未知选项一律报错(而不是忽略):agent 打错一个旗标,应该当场知道,而不是拿到一个"好像成了"的结果。
 */
function parseCapabilityId(args: string[]): Parsed<{ id: string }> {
  let id: string | undefined;
  for (const arg of args) {
    if (arg.startsWith("--")) return { error: `未知选项:${arg}` };
    if (id !== undefined) return { error: `多余参数:${arg}` };
    id = arg;
  }
  if (id === undefined) return { error: "缺少能力 id" };
  return { id };
}

/** `call` 的参数:一个能力 id + 可选的 `--input <JSON 对象>`。 */
function parseCallArgs(
  args: string[],
): Parsed<{ id: string; input: Record<string, JsonValue> | undefined }> {
  let id: string | undefined;
  let raw: string | undefined;

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index] as string;
    if (arg === "--input") {
      const value = args[index + 1];
      // 不吞旗标当值:`--input --json` 是"忘了给值",不是"值就叫 --json"。
      if (value === undefined || value.startsWith("--")) return { error: "--input 后面缺少 JSON 值" };
      raw = value;
      index += 1;
      continue;
    }
    if (arg.startsWith("--")) return { error: `未知选项:${arg}` };
    if (id !== undefined) return { error: `多余参数:${arg}(入参请用 --input '<JSON>')` };
    id = arg;
  }

  if (id === undefined) return { error: "缺少能力 id" };
  if (raw === undefined) return { id, input: undefined };

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    return { error: `--input 不是合法 JSON:${String(error)}` };
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return { error: "--input 必须是一个 JSON 对象(参数按名取值)" };
  }
  return { id, input: parsed as Record<string, JsonValue> };
}
