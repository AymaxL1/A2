// `a2 mihomo status|install|uninstall|upgrade` 的实体:把「本机 mihomo 怎么就位」收敛到一条命令。
//
// 深模块的边界与服务面一样:调用方(CLI)只拿到一个 `OpOutcome`。检测、档位裁定、下载校验、
// unit 编排、兼容地板与全部失败指引都在这一层里消化掉。
//
// **本文件里没有任何一条代码路径会去停/重启/杀一个不属于 a2 的 mihomo。** 这不是靠自觉:
//   * 能对进程动手的只有 `createSupervisor(plan)`,而 plan 恒是 `com.a2.mihomo` 那一份;
//   * 对别人的实例只有 `controller.ts` 里那两条只读 GET;
//   * 凡是"只能对自管那份做"的动作(升级、卸载),对方不是自管就返回 `mihomo_not_managed`。
// 「数据面不随控制面起落」的另一半在 unit 层:`com.a2.mihomo` 与 `com.a2.kernel` 是两个独立 unit,
// `a2 service uninstall` 碰不到前者(它的 plan 里根本没有那个 label)。

import path from "node:path";
import {
  ErrorCode,
  opFailure,
  opSuccess,
  type Guidance,
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
  recordAdoption,
  releaseAdoption,
} from "./install.ts";
import { resolveDesiredConfig } from "../proxy/config.ts";
import { mihomoLayout, readSecretOf, resolveScanInputs, type MihomoLayout } from "./paths.ts";
import { compareVersions, MIHOMO_COMPAT_FLOOR, MIHOMO_LOCKED_VERSION } from "./pin.ts";

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

    // ① 收编档:什么都不装,只把「我收编的是这个」记在 a2 自己 home 里。
    //    可达且达标才记 —— 否则结构化拒绝 + 指引(不可达时是"我收编的那个没了",归 unreachable)。
    if (decision.rung === "adopt_instance") {
      if (!decision.compatibility.meets) {
        return opFailure(
          decision.compatibility.shortfalls.includes("rest_api_unreachable")
            ? unreachableError(ctx, facts)
            : belowFloorError(ctx, facts, decision),
        );
      }
      const found = facts.foreign!;
      const actions: MihomoAction[] = [];
      if (
        await recordAdoption(ctx.layout, {
          controller: found.target,
          ...(found.configFile ? { configFile: found.configFile } : {}),
        })
      ) {
        actions.push("adoption_recorded");
      }
      const after = await collect(ctx);
      return opSuccess({ status: statusResult(ctx, after, decideLadder(after, options)), actions });
    }

    const actions: MihomoAction[] = [];
    // 走到这儿说明这次要用 a2 自己那份(或人类显式要求隔离):先解除任何既有收编记录,
    // 免得留着一个"我还盯着别人那个实例"的假状态。
    if (await releaseAdoption(ctx.layout)) actions.push("adoption_released");
    if (await ensureDataDir(ctx.layout)) actions.push("data_dir_created");
    // 配置内容由 07 票的配置面算(可调项 + 当前激活订阅);install 只负责"把它落到位"。
    const desired = await resolveDesiredConfig(ctx.layout, ctx.env);
    if (await ensureConfig(ctx.layout, desired.text)) actions.push("config_written");

    if (decision.rung === "reuse_binary") {
      // ② 只读复用:落点上放一个指向那份二进制的符号链接,真身一个字节都不碰。
      const target = facts.managed.binaryTarget ?? facts.foreignBinary?.path;
      if (!target) return opFailure(noBinaryError(ctx));
      if (await linkForeignBinary(ctx.layout, target)) actions.push("binary_linked");
    } else if (facts.managed.binaryKind !== "downloaded") {
      // ③ 脚本安装:只在**还没有自管二进制**时下载。已经有了就绝不在 install 里换版本 ——
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
 * 被收编的实例这条命令一根汗毛都碰不到 —— 它压根不在 `com.a2.mihomo` 这个 plan 里。
 */
export async function mihomoUninstall(paths: KernelPaths): Promise<OpOutcome> {
  return await withMihomo(paths, async (ctx) => {
    const removed = await removeUnit(ctx.plan, ctx.supervisor);
    if (removed.state.pid !== undefined) return opFailure(stillRunningError(ctx, removed.state.pid));
    const actions = mihomoActions(removed.actions);
    // 收编也是一次"就位",所以卸载要把它一并解除 —— 但解除的只是**我这边的记录**,
    // 那个实例该怎么跑还怎么跑(内核从头到尾没碰过它)。
    if (await releaseAdoption(ctx.layout)) actions.push("adoption_released");
    const facts = await collect(ctx);
    return opSuccess({ status: statusResult(ctx, facts, decideLadder(facts)), actions });
  });
}

/**
 * 显式升级 —— **本内核唯一会换 mihomo 版本的地方**,而且只换到 `MIHOMO_LOCKED_VERSION`。
 * 对象只能是 a2 自管的下载版:被收编的实例与只读复用的二进制都不归 a2 管,一律 `mihomo_not_managed`。
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
 * 被收编的实例没了 —— 票面第 2 条:**只产出报警 + 结构化指引,内核不越权重拉**。
 * 指引里那条「等价的前台命令」是从检测到的事实拼出来的,人类可以原样敲。
 */
function unreachableError(ctx: MihomoContext, facts: MihomoFacts): WireError {
  const found = facts.foreign;
  const configFile = found?.configFile;
  const binary = facts.foreignBinary?.path;
  const steps: Guidance["steps"] = [];
  if (binary && configFile) {
    steps.push({
      description: "按你原本的方式把它拉起来(下面是等价的前台命令,拿去改成你自己的托管方式)",
      command: `${binary} -d ${path.dirname(configFile)} -f ${configFile}`,
    });
  } else {
    steps.push({ description: "按你原本的方式把那个 mihomo 拉起来(内核不会替你重拉别人托管的进程)" });
  }
  steps.push(
    { description: "拉起来之后重新检测", command: "a2 mihomo status --json" },
    {
      description: "或者让 a2 装一份自管实例(与你那份并存,入站端口需你自行避开冲突)",
      command: "a2 mihomo install --isolated",
    },
  );
  return {
    code: ErrorCode.mihomoUnreachable,
    message: "配置里写着的 mihomo external-controller 连不上,收编不成立。",
    detail: found?.probe.detail ?? `未在 ${found?.target ?? "(未发现端点)"} 上发现可达的 external-controller。`,
    guidance: {
      summary: "被收编的实例其生命周期归原托管方 —— 内核只报警和指路,绝不替你重启它。",
      steps,
      context: {
        controller: found?.target ?? "(未发现)",
        ...(configFile ? { configFile } : {}),
        home: ctx.paths.home,
      },
    },
  };
}

/** 收编对象不达兼容地板 —— **不擅自升级别人的东西**,给降级报告与两条明路。 */
function belowFloorError(
  ctx: MihomoContext,
  facts: MihomoFacts,
  decision: LadderDecision,
): WireError {
  const found = facts.foreign;
  return {
    code: ErrorCode.mihomoBelowFloor,
    message: `跑着的那个 mihomo 不达兼容地板 ${MIHOMO_COMPAT_FLOOR},已拒绝收编。`,
    detail:
      `版本 ${decision.compatibility.version ?? "问不出"};不达标项:` +
      `${decision.compatibility.shortfalls.join("、")}。内核不会去升级不属于它的实例。`,
    guidance: {
      summary: "两条明路:你自己把它升到地板之上,或者让 a2 装一份自管实例与之并存。",
      steps: [
        { description: "自己升级那个 mihomo 之后重新检测", command: "a2 mihomo status --json" },
        {
          description: "或者让 a2 按锁定版装一份自管实例(与你那份并存,入站端口需你自行避开冲突)",
          command: "a2 mihomo install --isolated",
        },
      ],
      context: {
        floor: MIHOMO_COMPAT_FLOOR,
        lockedVersion: MIHOMO_LOCKED_VERSION,
        controller: found?.target ?? "(未发现)",
        shortfalls: decision.compatibility.shortfalls.join(","),
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
      : "a2 还没有自管的 mihomo 二进制(当前要么在收编别人的实例,要么还没就位)。";
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
          description: "然后让 a2 收编它(只读探测 + 配置面接管,进程生死仍归你)",
          command: "A2_MIHOMO_CONTROLLER=127.0.0.1:9090 a2 mihomo status --json",
        },
      ],
      context: { home: paths.home },
    },
  };
}
