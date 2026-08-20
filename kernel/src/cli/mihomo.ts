// `a2 mihomo status|enable|disable|restart` —— 内嵌 mihomo 的托管面(14 票 / ADR 0014)。
//
// 通路分两种,agent 在机读面上看不出区别:
//   * status / enable / disable **不经 UDS**(问的是文件系统与只读探测,daemon 没跑时恰恰最需要它们答话);
//     enable / disable 落盘后会**尽力**通知 daemon 立即照办(`mihomo.apply`)—— daemon 不在就等它下次启动。
//   * restart **必须经 daemon**(子进程是 daemon 的孩子,别的进程替它重启不了),daemon 不在 → 退出码 4 + 指引。
//
// 本文件不做任何裁定(那是 `src/mihomo/` 的事),只管:argv 怎么解析、结果怎么给人看。

import {
  ErrorCode,
  MihomoChangeResultSchema,
  MihomoStatusResultSchema,
  Op,
  type MihomoChangeResult,
  type MihomoManagedMode,
  type MihomoStatusResult,
  type OpOutcome,
} from "../contract/wire.ts";
import { callKernel } from "../client/kernel-client.ts";
import { mihomoDisable, mihomoEnable, mihomoStatus } from "../mihomo/manager.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { outcomeFromEnvelope, outcomeFromOpOutcome, type CommandOutcome } from "./outcome.ts";
import { MIHOMO_USAGE, helpOutcome, mihomoUsageOutcome } from "./usage.ts";

const MODE_LABEL: Record<MihomoManagedMode, string> = {
  off: "未启用",
  observe: "observe(只读旁观本机已有 mihomo)",
  embedded: "embedded(A2 内置代理内核)",
};

const STATE_LABEL: Record<MihomoStatusResult["embedded"]["state"], string> = {
  running: "运行中",
  stopped: "未在运行",
  failed: "故障(已暂停重拉)",
};

export async function mihomoCommand(args: string[], paths: KernelPaths): Promise<CommandOutcome> {
  const modeArg = args.find((arg) => arg.startsWith("--mode="))?.slice("--mode=".length);
  const positional = args.filter((arg) => !arg.startsWith("--mode="));
  const [action, ...rest] = positional;

  if (action === undefined) {
    return mihomoUsageOutcome("mihomo 需要一个动作:status / enable / disable / restart");
  }
  if (action === "help" || action === "-h" || action === "--help") return helpOutcome(MIHOMO_USAGE);
  if (rest.length > 0) {
    return mihomoUsageOutcome(`mihomo ${action} 不接受多余参数:${rest.join(" ")}`);
  }
  if (modeArg !== undefined && action !== "enable") {
    return mihomoUsageOutcome(`--mode 只对 enable 有意义(收到:mihomo ${action} --mode=${modeArg})`);
  }

  if (action === "status") {
    return outcomeFromOpOutcome(
      await mihomoStatus(paths),
      "mihomo.status",
      MihomoStatusResultSchema,
      renderStatus,
    );
  }

  if (action === "enable") {
    // 08 票临时闸(2026-08-21 用户裁定):observe 的眼睛就是检测面,而检测面此刻停用了 ——
    // 留着这个入口等于发一副瞎子的眼镜:模式落了盘,却看不见任何外来实例,proxy 域也解析不出对象。
    // 于是**在参数层就拒**,并把唯一走得通的那条路写进指引(词表与落盘态仍保留 observe,修复后回归)。
    if (modeArg === "observe") {
      return mihomoUsageOutcome(
        "observe 模式暂不开放(检测面临时停用,修复后回归),当前请用 --mode=embedded",
      );
    }
    if (modeArg !== "embedded") {
      return mihomoUsageOutcome(
        `enable 需要 --mode=embedded(收到:${modeArg ?? "(缺省)"})`,
      );
    }
    return outcomeFromOpOutcome(
      await withDaemonApply(paths, await mihomoEnable(paths, modeArg)),
      "mihomo.enable",
      MihomoChangeResultSchema,
      (result) => renderChange(result, "启用"),
    );
  }

  if (action === "disable") {
    return outcomeFromOpOutcome(
      await withDaemonApply(paths, await mihomoDisable(paths)),
      "mihomo.disable",
      MihomoChangeResultSchema,
      (result) => renderChange(result, "停用"),
    );
  }

  if (action === "restart") {
    return outcomeFromEnvelope(
      await callKernel(paths, Op.mihomoRestart),
      "mihomo.restart",
      MihomoChangeResultSchema,
      (result) => renderChange(result, "重启"),
    );
  }

  return mihomoUsageOutcome(`未知的 mihomo 动作:${action}`);
}

/**
 * 落盘之后,尽力让 daemon「立即照办」并**采纳它的答案**:
 *   * daemon 不在场(`daemon_unreachable`)不是错误 —— 模式已落盘,它下次启动自然照办;
 *     status 的 guidance(态 G)会把「服务没跑」这件事说清楚。**只有这一种失败可以静默**。
 *   * daemon 在场且 apply 真失败(二进制被删、spawn 起不来…)→ 结构化错误**原样上抛**
 *     (CR M1:吞掉它等于 enable 以 0 退出零痕迹,与「拒绝即指引」相抵)。
 *   * apply 成功 → **整体采用它返回的 status**(CR H2:那才是拉起之后的实况;
 *     留着落盘时算的旧 status 会出现 actions 说 child_started 而 status 说 stopped 的自相矛盾),
 *     actions 则两段拼接(落盘动作 + 拉起动作,一次显式启用的完整账)。
 */
async function withDaemonApply(paths: KernelPaths, outcome: OpOutcome): Promise<OpOutcome> {
  if (!outcome.ok) return outcome;
  const local = outcome.result as MihomoChangeResult;
  const envelope = await callKernel(paths, Op.mihomoApply);
  if (!envelope.ok) {
    if (envelope.error?.code === ErrorCode.daemonUnreachable) return outcome;
    return { ok: false, error: envelope.error ?? { code: ErrorCode.mihomoOperationFailed, message: "mihomo.apply 失败且没有错误报文。" } };
  }
  const parsed = MihomoChangeResultSchema.safeParse(envelope.result);
  if (!parsed.success) return outcome;
  return {
    ok: true,
    result: { status: parsed.data.status, actions: [...local.actions, ...parsed.data.actions] },
  };
}

// MARK: - 人类面

function renderStatus(status: MihomoStatusResult): string {
  const lines = [`mihomo 托管模式:${MODE_LABEL[status.mode]}`];

  const e = status.embedded;
  lines.push(
    `  内置内核:${STATE_LABEL[e.state]}` +
      `${e.pid !== undefined ? `(pid ${e.pid})` : ""}` +
      `${e.state === "failed" ? `,连续失败 ${e.restartCount} 次` : ""}`,
    `    二进制:${e.binaryPath}${e.binaryVersion ? `(${e.binaryVersion})` : "(尚未下载)"};锁定版 ${e.lockedVersion}`,
    `    配置:${e.configPath}`,
    `    控制端点:${e.controller}${e.state === "running" ? `(${e.controllerReachable ? "可达" : "未应答"})` : ""}`,
  );
  if (e.lastError) lines.push(`    最近错误:${firstLine(e.lastError)}`);

  const f = status.foreign;
  if (f?.instance) {
    lines.push(
      `  外来实例(非 A2 管理,只读):${f.instance.controller}` +
        `${f.instance.version ? ` 版本 ${f.instance.version}` : ""}` +
        `${f.instance.reachable ? "" : "(不可达)"}`,
    );
    if (f.instance.configFile) lines.push(`    来自配置:${f.instance.configFile}`);
  }
  if (f?.binary) {
    lines.push(`  盘上的外来二进制:${f.binary.path}${f.binary.version ? `(${f.binary.version})` : ""}`);
  }
  if (f?.skippedController) {
    lines.push(`  已跳过的非回环控制端点:${f.skippedController}(内核不对非本机端点发请求)`);
  }
  if (status.legacyUnit) {
    lines.push("  检测到旧版 A2 的 com.a2.mihomo 服务 —— 启用 embedded 时会自动移除(审计留痕)。");
  }
  if (status.guidance) {
    lines.push(`  下一步:${status.guidance.summary}`);
    for (const step of status.guidance.steps) {
      lines.push(`    - ${step.description}${step.command ? `:${step.command}` : ""}`);
    }
  }
  return lines.join("\n");
}

function firstLine(text: string): string {
  const line = text.split("\n").find((entry) => entry.trim().length > 0) ?? "";
  return line.length > 120 ? `${line.slice(0, 117)}…` : line;
}

/** 幂等的人类面:什么都没改时明说"本来就是这样",而不是假装干了活。 */
function renderChange(result: MihomoChangeResult, verb: string): string {
  const head =
    result.actions.length === 0
      ? `${verb}:已经是目标状态,本次未改动任何东西。`
      : `${verb}完成:${result.actions.join("、")}`;
  return [head, renderStatus(result.status)].join("\n");
}
