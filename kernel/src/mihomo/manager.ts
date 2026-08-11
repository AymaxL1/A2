// `a2 mihomo status|install|uninstall|upgrade` 的实体:把「本机 mihomo 怎么就位」收敛到一条命令。
//
// 深模块的边界与服务面一样:调用方(CLI)只拿到一个 `OpOutcome`。检测、档位裁定、下载校验、
// unit 编排、兼容地板与全部失败指引都在这一层里消化掉。
//
// **本文件里没有任何一条代码路径会去停/重启/杀/配置一个不属于 a2 的 mihomo。** 这不是靠自觉:
//   * 能对进程动手的只有 `createSupervisor(plan)`,而 plan 恒是 `com.a2.mihomo` 那一份;
//   * 对别人的实例只有 `controller.ts` 里那两条只读 GET;
//   * 凡是"只能对自管那份做"的动作(升级、卸载),对方不是自管就返回 `mihomo_not_managed`;
//   * 别人的实例在跑而 a2 未就位时,`install` 直接 `mihomo_foreign_instance_running` 拒绝、零改动
//     (2026-08-12 用户裁定:只读状态,不去接管;收编档随之废除)。
// 「数据面不随控制面起落」的另一半在 unit 层:`com.a2.mihomo` 与 `com.a2.kernel` 是两个独立 unit,
// `a2 service uninstall` 碰不到前者(它的 plan 里根本没有那个 label)。

import path from "node:path";
import {
  ErrorCode,
  opFailure,
  opSuccess,
  type MihomoAction,
  type MihomoStatusResult,
  type OpOutcome,
  type WireError,
} from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { convergeUnit, removeUnit } from "../service/converge.ts";
import {
  createSupervisor,
  SupervisorCommandError,
  type Supervisor,
  type UnitAction,
} from "../service/supervisor.ts";
import {
  MIHOMO_SERVICE_LABEL,
  MIHOMO_STDERR_LOG_NAME,
  mihomoServicePlan,
  resolveSupervisorKind,
  type ServicePlan,
} from "../service/unit.ts";
import { probeController } from "./controller.ts";
import { collectFacts, type MihomoFacts } from "./detect.ts";
import { decideLadder, type LadderDecision } from "./ladder.ts";
import {
  downloadLockedBinary,
  ensureConfig,
  ensureDataDir,
  linkForeignBinary,
  MihomoOperationError,
} from "./install.ts";
import { resolveDesiredConfig } from "../proxy/config.ts";
import { mihomoLayout, readSecretOf, resolveScanInputs, type MihomoLayout } from "./paths.ts";
import { compareVersions, MIHOMO_LOCKED_VERSION } from "./pin.ts";

/** 等"自管实例的控制端点真的应答"的上限。与内核 install 同一条口径:有 pid ≠ 能用。 */
const CONTROLLER_READY_TIMEOUT_MS = 5000;
const CONTROLLER_POLL_MS = 100;

interface MihomoContext {
  paths: KernelPaths;
  layout: MihomoLayout;
  plan: ServicePlan;
  supervisor: Supervisor;
  env: Record<string, string | undefined>;
}

export interface MihomoInstallOptions {
  /** 人类显式要求隔离安装(不复用别人的实例/二进制)。 */
  isolated?: boolean;
}

export async function mihomoStatus(paths: KernelPaths): Promise<OpOutcome> {
  return await withMihomo(paths, async (ctx) => {
    const facts = await collect(ctx);
    return opSuccess(statusResult(ctx, facts, decideLadder(facts)));
  });
}

export async function mihomoInstall(
  paths: KernelPaths,
  options: MihomoInstallOptions = {},
): Promise<OpOutcome> {
  return await withMihomo(paths, async (ctx) => {
    const facts = await collect(ctx);
    const decision = decideLadder(facts, options);

    // ⓪ 别人的实例在跑,而 a2 这边还没就位 → **结构化拒绝,零改动**(用户裁定:只读,不接管)。
    //    不收编(那一档已废除),也不默默在人家旁边再起一份 —— 端口打架该由人来权衡,不该由内核代劳。
    //    `--isolated` 是唯一的逃生门;a2 已就位时不走这道闸(维持现状,见 ladder.ts 文件头)。
    if (decision.foreignInstanceRunning && !decision.provisioned && !options.isolated) {
      return opFailure(foreignRunningError(ctx, facts));
    }

    const actions: MihomoAction[] = [];
    if (await ensureDataDir(ctx.layout)) actions.push("data_dir_created");
    // 配置内容由 07 票的配置面算(可调项 + 当前激活订阅);install 只负责"把它落到位"。
    const desired = await resolveDesiredConfig(ctx.layout, ctx.env);
    if (await ensureConfig(ctx.layout, desired.text)) actions.push("config_written");

    if (decision.rung === "reuse_binary") {
      // ① 只读复用:落点上放一个指向那份二进制的符号链接,真身一个字节都不碰。
      const target = facts.managed.binaryTarget ?? facts.foreignBinary?.path;
      if (!target) return opFailure(noBinaryError(ctx));
      if (await linkForeignBinary(ctx.layout, target)) actions.push("binary_linked");
    } else if (facts.managed.binaryKind !== "downloaded") {
      // ② 脚本安装:只在**还没有自管二进制**时下载。已经有了就绝不在 install 里换版本 ——
      //    换版本只有 `a2 mihomo upgrade` 一条路(「升级永远显式」)。
      await downloadLockedBinary(ctx.layout, ctx.env);
      actions.push("binary_downloaded");
    }

    const converged = await convergeUnit(ctx.plan, ctx.supervisor);
    actions.push(...mihomoActions(converged.actions));
    if (converged.state.pid === undefined) return opFailure(notRunningError(ctx));
    if (!(await settleControllerReady(ctx))) return opFailure(notAnsweringError(ctx));

    const after = await collect(ctx);
    return opSuccess({ status: statusResult(ctx, after, decideLadder(after, options)), actions });
  });
}

/**
 * 卸掉 **a2 自己那份**(unit + 进程)。**有意保留**二进制、配置与数据目录:
 * 它们是数据面资产(缓存、geo 库、你的 secret),删不删该由人类决定,路径在报文里给出。
 * 别人那份实例这条命令一根汗毛都碰不到 —— 它压根不在 `com.a2.mihomo` 这个 plan 里。
 */
export async function mihomoUninstall(paths: KernelPaths): Promise<OpOutcome> {
  return await withMihomo(paths, async (ctx) => {
    const removed = await removeUnit(ctx.plan, ctx.supervisor);
    if (removed.state.pid !== undefined) return opFailure(stillRunningError(ctx, removed.state.pid));
    const actions = mihomoActions(removed.actions);
    const facts = await collect(ctx);
    return opSuccess({ status: statusResult(ctx, facts, decideLadder(facts)), actions });
  });
}

/**
 * 显式升级 —— **本内核唯一会换 mihomo 版本的地方**,而且只换到 `MIHOMO_LOCKED_VERSION`。
 * 对象只能是 a2 自管的下载版:只读复用来的二进制不归 a2 管,一律 `mihomo_not_managed`。
 */
export async function mihomoUpgrade(paths: KernelPaths): Promise<OpOutcome> {
  return await withMihomo(paths, async (ctx) => {
    const facts = await collect(ctx);
    if (facts.managed.binaryKind !== "downloaded") {
      return opFailure(notManagedError(ctx, facts));
    }
    if (facts.managed.version && compareVersions(facts.managed.version, MIHOMO_LOCKED_VERSION) === 0) {
      return opSuccess({ status: statusResult(ctx, facts, decideLadder(facts)), actions: [] });
    }

    const actions: MihomoAction[] = [];
    await downloadLockedBinary(ctx.layout, ctx.env);
    actions.push("binary_upgraded");

    // 换了文件不等于换了进程:跑着的那个还攥着旧 inode,必须显式重启才吃到新版本。
    const state = await ctx.supervisor.query();
    if (state.pid !== undefined) {
      await ctx.supervisor.restart();
      actions.push("mihomo_restarted");
      await settleControllerReady(ctx);
    }

    const after = await collect(ctx);
    return opSuccess({ status: statusResult(ctx, after, decideLadder(after)), actions });
  });
}

// MARK: - 骨架

async function withMihomo(
  paths: KernelPaths,
  body: (ctx: MihomoContext) => Promise<OpOutcome>,
): Promise<OpOutcome> {
  const choice = resolveSupervisorKind();
  if (!choice.ok) return opFailure(unsupportedPlatformError(choice.reason, paths));

  const env = process.env;
  const layout = mihomoLayout(paths, env);
  const plan = mihomoServicePlan(choice.kind, paths, {
    binaryPath: layout.binaryPath,
    dataDir: layout.dataDir,
    configPath: layout.configPath,
  });
  const ctx: MihomoContext = { paths, layout, plan, supervisor: createSupervisor(plan), env };

  try {
    return await body(ctx);
  } catch (error) {
    if (error instanceof MihomoOperationError) return opFailure(error.toWireError());
    if (error instanceof SupervisorCommandError) return opFailure(commandFailedError(ctx, error));
    return opFailure({
      code: ErrorCode.mihomoOperationFailed,
      message: "mihomo 操作失败。",
      detail: String(error),
      guidance: {
        summary: "确认 A2_HOME 可写、unit 目录可写后重试(幂等)。",
        steps: [
          { description: "看当前现状", command: "a2 mihomo status --json" },
          {
            description: "看 mihomo 的错误日志",
            command: `tail -n 50 ${path.join(ctx.plan.logDir, MIHOMO_STDERR_LOG_NAME)}`,
          },
        ],
        context: { home: paths.home, dataDir: layout.dataDir },
      },
    });
  }
}

async function collect(ctx: MihomoContext): Promise<MihomoFacts> {
  return await collectFacts(ctx.layout, resolveScanInputs(ctx.env), ctx.plan, ctx.supervisor);
}

/** unit 层的通用动作词 → mihomo 面的词表。 */
function mihomoActions(actions: UnitAction[]): MihomoAction[] {
  return actions.map((action) =>
    action === "process_started"
      ? "mihomo_started"
      : action === "process_restarted"
        ? "mihomo_restarted"
        : action,
  );
}

/** 轮询到自管实例的控制端点真的应答为止(有 pid ≠ 能用,与内核 install 同一口径)。 */
async function settleControllerReady(ctx: MihomoContext): Promise<boolean> {
  const secret = await readSecretOf(ctx.layout.configPath);
  const deadline = Date.now() + CONTROLLER_READY_TIMEOUT_MS;
  for (;;) {
    if ((await probeController(ctx.layout.controller, secret)).reachable) return true;
    if (Date.now() >= deadline) return false;
    await Bun.sleep(CONTROLLER_POLL_MS);
  }
}

function statusResult(
  ctx: MihomoContext,
  facts: MihomoFacts,
  decision: LadderDecision,
): MihomoStatusResult {
  const managed = facts.managed;
  return {
    presence: decision.presence,
    rung: decision.rung,
    provisioned: decision.provisioned,
    lockedVersion: MIHOMO_LOCKED_VERSION,
    ...(decision.instance ? { instance: decision.instance } : {}),
    ...(facts.foreignBinary ? { foreignBinary: facts.foreignBinary } : {}),
    managed: {
      label: MIHOMO_SERVICE_LABEL,
      supervisor: ctx.plan.kind,
      unitPath: ctx.plan.unitPath,
      unitInstalled: managed.unitInstalled,
      state:
        managed.state.pid !== undefined
          ? "running"
          : managed.unitInstalled || managed.state.registered
            ? "installed_not_running"
            : "not_installed",
      ...(managed.state.pid === undefined ? {} : { pid: managed.state.pid }),
      binaryKind: managed.binaryKind,
      binaryPath: managed.binaryPath,
      ...(managed.binaryTarget ? { binaryTarget: managed.binaryTarget } : {}),
      ...(managed.version ? { version: managed.version } : {}),
      configPath: ctx.layout.configPath,
      dataDir: ctx.layout.dataDir,
      controller: ctx.layout.controller,
    },
    compatibility: decision.compatibility,
    ...(decision.fallback ? { fallback: decision.fallback } : {}),
    ...(facts.skipped ? { skippedController: facts.skipped.address } : {}),
    home: ctx.paths.home,
  };
}

// MARK: - 拒绝即指引

/**
 * **别人的 mihomo 在跑,而 a2 还没就位** —— 结构化拒绝,零改动(用户裁定:只读状态,不去接管)。
 *
 * 这条报文要同时说清三件事,少一件人就不知道下一步该干嘛:
 *   ① 我看见了什么(哪个端点、哪份配置、什么版本)—— 都是刚探到的事实,不是猜的;
 *   ② 我**没有做**什么(没收编、没起进程、没写一个字节)—— 「零改动」必须明说,否则人会去查有没有残留;
 *   ③ 想继续的两条路各自的代价 —— 就这么用(a2 只读它),或者显式并存(端口要你自己避开)。
 */
function foreignRunningError(ctx: MihomoContext, facts: MihomoFacts): WireError {
  const found = facts.foreign;
  const controller = found?.target ?? "(未发现)";
  const configFile = found?.configFile;
  const version = found?.probe.version;
  return {
    code: ErrorCode.mihomoForeignInstanceRunning,
    message: "本机已经有一个别人托管的 mihomo 在跑,a2 不接管它,本次未做任何改动。",
    detail:
      `可达的 external-controller:${controller}` +
      `${version ? `(版本 ${version})` : ""}` +
      `${configFile ? `;来自配置 ${configFile}` : ""}。` +
      "内核对它只有两条只读 GET,既不收编、也不在它旁边自作主张再起一份。",
    guidance: {
      summary:
        "机器上要不要同时跑两份 mihomo,是一个有代价的决定(两套入站端口、两份配置)—— 该由你来做,不由内核代劳。",
      steps: [
        {
          description: "就这么用:a2 只读它的状态(模式/节点/端口),配置由你自己或 agent 去改那份配置文件",
          command: "a2 mihomo status --json",
        },
        {
          description: "或者显式让 a2 装一份自管实例与之并存(入站端口需你自行避开冲突)",
          command: "a2 mihomo install --isolated --json",
        },
      ],
      context: {
        controller,
        ...(configFile ? { configFile } : {}),
        ...(version ? { version } : {}),
        home: ctx.paths.home,
      },
    },
  };
}

/** 这件事只能对自管那份做,而当前那份不归 a2 管 —— 红线的报文投影。 */
function notManagedError(ctx: MihomoContext, facts: MihomoFacts): WireError {
  const kind = facts.managed.binaryKind;
  const why =
    kind === "reused"
      ? `a2 落点上的是一个指向 ${facts.managed.binaryTarget ?? "别处"} 的只读引用 —— 那份二进制不是内核装的,内核也不会去改它。`
      : "a2 还没有自管的 mihomo 二进制(还没就位)。";
  return {
    code: ErrorCode.mihomoNotManaged,
    message: "升级只对 a2 自管的 mihomo 有效,当前这份不归 a2 管。",
    detail: why,
    guidance: {
      summary: "要让 a2 管版本,先让它拥有一份自己的二进制(隔离安装);别人的那份请由它的主人升级。",
      steps: [
        { description: "看清楚现在是哪一档、各自是什么", command: "a2 mihomo status --json" },
        {
          description: "让 a2 按锁定版装一份自管实例(此后 upgrade 才有对象)",
          command: "a2 mihomo install --isolated",
        },
      ],
      context: {
        binaryKind: kind,
        binaryPath: facts.managed.binaryPath,
        lockedVersion: MIHOMO_LOCKED_VERSION,
        home: ctx.paths.home,
      },
    },
  };
}

function noBinaryError(ctx: MihomoContext): WireError {
  return {
    code: ErrorCode.mihomoOperationFailed,
    message: "复用档成立但找不到可复用的二进制(它在检测之后消失了?)。",
    detail: "重新检测一次再决定走哪一档。",
    guidance: {
      summary: "现状变了,重跑一次检测。",
      steps: [
        { description: "重新检测", command: "a2 mihomo status --json" },
        { description: "或直接让 a2 按锁定版隔离安装", command: "a2 mihomo install --isolated" },
      ],
      context: { home: ctx.paths.home },
    },
  };
}

function notRunningError(ctx: MihomoContext): WireError {
  return {
    code: ErrorCode.mihomoOperationFailed,
    message: "unit 已装好,但 mihomo 进程没能起来。",
    detail: "supervisor 接受了 unit 却报不出 pid —— 常见原因是配置有误或入站端口被占。",
    guidance: {
      summary: "先看 mihomo 自己的错误日志,再决定改配置还是让端口。",
      steps: [
        {
          description: "看 mihomo 错误日志",
          command: `tail -n 50 ${path.join(ctx.plan.logDir, MIHOMO_STDERR_LOG_NAME)}`,
        },
        {
          description: "前台手动起一次,直接看它报什么",
          command: `${ctx.layout.binaryPath} -d ${ctx.layout.dataDir} -f ${ctx.layout.configPath}`,
        },
        { description: "看当前现状", command: "a2 mihomo status --json" },
      ],
      context: { unitPath: ctx.plan.unitPath, configPath: ctx.layout.configPath },
    },
  };
}

function notAnsweringError(ctx: MihomoContext): WireError {
  return {
    code: ErrorCode.mihomoOperationFailed,
    message: "mihomo 进程起来了,但 external-controller 迟迟不应答。",
    detail: `等了 ${CONTROLLER_READY_TIMEOUT_MS}ms 仍连不上 ${ctx.layout.controller}。`,
    guidance: {
      summary: "多半是配置里的 external-controller 与内核算的不一致,或它起来后自己退了。",
      steps: [
        {
          description: "看 mihomo 错误日志",
          command: `tail -n 50 ${path.join(ctx.plan.logDir, MIHOMO_STDERR_LOG_NAME)}`,
        },
        { description: "看那份自管配置", command: `cat ${ctx.layout.configPath}` },
        { description: "再查一次现状", command: "a2 mihomo status --json" },
      ],
      context: { controller: ctx.layout.controller, configPath: ctx.layout.configPath },
    },
  };
}

function stillRunningError(ctx: MihomoContext, pid: number): WireError {
  return {
    code: ErrorCode.mihomoOperationFailed,
    message: "已从 supervisor 卸下 com.a2.mihomo,但进程仍在运行。",
    detail: `supervisor 仍报告 pid ${pid}。`,
    guidance: {
      summary: "确认那个进程确实是 a2 自管的那份,是则显式停掉它,然后重跑卸载(幂等)。",
      steps: [
        { description: "看它是谁(确认命令行里是 a2 自己的落点)", command: `ps -p ${pid} -o pid,command` },
        { description: "确认之后停掉它", command: `kill ${pid}` },
        { description: "重跑卸载", command: "a2 mihomo uninstall" },
      ],
      context: { label: MIHOMO_SERVICE_LABEL, binaryPath: ctx.layout.binaryPath, pid: String(pid) },
    },
  };
}

function commandFailedError(ctx: MihomoContext, error: SupervisorCommandError): WireError {
  return {
    code: ErrorCode.mihomoOperationFailed,
    message: "系统 supervisor 命令失败,com.a2.mihomo 未收敛到预期状态。",
    detail: `${error.message}\n${error.output}`,
    guidance: {
      summary: "原样重跑那条命令看完整输出;确认 unit 文件权限与内容后再试一次。",
      steps: [
        { description: "重跑失败的那条命令", command: error.command },
        { description: "看 unit 文件内容", command: `cat ${ctx.plan.unitPath}` },
        { description: "重试就位(幂等)", command: "a2 mihomo install" },
      ],
      context: { unitPath: ctx.plan.unitPath, label: MIHOMO_SERVICE_LABEL, supervisor: ctx.plan.kind },
    },
  };
}

function unsupportedPlatformError(reason: string, paths: KernelPaths): WireError {
  return {
    code: ErrorCode.serviceUnsupportedPlatform,
    message: "本平台没有已支持的系统 supervisor,无法把 mihomo 挂成系统托管的数据面。",
    detail: reason,
    guidance: {
      summary: "系统托管暂只支持 macOS(launchd)与 Linux(systemd);其余平台请自行常驻 mihomo。",
      steps: [
        { description: "自行前台起一个 mihomo,并把它的 external-controller 告诉 a2" },
        {
          description: "然后 a2 就能读到它的状态(只读探测;它的配置与进程生死都仍归你)",
          command: "A2_MIHOMO_CONTROLLER=127.0.0.1:9090 a2 mihomo status --json",
        },
      ],
      context: { home: paths.home },
    },
  };
}
