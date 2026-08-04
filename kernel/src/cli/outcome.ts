// 子命令的统一产出形态。
//
// agent-first 的取舍(ADR 0008 第 2 条):`--json` 时 stdout 上**只有一条 JSON 包封**
// (成功失败同一形状,agent 一次 JSON.parse 就能分支);无 `--json` 时才给人类一行散文,
// 且散文里的失败走 stderr —— 机读面永远不被散文污染。

import type { z } from "zod";
import { ExitCode, exitCodeForErrorCode } from "../contract/exit-codes.ts";
import {
  ErrorCode,
  failureResponse,
  successResponse,
  type OpOutcome,
  type ResponseEnvelope,
  type WireError,
} from "../contract/wire.ts";

export interface CommandOutcome {
  /** 机读结果。缺省表示该命令自己流式输出过(如 `daemon run` 的事件行),无需再打包封。 */
  envelope?: ResponseEnvelope;
  /** 人类面的一行文本(无 `--json` 时用)。 */
  human?: string;
  exitCode: number;
}

/** 按 `--json` 与成败把 outcome 写到 stdout/stderr。 */
export function emitOutcome(outcome: CommandOutcome, json: boolean): void {
  const { envelope, human } = outcome;
  if (json && envelope) {
    process.stdout.write(`${JSON.stringify(envelope)}\n`);
    return;
  }
  // 唯一没有包封的命令是 `daemon run`(它在 stdout 上流式吐 NDJSON 生命周期事件,不再补一条包封);
  // 它在 --json 下也照常走人类面 —— 总比空 stdout 强。其余命令一律有包封(help/version 也各有 result 契约)。
  if (human === undefined) return;
  const text = `${human}\n`;
  if (outcome.exitCode === 0) process.stdout.write(text);
  else process.stderr.write(text);
}

/**
 * 「daemon 应答 → 命令结果」的唯一模板(每条走 UDS 的子命令都长一个样,只有 result schema 与人类面说辞不同):
 *   * 失败包封 → 原样透传 + 按 `error.code` 定退出码(细因在报文里,退出码只做粗分类);
 *   * 成功但 result 不符契约 → 就地翻成 `bad_request` 失败包封 + 退出码 6
 *     (契约漂移必须在这里被发现,而不是让 agent 拿到怪 JSON 自己猜);
 *   * 成功且合契约 → 渲染人类面一行,退出码 0。
 *
 * `what` 只进错误文案(「daemon 返回的 <what> 结果不符合契约」),给人看是哪条命令漂了。
 */
export function outcomeFromEnvelope<T>(
  envelope: ResponseEnvelope,
  what: string,
  schema: z.ZodType<T>,
  render: (result: T) => string,
): CommandOutcome {
  if (!envelope.ok) {
    return {
      envelope,
      human: renderWireError(envelope.error),
      exitCode: exitCodeForErrorCode(envelope.error.code),
    };
  }

  const parsed = schema.safeParse(envelope.result);
  if (!parsed.success) {
    const failure = failureResponse(envelope.id, {
      code: ErrorCode.badRequest,
      message: `daemon 返回的 ${what} 结果不符合契约。`,
      detail: parsed.error.message,
    });
    return {
      envelope: failure,
      human: renderWireError(failure.error),
      exitCode: ExitCode.protocolError,
    };
  }

  return { envelope, human: render(parsed.data), exitCode: ExitCode.success };
}

/**
 * **本地**产出的 op 层结果 → 命令结果。包封在这里现拼,之后走的还是 `outcomeFromEnvelope` 那一套
 * (契约校验 + 退出码 + 人类面)—— 服务面不经 daemon(daemon 没跑时它更要能答话),
 * 但机读面必须与走 daemon 的命令**一模一样**,agent 不该看得出哪条命令去过 UDS。
 */
export function outcomeFromOpOutcome<T>(
  outcome: OpOutcome,
  what: string,
  schema: z.ZodType<T>,
  render: (result: T) => string,
): CommandOutcome {
  const id = crypto.randomUUID();
  const envelope = outcome.ok
    ? successResponse(id, outcome.result)
    : failureResponse(id, outcome.error);
  return outcomeFromEnvelope(envelope, what, schema, render);
}

/** 把结构化错误(含指引)渲染成人类面的多行文本 —— 与 JSON 面同源,不另写一套说辞。 */
export function renderWireError(error: WireError): string {
  const lines = [`错误(${error.code}):${error.message}`];
  if (error.detail) lines.push(`  细节:${error.detail}`);
  const guidance = error.guidance;
  if (guidance) {
    lines.push(guidance.summary);
    for (const step of guidance.steps) {
      lines.push(step.command ? `  - ${step.description}:${step.command}` : `  - ${step.description}`);
    }
    for (const [key, value] of Object.entries(guidance.context ?? {})) {
      lines.push(`  ${key}: ${value}`);
    }
  }
  return lines.join("\n");
}
