// 子命令的统一产出形态。
//
// agent-first 的取舍(ADR 0008 第 2 条):`--json` 时 stdout 上**只有一条 JSON 包封**
// (成功失败同一形状,agent 一次 JSON.parse 就能分支);无 `--json` 时才给人类一行散文,
// 且散文里的失败走 stderr —— 机读面永远不被散文污染。

import type { ResponseEnvelope, WireError } from "../contract/wire.ts";

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
  // 没有包封的命令(help/version/daemon run)在 --json 下也照常走人类面 —— 总比空 stdout 强。
  if (human === undefined) return;
  const text = `${human}\n`;
  if (outcome.exitCode === 0) process.stdout.write(text);
  else process.stderr.write(text);
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
