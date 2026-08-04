// `a2 service install|uninstall|status` —— 常驻服务的显式安装面(ADR 0008 第 6 条)。
//
// 这三条命令**不经 UDS**:服务面问的是系统 supervisor,而 daemon 没跑的时候恰恰是最需要它们答话的时候。
// 但机读面与走 daemon 的命令同一形状(`outcomeFromOpOutcome` 负责),agent 看不出区别。
//
// 本文件不做任何平台判断与命令编排(那是 `src/service/` 的事),只管:argv 怎么解析、结果怎么给人看。

import {
  ServiceChangeResultSchema,
  ServiceStatusResultSchema,
  type ServiceChangeResult,
  type ServiceStatusResult,
} from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { serviceInstall, serviceStatus, serviceUninstall } from "../service/manager.ts";
import { outcomeFromOpOutcome, type CommandOutcome } from "./outcome.ts";
import { SERVICE_USAGE, helpOutcome, serviceUsageOutcome } from "./usage.ts";

export async function serviceCommand(args: string[], paths: KernelPaths): Promise<CommandOutcome> {
  const [action, ...rest] = args;

  if (action === undefined) {
    return serviceUsageOutcome("service 需要一个动作:install / uninstall / status");
  }
  if (action === "help" || action === "-h" || action === "--help") {
    return helpOutcome(SERVICE_USAGE);
  }
  // 三条命令都不接受参数 —— unit 名与域是内核写死的(只碰 `com.a2.kernel`),没有可调之处。
  if (rest.length > 0) {
    return serviceUsageOutcome(`service ${action} 不接受多余参数:${rest.join(" ")}`);
  }

  if (action === "status") {
    return outcomeFromOpOutcome(
      await serviceStatus(paths),
      "service.status",
      ServiceStatusResultSchema,
      renderStatus,
    );
  }
  if (action === "install") {
    return outcomeFromOpOutcome(
      await serviceInstall(paths),
      "service.install",
      ServiceChangeResultSchema,
      (result) => renderChange(result, "安装"),
    );
  }
  if (action === "uninstall") {
    return outcomeFromOpOutcome(
      await serviceUninstall(paths),
      "service.uninstall",
      ServiceChangeResultSchema,
      (result) => renderChange(result, "卸载"),
    );
  }

  return serviceUsageOutcome(`未知的 service 动作:${action}`);
}

function renderStatus(status: ServiceStatusResult): string {
  const head =
    status.state === "running"
      ? `a2 服务运行中(supervisor ${status.supervisor},unit ${status.label},pid ${status.pid})`
      : status.state === "installed_not_running"
        ? `a2 服务已安装但未在运行(supervisor ${status.supervisor},unit ${status.label})`
        : `a2 服务未安装(supervisor ${status.supervisor})`;

  const lines = [
    head,
    `  unit 文件:${status.unitPath}${status.unitInstalled ? "" : "(尚不存在)"}`,
    `  A2_HOME:${status.home}`,
  ];
  if (status.state !== "running") {
    lines.push("  装成系统托管常驻(幂等):a2 service install");
  }
  return lines.join("\n");
}

/** 幂等的人类面:什么都没改时明说"本来就是这样",而不是假装干了活。 */
function renderChange(result: ServiceChangeResult, verb: string): string {
  const head =
    result.actions.length === 0
      ? `${verb}:已经是目标状态,本次未改动任何东西。`
      : `${verb}完成:${result.actions.join("、")}`;
  return [head, renderStatus(result.status)].join("\n");
}
