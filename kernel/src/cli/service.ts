// `a2 service install|uninstall|status` —— 常驻服务的显式安装面(ADR 0008 第 6 条)。
//
// 这三条命令**不经 UDS**:服务面问的是系统 supervisor,而 daemon 没跑的时候恰恰是最需要它们答话的时候。
// 但机读面与走 daemon 的命令同一形状(`outcomeFromOpOutcome` 负责),agent 看不出区别。
// 15 票起这三条也是**面板的引导路径**(ADR 0012 的执行器白名单),所以机读面从面板可达这件事
// 不是附带的:面板拿到的就是 agent 拿到的那一条包封,没有第二套输出。
//
// 本文件不做任何平台判断与命令编排(那是 `src/service/` 的事),只管:argv 怎么解析、结果怎么给人看。

import {
  ServiceChangeResultSchema,
  ServiceStatusResultSchema,
  type ServiceChangeResult,
  type ServicePurgeReport,
  type ServiceStatusResult,
} from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { serviceInstall, serviceStatus, serviceUninstall } from "../service/manager.ts";
import { outcomeFromOpOutcome, type CommandOutcome } from "./outcome.ts";
import { SERVICE_USAGE, helpOutcome, serviceUsageOutcome } from "./usage.ts";

/** 把自身单文件拷进 `$A2_HOME/bin/a2` 并让 unit 指向拷贝(15 票 / ADR 0012「面板自足」)。 */
const COPY_TO_HOME_FLAG = "--copy-to-home";
/** 卸载之后继续拆 `com.a2.mihomo` 并删掉整个 `$A2_HOME`(17 票 / ADR 0012 第 6 条修订)。 */
const PURGE_FLAG = "--purge";
const FLAGS = [COPY_TO_HOME_FLAG, PURGE_FLAG];

export async function serviceCommand(args: string[], paths: KernelPaths): Promise<CommandOutcome> {
  // 三条命令一共只认这两个旗标(`--copy-to-home` 归 install、`--purge` 归 uninstall);
  // `--json` 更早一步就被 `main.ts` 摘掉了,走到这里的从来只有子命令自己的参数。
  const copyToHome = args.includes(COPY_TO_HOME_FLAG);
  const purge = args.includes(PURGE_FLAG);
  const [action, ...rest] = args.filter((arg) => !FLAGS.includes(arg));

  if (action === undefined) {
    return serviceUsageOutcome("service 需要一个动作:install / uninstall / status");
  }
  if (action === "help" || action === "-h" || action === "--help") {
    return helpOutcome(SERVICE_USAGE);
  }
  // 旗标之外一律不收 —— unit 名与域是内核写死的(只碰 `com.a2.kernel`),没有可调之处。
  if (rest.length > 0) {
    return serviceUsageOutcome(`service ${action} 不接受多余参数:${rest.join(" ")}`);
  }
  // `--copy-to-home` 只对 install 有意义。默默忽略等于让人以为它生效了,所以照用法错处理
  // (与 `a2 mihomo install --isolated` 同一口径)。
  if (copyToHome && action !== "install") {
    return serviceUsageOutcome(
      `${COPY_TO_HOME_FLAG} 只对 install 有意义(收到:service ${action} ${COPY_TO_HOME_FLAG})`,
    );
  }
  // 同一口径,而且这一条更要紧:`--purge` 会删掉整个 $A2_HOME —— 把它写在 install 后面还被
  // 默默忽略,人会以为自己已经清理过了。
  if (purge && action !== "uninstall") {
    return serviceUsageOutcome(
      `${PURGE_FLAG} 只对 uninstall 有意义(收到:service ${action} ${PURGE_FLAG})`,
    );
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
      await serviceInstall(paths, { copyToHome }),
      "service.install",
      ServiceChangeResultSchema,
      (result) => renderChange(result, "安装"),
    );
  }
  if (action === "uninstall") {
    return outcomeFromOpOutcome(
      await serviceUninstall(paths, { purge }),
      "service.uninstall",
      ServiceChangeResultSchema,
      (result) => renderChange(result, purge ? "卸载并清理" : "卸载", purge ? undefined : UNINSTALL_KEEPS_BIN),
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
    // unit 指着谁,是「托管的是不是我这份内核」的唯一答案(15 票);未安装时给的是 install 会写的那个。
    `  托管的可执行:${status.binPath}${status.unitInstalled ? "" : "(将写入)"}`,
    `  A2_HOME:${status.home}`,
  ];
  if (status.state !== "running") {
    lines.push("  装成系统托管常驻(幂等):a2 service install");
  }
  return lines.join("\n");
}

/**
 * 卸载的口径(15 票 / ADR 0012):**只拆 unit**。`$A2_HOME/bin/a2` 那份拷贝落在数据同侧
 * (与配置、日志、插件登记区同类),删它永远是另一个显式动作,不搭在"停服"这一条上顺手做掉。
 */
const UNINSTALL_KEEPS_BIN =
  "  注:只拆 unit —— $A2_HOME/bin/a2 那份内核拷贝(若有)保留不删,要清理请显式删它。";

/** 幂等的人类面:什么都没改时明说"本来就是这样",而不是假装干了活。 */
function renderChange(result: ServiceChangeResult, verb: string, note?: string): string {
  const head =
    result.actions.length === 0
      ? `${verb}:已经是目标状态,本次未改动任何东西。`
      : `${verb}完成:${result.actions.join("、")}`;
  const lines = [head, renderStatus(result.status)];
  if (result.purge !== undefined) lines.push(...renderPurge(result.purge));
  if (note !== undefined) lines.push(note);
  return lines.join("\n");
}

/**
 * `--purge` 的人类面对账:**具体到 label 与绝对路径**(与机读面同一份事实,不是另写一段散文)。
 * 最后那句红线不是客套 —— 它是这条命令边界的一部分,人在删完之后有权看见它。
 */
function renderPurge(purge: ServicePurgeReport): string[] {
  const lines = [
    purge.removedUnits.length === 0
      ? "  已移除的 unit:无(本来就不在)"
      : `  已移除的 unit:${purge.removedUnits.join("、")}`,
    purge.removedPaths.length === 0
      ? "  已删除的目录:无(本来就不在)"
      : `  已删除的目录:${purge.removedPaths.join("、")}`,
  ];
  lines.push("  清理范围恒为 com.a2.* 与 $A2_HOME —— 你自己装的 mihomo 与它的配置从不在内。");
  return lines;
}
