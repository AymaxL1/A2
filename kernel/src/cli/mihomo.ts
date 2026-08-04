// `a2 mihomo status|install|uninstall|upgrade` —— mihomo 的获取与共存面(06 票)。
//
// 与服务面同一种安排:**不经 UDS**(检测问的是文件系统、supervisor 与 external-controller,
// daemon 没跑的时候恰恰最需要它答话),但机读面与走 daemon 的命令一模一样,agent 看不出区别。
//
// 本文件不做任何裁定(那是 `src/mihomo/` 的事),只管:argv 怎么解析、结果怎么给人看。

import {
  MihomoChangeResultSchema,
  MihomoStatusResultSchema,
  type MihomoChangeResult,
  type MihomoStatusResult,
} from "../contract/wire.ts";
import { mihomoInstall, mihomoStatus, mihomoUninstall, mihomoUpgrade } from "../mihomo/manager.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { outcomeFromOpOutcome, type CommandOutcome } from "./outcome.ts";
import { MIHOMO_USAGE, helpOutcome, mihomoUsageOutcome } from "./usage.ts";

const RUNG_LABEL: Record<MihomoStatusResult["rung"], string> = {
  adopt_instance: "收编运行中的实例(进程生死归原托管方)",
  reuse_binary: "只读复用既有二进制(配置/数据/unit 自建)",
  managed_install: "按锁定版隔离安装(a2 自管)",
};

const PRESENCE_LABEL: Record<MihomoStatusResult["presence"], string> = {
  running_instance: "有跑着的实例",
  binary_only: "只有二进制,没有可达实例",
  absent: "本机没有 mihomo",
};

export async function mihomoCommand(args: string[], paths: KernelPaths): Promise<CommandOutcome> {
  const isolated = args.includes("--isolated");
  const [action, ...rest] = args.filter((arg) => arg !== "--isolated");

  if (action === undefined) {
    return mihomoUsageOutcome("mihomo 需要一个动作:status / install / uninstall / upgrade");
  }
  if (action === "help" || action === "-h" || action === "--help") return helpOutcome(MIHOMO_USAGE);
  if (rest.length > 0) {
    return mihomoUsageOutcome(`mihomo ${action} 不接受多余参数:${rest.join(" ")}`);
  }
  // `--isolated` 只对 install 有意义。默默忽略等于让人以为它生效了,所以照用法错处理。
  if (isolated && action !== "install") {
    return mihomoUsageOutcome(`--isolated 只对 install 有意义(收到:mihomo ${action} --isolated)`);
  }

  if (action === "status") {
    return outcomeFromOpOutcome(
      await mihomoStatus(paths),
      "mihomo.status",
      MihomoStatusResultSchema,
      renderStatus,
    );
  }
  if (action === "install") {
    return outcomeFromOpOutcome(
      await mihomoInstall(paths, { isolated }),
      "mihomo.install",
      MihomoChangeResultSchema,
      (result) => renderChange(result, "就位"),
    );
  }
  if (action === "uninstall") {
    return outcomeFromOpOutcome(
      await mihomoUninstall(paths),
      "mihomo.uninstall",
      MihomoChangeResultSchema,
      (result) => renderChange(result, "卸载"),
    );
  }
  if (action === "upgrade") {
    return outcomeFromOpOutcome(
      await mihomoUpgrade(paths),
      "mihomo.upgrade",
      MihomoChangeResultSchema,
      (result) => renderChange(result, "升级"),
    );
  }

  return mihomoUsageOutcome(`未知的 mihomo 动作:${action}`);
}

function renderStatus(status: MihomoStatusResult): string {
  const lines = [
    `mihomo 现状:${PRESENCE_LABEL[status.presence]} —— 阶梯档位:${RUNG_LABEL[status.rung]}`,
  ];
  if (status.instance) {
    const owner = status.instance.owner === "a2" ? "a2 自管" : "别人托管";
    lines.push(
      `  实例(${owner}):${status.instance.controller}` +
        `${status.instance.version ? ` 版本 ${status.instance.version}` : ""}` +
        `,能力位 [${status.instance.capabilities.join(", ") || "无"}]`,
    );
    if (status.instance.configFile) lines.push(`    来自配置:${status.instance.configFile}`);
  }
  if (status.foreignBinary) {
    lines.push(
      `  盘上的二进制:${status.foreignBinary.path}` +
        `${status.foreignBinary.version ? `(${status.foreignBinary.version})` : ""}`,
    );
  }
  lines.push(
    `  a2 自管:${status.provisioned ? "已就位" : "未就位"}(unit ${status.managed.label},${status.managed.state})`,
    `    unit 文件:${status.managed.unitPath}${status.managed.unitInstalled ? "" : "(尚不存在)"}`,
    `    二进制:${status.managed.binaryPath} —— ${describeBinary(status)}`,
    `    配置:${status.managed.configPath};控制端点:${status.managed.controller}`,
    `  兼容地板 ${status.compatibility.floor}:${status.compatibility.meets ? "达标" : `不达标(${status.compatibility.shortfalls.join("、")})`}`,
    `  锁定版本:${status.lockedVersion}(换版本只有 a2 mihomo upgrade 一条路)`,
  );
  if (status.fallback) lines.push(`  档位回退:${status.fallback.reason}`);
  if (status.skippedController) {
    lines.push(`  已跳过的非回环控制端点:${status.skippedController}(内核不对非本机端点发请求)`);
  }
  if (!status.provisioned && status.rung !== "adopt_instance") {
    lines.push("  让它就位(幂等):a2 mihomo install");
  }
  return lines.join("\n");
}

function describeBinary(status: MihomoStatusResult): string {
  switch (status.managed.binaryKind) {
    case "absent":
      return "尚未就位";
    case "downloaded":
      return `按锁定版下载的自管二进制${status.managed.version ? `(${status.managed.version})` : ""}`;
    case "reused":
      return `只读引用 → ${status.managed.binaryTarget ?? "(链接已断)"}${status.managed.version ? `(${status.managed.version})` : ""}`;
  }
}

/** 幂等的人类面:什么都没改时明说"本来就是这样",而不是假装干了活。 */
function renderChange(result: MihomoChangeResult, verb: string): string {
  const head =
    result.actions.length === 0
      ? `${verb}:已经是目标状态,本次未改动任何东西。`
      : `${verb}完成:${result.actions.join("、")}`;
  return [head, renderStatus(result.status)].join("\n");
}
