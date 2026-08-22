// `a2 service install|uninstall|start|stop|status` 的实体:系统托管与进程生命周期。
//
// 深模块的边界:调用方(CLI)只拿到**一种东西** —— 一个 `OpOutcome`(成了带 result,没成带 WireError)。
// 平台差异、命令编排、幂等判定、失败指引全在这一层里消化掉。
//
// 幂等口径:五条命令都是**收敛**语义 —— 说的是"我要它是这个样子",不是"执行这几步"。
// 已经是那个样子就什么都不做,`actions` 为空数组;这就是幂等的可观察面(不必比对前后状态)。
//
// 「CLI 永不隐式拉起 daemon」不因本票而破:`install` 是**人类显式授权**的动作,由它把常驻交给系统
// supervisor 是合法的;`status` 只读;其余任何命令仍然只 connect、从不 spawn。

import { existsSync, readFileSync } from "node:fs";
import { rm } from "node:fs/promises";
import path from "node:path";
import { callKernel } from "../client/kernel-client.ts";
import {
  ErrorCode,
  Op,
  opFailure,
  opSuccess,
  type OpOutcome,
  type ServiceAction,
  type ServicePurgeReport,
  type ServiceStatusResult,
  type WireError,
} from "../contract/wire.ts";
import { mihomoLayout } from "../mihomo/paths.ts";
import { readSnapshot, snapshotPath } from "../proxy/system-proxy.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { convergeUnit, removeUnit, settle, SETTLE_POLL_MS } from "./converge.ts";
import {
  defaultHome,
  nonDefaultHome,
  unsafeHomeOnDisk,
  unsafeHomeShape,
  type PurgeRefusal,
} from "./purge-guard.ts";
import { copySelfToHome, homeBinPath, resolveSelfBin, SELF_BIN_ENV } from "./self-copy.ts";
import {
  createSupervisor,
  loadImpliesStart,
  SupervisorCommandError,
  type Supervisor,
  type SupervisorState,
  type UnitAction,
} from "./supervisor.ts";
import {
  legacyMihomoRemovalPlan,
  MIHOMO_SERVICE_LABEL,
  resolveSupervisorKind,
  servicePlan,
  STDERR_LOG_NAME,
  STDOUT_LOG_NAME,
  unitBinaryPath,
  unitHomePath,
  type ServicePlan,
  type ServicePlanOptions,
} from "./unit.ts";

/**
 * 等"内核真的能答话"的上限。supervisor 报了 pid 只说明进程 exec 了 —— 本机实测那一刻 socket 还没 bind
 * (连 `<home>/run` 目录都还没建),紧接着的一条 `a2 status` 会撞上几百毫秒的空窗、拿到 daemon_unreachable。
 * `install` 承诺的是"装完就是能用的",所以它必须替调用方等完这一段。
 */
const DAEMON_READY_TIMEOUT_MS = 5000;

export async function serviceStatus(paths: KernelPaths): Promise<OpOutcome> {
  return await withPlan(paths, async (plan) => {
    const state = await createSupervisor(plan).query();
    return opSuccess(statusResult(plan, state));
  });
}

/** 拉起已经安装但已停止的服务;不写 unit、不换 bin。 */
export async function serviceStart(paths: KernelPaths): Promise<OpOutcome> {
  return await withPlan(paths, async (plan) => {
    const supervisor = createSupervisor(plan);
    let state = await supervisor.query();
    if (!existsSync(plan.unitPath) || !state.registered) {
      return opFailure(serviceNotInstalledError(plan, "启动"));
    }
    const actions: ServiceAction[] = [];
    if (state.pid === undefined) {
      await supervisor.start();
      actions.push("kernel_started");
      state = await settle(supervisor, (current) => current.pid !== undefined);
    }
    if (state.pid === undefined) return opFailure(notRunningError(plan));
    if (!(await settleDaemonReachable(plan))) return opFailure(notAnsweringError(plan));
    return opSuccess({ status: statusResult(plan, state), actions });
  });
}

/** 停止服务进程但保留 unit/自启登记;a2 的退出钩子会同步收掉内嵌 mihomo。 */
export async function serviceStop(paths: KernelPaths): Promise<OpOutcome> {
  return await withPlan(paths, async (plan) => {
    const supervisor = createSupervisor(plan);
    let state = await supervisor.query();
    const actions: ServiceAction[] = [];
    if (state.pid !== undefined) {
      await supervisor.stop(state);
      actions.push("kernel_stopped");
      state = await settle(supervisor, (current) => current.pid === undefined);
    }
    if (state.pid !== undefined) return opFailure(stillRunningError(plan, state.pid));
    return opSuccess({ status: statusResult(plan, state), actions });
  });
}

export interface ServiceInstallOptions {
  /**
   * `--copy-to-home`(15 票 / ADR 0012「面板自足」):先把本 bin 自己原子拷进 `$A2_HOME/bin/a2`,
   * 再让 unit 指向那份拷贝。不给则行为一字不变(unit 仍指向当前这个可执行)。
   */
  copyToHome?: boolean;
}

export async function serviceInstall(
  paths: KernelPaths,
  options: ServiceInstallOptions = {},
): Promise<OpOutcome> {
  // 拷贝的前置判断放在**动手之前**:没有可分发的自身时,连 unit 都不该碰一下。两种不成立各有说法 ——
  // 开发态(压根没有单文件产物)与"指过来的那个文件不在"(只可能来自诊断用的覆写)。
  const selfBin = options.copyToHome ? resolveSelfBin() : undefined;
  if (options.copyToHome) {
    if (selfBin === undefined) return opFailure(selfCopyUnsupportedError(paths));
    // 不做这一步的话,它会一路走到 `Bun.write` 才炸,落进 withPlan 的兜底(退出码 5「事没办成」)——
    // 而这件事其实是**这条请求本身不成立**(6),指引也该对着那个覆写说话,不是让人去看内核日志。
    if (!existsSync(selfBin)) return opFailure(selfBinMissingError(paths, selfBin));
  }
  const planOptions: ServicePlanOptions = options.copyToHome
    ? { binPath: homeBinPath(paths) }
    : {};

  return await withPlan(
    paths,
    async (plan) => {
      const actions: ServiceAction[] = [];
      // 先落 bin 再写 unit:反过来的话,拷贝失败会留下一个指着不存在的文件的 unit。
      const binChanged =
        selfBin !== undefined && (await copySelfToHome(selfBin, homeBinPath(paths))) === "copied";
      if (binChanged) actions.push("bin_copied");

      const supervisor = createSupervisor(plan);
      // 收敛**之前**的运行态:下面那条"要不要重启"问的是"这次改动落地时它正跑着吗"。
      const before = await supervisor.query();
      const converged = await convergeUnit(plan, supervisor);
      actions.push(...kernelActions(converged.actions));
      let state = converged.state;

      // **换了文件不等于换了进程**(内嵌 mihomo 的升级随行同一条道理):bin 换了新 inode 而 unit
      // 一个字没动时,收敛逻辑什么都不会做,跑着的那个进程还攥着旧 bin。这一步就是显式升级的落点。
      if (binChanged && before.pid !== undefined && !processReplaced(converged.actions, supervisor)) {
        await supervisor.restart();
        actions.push("kernel_restarted");
        state = await settle(supervisor, (current) => current.pid !== undefined);
      }

      if (state.pid === undefined) {
        return opFailure(notRunningError(plan));
      }
      // 有 pid ≠ 能用。等它在 socket 上真的应答,`install` 才算兑现"装完就是跑着的"。
      if (!(await settleDaemonReachable(plan))) {
        return opFailure(notAnsweringError(plan));
      }

      return opSuccess({ status: statusResult(plan, state), actions });
    },
    planOptions,
  );
}

/**
 * 本次收敛有没有顺带把进程换掉:显式拉起/重启过,或者这一次的装载本身就含拉起
 * (launchd 的 bootstrap —— 判据与 `converge.ts` 里"值不值得空等"共用 `loadImpliesStart()`,
 * 不是各写一遍的"同源")。错判的代价是白重启一次服务,所以宁可保守。
 */
function processReplaced(actions: UnitAction[], supervisor: Supervisor): boolean {
  if (actions.includes("process_started") || actions.includes("process_restarted")) return true;
  return loadImpliesStart(supervisor, actions);
}

export interface ServiceUninstallOptions {
  /**
   * `--purge`(17 票):卸载之后**继续往下清** —— 拆掉 a2 自管的 mihomo unit(`com.a2.mihomo`,
   * 装着才拆)、再删掉整个 `$A2_HOME`。不给则行为一字不变(只拆内核那一个 unit)。
   */
  purge?: boolean;
}

/**
 * 卸载。不带 `--purge` 时口径与 15 票一字不变:**只拆内核那一个 unit**。
 *
 * 带 `--purge` 时的**顺序即安全性**,一步都不能挪:
 *   ⓪ **五道拒绝判据全部前置**,任一不过就当场拒绝、**一个字节都不删**:
 *      ⓪0 **只对缺省 `~/.a2` 放行**(18 票用户裁定;自定义 `A2_HOME` 一律拒,见 `nonDefaultHomeError`);
 *      ⓪a 目标形状(`purge-guard.ts` 的纯判据:不许是 `/`、家目录本身、家目录的祖先、相对路径);
 *      ⓪b 目标是不是符号链接(删链不删树 = 假账,如实拒绝并告诉他真实目标在哪);
 *      ⓪c **盘上那两份 unit 服务的 home 与本次的 `$A2_HOME` 一致**(见 `unitRecordedHome`);
 *      ⓪d 系统代理仍处接管态(见 `purgeBlockedError`)。
 *      全部放在最前面是因为"删一半再拒"比"直接拒"糟得多:那时内核已经没了,而还原依据还在,人两头够不着。
 *   ① 拆内核 unit(既有路径,含"进程真的没了"的确认);
 *   ② 拆 `com.a2.mihomo`(装着才拆,不在则整条不报 action);两个 unit 都收拾干净,才轮得到删数据 ——
 *      反过来先删 `$A2_HOME` 的话,那两个进程会攥着一个已经不存在的配置目录继续跑;
 *   ③ 删 `$A2_HOME` 整棵树。
 *
 * **范围红线**:动得了的 unit 只有 `plan.label` 与 `MIHOMO_SERVICE_LABEL` 两个常量(`com.a2.*`),
 * 动得了的路径只有 `paths.home` 一条。用户自己装的 mihomo(`io.metacubex.mihomo` 等)无论装在哪、
 * 数据放在哪,都不在任何一条代码路径的射程内。
 *
 * ============================================================================
 * 一处必须说清的皱褶:**label 是每用户一个,而 home 是每次调用一个**
 * ============================================================================
 * `com.a2.kernel` / `com.a2.mihomo` 这两个 label 是常量(`unit.ts`,任何参数都改不了),
 * 于是**每个用户在同一时刻只可能有一套 a2 服务**;而 `$A2_HOME` 是每次调用现算的(环境变量可覆写)。
 * 两者交叉出一个真实的坑,而 18 票之后它的形状是**反过来的那一半**:purge 只在缺省 `~/.a2` 上放行,
 * 但那两个 unit 可能是**在别的 home 下装的**(`A2_HOME=/tmp/x a2 service install` 装的是同一对 label)。
 * 于是"在缺省 home 上 purge"会去拆一对**服务着 `/tmp/x` 的数据面**的 unit,而 ⓪d 的接管快照判据
 * 看的是缺省 home 那份 —— `/tmp/x/system-proxy.json` 根本不会被看见。放行 = 拆掉正承载着系统代理的
 * 用户级 `com.a2.mihomo`,当场断网。
 * (18 票之前还有对称的另一半:在自定义 home 下 purge 去拆缺省 home 的 unit。那一半现在被 ⓪0 挡死了。)
 *
 * ⓪c 就是把这扇门真的关上:**盘上那两份 unit 各自带着它服务的那个 home 的指纹** ——
 * 内核那份记着安装时的 `A2_HOME`(`servicePlan` 写进去的),mihomo 那份是它跑的二进制路径
 * (`<home>/mihomo/bin/mihomo`)。任一与本次的 home 不一致就拒绝。
 * 两份都不在则跳过这一条 —— 没有 unit 就没有"被托管的数据面",当前 home 的快照判据照常管用。
 */
export async function serviceUninstall(
  paths: KernelPaths,
  options: ServiceUninstallOptions = {},
): Promise<OpOutcome> {
  return await withPlan(paths, async (plan) => {
    if (options.purge) {
      // ⓪0 **白名单**(18 票,用户裁定):purge 只对缺省 `~/.a2` 生效。最一刀切、最便宜,故最先跑;
      //    它一成立,下面 ⓪a 的根 / 家目录 / 祖先几档就再也走不到了(如实记在 `purge-guard.ts` 头注,
      //    判据与用例都保留 —— 纵深不因为"上面挡住了"就该拆掉)。
      const custom = nonDefaultHome(paths.home);
      if (custom) return opFailure(nonDefaultHomeError(paths, custom));
      const refusal = unsafeHomeShape(paths.home) ?? (await unsafeHomeOnDisk(paths.home));
      // ⓪a/⓪b 目标本身不成立 —— 这条请求在这个 $A2_HOME 上根本不该被执行。
      if (refusal) return opFailure(unsafeHomeError(paths, refusal));
      // ⓪c 这两个 unit 是不是给这个 home 装的(见上文那段皱褶)。**两个都要核**:
      //    内核那份记着 `A2_HOME`,mihomo 那份没有(它不认识这个变量),但它的 argv[0] 恒是
      //    `<home>/mihomo/bin/mihomo` —— 那就是它服务的那个 home 的指纹。
      //    只核内核那一份是不够的:内核 unit 不在、而 mihomo unit 是别的 home 装的,
      //    这条路上照样会拆掉一个正承载着系统代理的数据面。
      const mismatch =
        unitRecordedHome(plan) ?? unitRecordedHome(mihomoPlanFor(plan, paths));
      if (mismatch) return opFailure(homeMismatchError(plan, mismatch));
      // ⓪d 判据是接管记录这个文件在不在(`system-proxy.ts` 的口径:"它在 = 现在是我接管着"),
      //    不经 daemon —— purge 的典型时刻恰恰是 daemon 已经该没了。**它是 home 相对的**,
      //    所以必须排在 ⓪c 之后:home 都错了的话,这一条看的是错那个 home 的快照。
      if (existsSync(snapshotPath(paths))) {
        return opFailure(await purgeBlockedError(paths));
      }
    }

    const supervisor = createSupervisor(plan);
    // 卸载的承诺是"干净移除",所以要真的确认进程没了 —— 否则下一次 install 会撞上一个野生实例。
    const { actions, state } = await removeUnit(plan, supervisor);
    if (state.pid !== undefined) {
      return opFailure(stillRunningError(plan, state.pid));
    }
    const serviceActions = kernelActions(actions);

    if (!options.purge) {
      return opSuccess({ status: statusResult(plan, state), actions: serviceActions });
    }

    const purge: ServicePurgeReport = { removedUnits: [], removedPaths: [] };
    if (actions.includes("unit_removed") || actions.includes("supervisor_unloaded")) {
      purge.removedUnits.push(plan.label);
    }

    // ② 旧版 a2 自装的 `com.a2.mihomo`(14 票起内核不再写它,这里只为拆干净)。
    //    plan 的路径取自 `mihomoLayout`(与内嵌子进程同一个来源)—— 各拼一次路径就会有
    //    "purge 删的不是当年装的"这种最难查的漂移。
    const mihomo = mihomoPlanFor(plan, paths);
    const removedMihomo = await removeUnit(mihomo, createSupervisor(mihomo));
    if (removedMihomo.state.pid !== undefined) {
      return opFailure(mihomoStillRunningError(mihomo, removedMihomo.state.pid));
    }
    if (removedMihomo.actions.length > 0) {
      serviceActions.push("mihomo_unit_removed");
      purge.removedUnits.push(mihomo.label);
    }

    // ③ 数据面。两个 unit 都收拾干净了,这一步才是安全的。
    if (existsSync(paths.home)) {
      await rm(paths.home, { recursive: true, force: true });
      serviceActions.push("home_purged");
      purge.removedPaths.push(paths.home);
    }

    // 状态取删完之后的那一帧:unit 不在、进程不在 —— 与"卸干净了"这句话对得上。
    return opSuccess({ status: statusResult(plan, state), actions: serviceActions, purge });
  });
}

/** ⓪c 的读数:**哪一个** unit 对不上,以及它盘上那份到底是给谁装的(读不出则缺席)。 */
interface HomeMismatch {
  unitPath: string;
  label: string;
  /** 从盘上那份 unit 推出来的 home;形状解不出时缺席(那一格同样拒绝,见下)。 */
  home?: string;
}

/**
 * 盘上这个 unit 是给哪个 `$A2_HOME` 装的 —— 对得上返回 undefined,对不上返回它的读数。
 *
 * 两个 unit 各有各的指纹,由 `plan.label` 分派:
 *   * `com.a2.kernel` —— unit 里**明写着** `A2_HOME`(`servicePlan` 无条件注入,supervisor 不读 shell 配置);
 *   * `com.a2.mihomo` —— 有意**不**注入 `A2_HOME`(mihomo 不认识它),但它的 argv[0] 恒是
 *     `<home>/mihomo/bin/mihomo`,那就是它服务的那个 home 的指纹。这里不自己拼路径去比,
 *     而是拿**本次 plan 会写的那个 argv[0]** 与盘上那份逐字比 —— 同源比较,不会各算各的。
 *
 * 三种收场:
 *   * **unit 不在** → 不拒(没有那一份被托管的东西,也就没有"删错谁"的风险);
 *   * **读得出且相等** → 不拒;
 *   * **读得出但不等 / 读不出** → 拒。最后那一格是有意的 fail-closed:本内核写的 unit 必然带着
 *     这两个指纹之一,读不出来说明它不是本内核写的、或者被改坏了 —— 那时我们对"这台机器上正被
 *     托管的是哪个 home"一无所知,而下一步是不可逆的删除。不猜。
 */
function unitRecordedHome(plan: ServicePlan): HomeMismatch | undefined {
  if (!existsSync(plan.unitPath)) return undefined;

  let content: string | undefined;
  try {
    content = readFileSync(plan.unitPath, "utf8");
  } catch {
    content = undefined;
  }
  const identity = { unitPath: plan.unitPath, label: plan.label };
  if (content === undefined) return identity;

  if (plan.label === MIHOMO_SERVICE_LABEL) {
    const binary = unitBinaryPath(plan.kind, content);
    if (binary === (plan.programArguments[0] as string)) return undefined;
    // `<home>/mihomo/bin/mihomo` → `<home>`:往上三级。推不出来就只报 unit,不编一个 home 出来。
    const derived = binary === undefined ? undefined : path.dirname(path.dirname(path.dirname(binary)));
    return { ...identity, ...(derived === undefined ? {} : { home: derived }) };
  }

  const recorded = unitHomePath(plan.kind, content);
  if (recorded === plan.paths.home) return undefined;
  return { ...identity, ...(recorded === undefined ? {} : { home: recorded }) };
}

/**
 * 旧版 `com.a2.mihomo` 的 plan。**唯一目的是拆它**(14 票起内核不再写这个 unit),
 * 三个路径参数取自 `mihomoLayout`(与内嵌子进程同一个来源),unit 内容在移除路径上不参与任何判断。
 */
function mihomoPlanFor(plan: ServicePlan, paths: KernelPaths): ServicePlan {
  const layout = mihomoLayout(paths, process.env);
  return legacyMihomoRemovalPlan(
    plan.kind,
    paths,
    { binaryPath: layout.binaryPath, dataDir: layout.dataDir, configPath: layout.configPath },
    process.env,
  );
}

/** unit 层的通用动作词 → 服务面的词表(内核这一份的进程就叫「内核」)。 */
function kernelActions(actions: UnitAction[]): ServiceAction[] {
  return actions.map((action) =>
    action === "process_started"
      ? "kernel_started"
      : action === "process_restarted"
        ? "kernel_restarted"
        : action,
  );
}

/** 五条命令共用的前置:选 supervisor → 算 plan → 把两类失败(平台不支持 / 命令失败)翻成 WireError。 */
async function withPlan(
  paths: KernelPaths,
  body: (plan: ServicePlan) => Promise<OpOutcome>,
  planOptions: ServicePlanOptions = {},
): Promise<OpOutcome> {
  const choice = resolveSupervisorKind();
  if (!choice.ok) return opFailure(unsupportedPlatformError(choice.reason, paths));

  const plan = servicePlan(choice.kind, paths, process.env, planOptions);
  try {
    return await body(plan);
  } catch (error) {
    if (error instanceof SupervisorCommandError) return opFailure(commandFailedError(error, plan));
    return opFailure({
      code: ErrorCode.serviceOperationFailed,
      message: "服务操作失败。",
      detail: String(error),
      guidance: {
        summary: "确认 unit 目录与 A2_HOME 可写后重试;仍不行则看内核日志。",
        steps: [
          { description: "看当前服务状态", command: "a2 service status --json" },
          { description: "看内核错误日志", command: `tail -n 50 ${path.join(plan.logDir, STDERR_LOG_NAME)}` },
        ],
        context: { unitPath: plan.unitPath, home: plan.paths.home },
      },
    });
  }
}

/**
 * 轮询到内核在 UDS 上真的应答为止。用的就是普通客户端那条路(`callKernel`)——
 * "能不能用"这件事只该有一个判据,不另造探针。
 */
async function settleDaemonReachable(plan: ServicePlan): Promise<boolean> {
  const deadline = Date.now() + DAEMON_READY_TIMEOUT_MS;
  for (;;) {
    if ((await callKernel(plan.paths, Op.statusGet)).ok) return true;
    if (Date.now() >= deadline) return false;
    await Bun.sleep(SETTLE_POLL_MS);
  }
}

/**
 * 三态判定(契约见 `ServiceStateSchema`):有 pid 就是运行中;没 pid 但 unit 文件在**或** supervisor
 * 认识它,就是"装了没跑"(半装状态也算装了 —— 这样 uninstall 才会去收拾它);两样都没有才是未安装。
 */
function statusResult(plan: ServicePlan, state: SupervisorState): ServiceStatusResult {
  const unitInstalled = existsSync(plan.unitPath);
  const installed = unitInstalled || state.registered;
  return {
    state: state.pid !== undefined ? "running" : installed ? "installed_not_running" : "not_installed",
    supervisor: plan.kind,
    label: plan.label,
    unitPath: plan.unitPath,
    unitInstalled,
    binPath: installedBinPath(plan),
    registered: state.registered,
    ...(state.pid === undefined ? {} : { pid: state.pid }),
    home: plan.paths.home,
    socketPath: plan.paths.socketPath,
  };
}

/**
 * unit 实际指向的可执行。**先问盘上那份**(它才是此刻真被托管的东西);
 * 只有 **unit 不在、或形状解不出**这两种情形才回落到本次调用会写的那个 ——
 * 与 `unitPath` 在未安装时给出"install 会写的位置"同一口径。
 */
function installedBinPath(plan: ServicePlan): string {
  const planned = plan.programArguments[0] as string;
  try {
    return unitBinaryPath(plan.kind, readFileSync(plan.unitPath, "utf8")) ?? planned;
  } catch {
    return planned;
  }
}

function unsupportedPlatformError(reason: string, paths: KernelPaths): WireError {
  return {
    code: ErrorCode.serviceUnsupportedPlatform,
    message: "本平台没有已支持的系统 supervisor,无法安装常驻服务。",
    detail: reason,
    guidance: {
      summary: "常驻托管暂只支持 macOS(launchd)与 Linux(systemd);其余平台请自行常驻内核进程。",
      steps: [
        { description: "在一个终端里前台起常驻进程(Ctrl-C 结束)", command: "a2 daemon run" },
        { description: "或用你自己的进程管理器托管这条命令", command: "a2 daemon run" },
      ],
      context: { home: paths.home },
    },
  };
}

/**
 * `--copy-to-home` 撞上开发态。指引给的是**这台机器上此刻能走通的两条路**:
 * 要么用编译产物(分发形态本来就是它),要么不带旗标装(unit 直接指向源码入口那条命令)。
 */
function selfCopyUnsupportedError(paths: KernelPaths): WireError {
  return {
    code: ErrorCode.serviceSelfCopyUnsupported,
    message: "当前这个 a2 不是可分发的单文件产物,没有「自身」可以拷进 A2_HOME。",
    detail:
      "--copy-to-home 拷的是 bun build --compile 出来的那份单文件;源码态跑起来的 a2 的可执行是 bun 自己,拷过去只会得到一个跑不起来的空壳。",
    guidance: {
      summary: "用编译产物跑这条命令(分发形态本来就是它);只想在开发态装服务的话,不带旗标即可。",
      steps: [
        { description: "编译单文件产物", command: "bash kernel/scripts/build.sh" },
        {
          description: "用产物装(unit 指向 $A2_HOME/bin/a2 的拷贝)",
          command: "kernel/dist/a2 service install --copy-to-home --json",
        },
        { description: "或者开发态直接装(unit 指向当前这条命令)", command: "a2 service install --json" },
      ],
      // 有意**不**在这里登记 `A2_SELF_BIN`(CR 尾款 5a):那是仅供测试与诊断的覆写,
      // 把它写进用户可见的指引等于邀请人去用它。它只在**它自己出问题**的那条错误里露面(见下)。
      context: { home: paths.home, binPath: homeBinPath(paths) },
    },
  };
}

/**
 * 指过来的那份"自身"不在。生产路径上走不到这里(那时是 `process.execPath`,它必然存在)——
 * 唯一的来路是 `A2_SELF_BIN` 覆写指错了地方,所以这条错误**点名它**:是它出的问题,人得知道去改哪。
 */
function selfBinMissingError(paths: KernelPaths, selfBin: string): WireError {
  const overridden = process.env[SELF_BIN_ENV]?.trim() ? SELF_BIN_ENV : undefined;
  return {
    code: ErrorCode.serviceSelfCopyUnsupported,
    message: overridden
      ? `${SELF_BIN_ENV} 指向不存在的文件,没有可拷贝的自身。`
      : "本 bin 自己的可执行不在了,没有可拷贝的自身。",
    detail: `要拷的是 ${selfBin},但这个路径上没有文件。`,
    guidance: {
      summary: overridden
        ? `${SELF_BIN_ENV} 是仅供测试与诊断的覆写:要么把它指向一个真的可执行,要么去掉它、用编译产物跑。`
        : "用一份完整的编译产物重跑这条命令。",
      steps: [
        { description: "看那个路径上到底有什么", command: `ls -l ${selfBin}` },
        { description: "编译一份完整的单文件产物", command: "bash kernel/scripts/build.sh" },
        {
          description: "用产物装(不带任何覆写)",
          command: "kernel/dist/a2 service install --copy-to-home --json",
        },
      ],
      context: { home: paths.home, binPath: homeBinPath(paths), selfBin },
    },
  };
}

function commandFailedError(error: SupervisorCommandError, plan: ServicePlan): WireError {
  return {
    code: ErrorCode.serviceOperationFailed,
    message: "系统 supervisor 命令失败,服务未收敛到预期状态。",
    detail: `${error.message}\n${error.output}`,
    guidance: {
      summary: "原样重跑那条命令看完整输出;确认 unit 文件权限与内容后再试一次。",
      steps: [
        { description: "重跑失败的那条命令", command: error.command },
        { description: "看 unit 文件内容", command: `cat ${plan.unitPath}` },
        { description: "重试安装(幂等)", command: "a2 service install" },
      ],
      context: { unitPath: plan.unitPath, label: plan.label, supervisor: plan.kind },
    },
  };
}

function serviceNotInstalledError(plan: ServicePlan, verb: string): WireError {
  return {
    code: ErrorCode.serviceOperationFailed,
    message: `a2 服务尚未安装,无法${verb}。`,
    detail: `${plan.unitPath} 不存在,或 supervisor 尚未登记 ${plan.label}。`,
    guidance: {
      summary: "先显式安装服务,再重试。",
      steps: [{ description: "安装并启动服务", command: "a2 service install --json" }],
      context: { unitPath: plan.unitPath, label: plan.label },
    },
  };
}

function notRunningError(plan: ServicePlan): WireError {
  return {
    code: ErrorCode.serviceOperationFailed,
    message: "unit 已装好,但内核进程没能起来。",
    detail:
      "supervisor 接受了 unit 却报不出 pid —— 常见原因是内核启动即退出(如同一个 A2_HOME 下已有前台实例占着 socket)。",
    guidance: {
      summary: "先看内核自己的错误日志,再决定是停掉占用者还是修 unit。",
      steps: [
        {
          description: "看内核错误日志",
          command: `tail -n 50 ${path.join(plan.logDir, STDERR_LOG_NAME)}`,
        },
        { description: "前台手动起一次,直接看它报什么", command: "a2 daemon run" },
        { description: "看服务当前状态", command: "a2 service status --json" },
      ],
      context: { unitPath: plan.unitPath, label: plan.label, home: plan.paths.home },
    },
  };
}

function notAnsweringError(plan: ServicePlan): WireError {
  return {
    code: ErrorCode.serviceOperationFailed,
    message: "内核进程起来了,但迟迟没在 socket 上应答。",
    detail: `等了 ${DAEMON_READY_TIMEOUT_MS}ms 仍连不上 ${plan.paths.socketPath}。`,
    guidance: {
      summary: "多半是内核起来后自己退了或卡在启动上,看它的日志。",
      steps: [
        {
          description: "看内核错误日志",
          command: `tail -n 50 ${path.join(plan.logDir, STDERR_LOG_NAME)}`,
        },
        {
          description: "看内核生命周期事件",
          command: `tail -n 50 ${path.join(plan.logDir, STDOUT_LOG_NAME)}`,
        },
        { description: "再查一次运行态", command: "a2 status --json" },
      ],
      context: { socketPath: plan.paths.socketPath, unitPath: plan.unitPath, home: plan.paths.home },
    },
  };
}

/**
 * ⓪0:这次的 `$A2_HOME` 不是缺省的 `~/.a2`(18 票,用户裁定)。
 *
 * **复用 `service_purge_unsafe_home`(6)而不另立新码**,理由:这一码的语义本来就是
 * 「这条请求在**这个 `$A2_HOME`** 上根本不成立」—— 而"自定义 home 上 purge 永远不成立"
 * 正是这句话的一个取值,不是另一件事。真正区分它们的是 `guidance.context.reason`
 * (`non_default_home` / `filesystem_root` / `symlink` …),那本来就是这一族的机读分支依据;
 * 为同一句话再造一个码,只会让 agent 多写一个 case 而拿不到任何新信息。
 *
 * 归 6 不归 1 也是同一条道理:1 那一档是"等状态变了同一条命令就成立",而这条**等到什么时候都不成立**
 * —— 除非你换掉 `A2_HOME`,而那已经是另一条请求了。
 *
 * 指引给三条**都能走通**的路:只拆服务(不挑 home)、去缺省 home 清、以及自己清这个自定义 home
 * (那条 `rm -rf` 写明"这条会真的删" —— 数据的处置权本来就该在人手里)。
 */
function nonDefaultHomeError(paths: KernelPaths, refusal: PurgeRefusal): WireError {
  const expected = defaultHome();
  return {
    code: ErrorCode.servicePurgeUnsafeHome,
    message: "--purge 只清理缺省的 ~/.a2,而这次的 A2_HOME 是自定义的 —— 已拒绝,什么都没删。",
    detail:
      `${refusal.detail}自定义 home 多半另有用途(测试沙盒、多份配置、指向共享目录),` +
      "内核不替你判断哪一份是「该整棵删掉的那一份」—— 那个决定连同它的后果都该在你手里。",
    guidance: {
      summary: "要清这个自定义 home 请自己动手(路径见下);服务本身可以照常拆,那一条不挑 home。",
      steps: [
        { description: "只拆服务(不动任何数据,这条对任何 A2_HOME 都成立)", command: "a2 service uninstall" },
        { description: "确认这次用的是哪个 home", command: "a2 service status --json" },
        { description: "要清的是缺省 home 的话,不带 A2_HOME 重来", command: "a2 service uninstall --purge" },
        { description: "确认无误后自行清理这个自定义 home(这条会真的删)", command: `rm -rf ${paths.home}` },
      ],
      context: { home: paths.home, defaultHome: expected, reason: refusal.reason },
    },
  };
}

/**
 * ⓪a/⓪b:`$A2_HOME` 本身不是一个可以被 `rm -rf` 的目标(17 票 CR 尾款)。
 *
 * 归 6 不归 5/1(与 `service_unsupported_platform` / `service_self_copy_unsupported` 同档):
 * 那两条说的是"这条请求在这台机器 / 这个 bin 上根本不成立",这一条说的是"在这个 `$A2_HOME` 上
 * 根本不成立" —— 同一种"请求本身不成立"。它**不是** 1(那一档是"命令没错、这会儿不该发",
 * 等状态变了同一条命令就成立;而 `A2_HOME=/` 无论等到什么时候都不该被删),也不是 5(什么都没执行)。
 *
 * `context.reason` 是机读词表(`PurgeRefusalReason`),agent 据此分支;symlink 那两档另给 `linkTarget`,
 * 免得用户还得自己去 `readlink` 一次才知道数据在哪。
 */
function unsafeHomeError(paths: KernelPaths, refusal: PurgeRefusal): WireError {
  const symlink = refusal.reason === "symlink" || refusal.reason === "dangling_symlink";
  return {
    code: ErrorCode.servicePurgeUnsafeHome,
    message: symlink
      ? "$A2_HOME 是一根符号链接,已拒绝 --purge —— 删它只会删掉那根链,数据一个字节都不会少。"
      : "$A2_HOME 不是一个可以整棵删掉的目标,已拒绝 --purge —— 什么都没删。",
    detail: refusal.detail,
    guidance: {
      summary: symlink
        ? "链目标是你自己指过去的地方,该不该删由你决定 —— 内核只拆服务,不替你处置链那一头的树。"
        : "把 A2_HOME 指回 a2 自己的数据目录(缺省 ~/.a2)再来;这一次什么都没删。",
      steps: symlink
        ? [
            { description: "看这根链指向哪儿", command: `readlink ${paths.home}` },
            { description: "只拆服务(不删任何数据)", command: "a2 service uninstall" },
            {
              description: "确认要清的话,自己处置链目标那棵树",
              command: refusal.linkTarget ? `ls -la ${refusal.linkTarget}` : `ls -la ${paths.home}/`,
            },
          ]
        : [
            { description: "看这次 A2_HOME 到底指着哪儿", command: "a2 service status --json" },
            { description: "用缺省 home 重来(或把 A2_HOME 指对)", command: "a2 service uninstall --purge" },
            { description: "只拆服务(不碰任何数据)", command: "a2 service uninstall" },
          ],
      context: {
        home: paths.home,
        reason: refusal.reason,
        ...(refusal.linkTarget ? { linkTarget: refusal.linkTarget } : {}),
      },
    },
  };
}

/**
 * ⓪c:盘上那份 unit 是给**另一个** `$A2_HOME` 装的(17 票 CR 尾款)。
 *
 * 归 1(与 `daemon_already_running` / `service_purge_blocked` 同档):命令本身完全成立,
 * 只是**不该在这儿发** —— 到那个 home 去执行,或者先把那边收拾干净,这条就成立了。
 * 不归 6:这不是"这条请求根本不成立",而是"你站错了地方"。
 *
 * 为什么必须拒(而不是"顺手把那两个 unit 也拆了"):那两个 unit 服务的是**另一个 home 的数据面**,
 * 它的接管快照在那边,这次调用连看都看不到。放行 = 拆掉一个可能正承载着系统代理的 mihomo,当场断网。
 */
function homeMismatchError(plan: ServicePlan, mismatch: HomeMismatch): WireError {
  const known = mismatch.home;
  return {
    code: ErrorCode.servicePurgeHomeMismatch,
    message: known
      ? `盘上这份 ${mismatch.label} 是为另一个 A2_HOME 装的,已拒绝 --purge —— 什么都没删。`
      : `盘上这份 ${mismatch.label} 读不出它服务的 A2_HOME,已拒绝 --purge —— 什么都没删。`,
    detail: known
      ? `${mismatch.unitPath} 服务的是 ${known},而这次调用的是 ${plan.paths.home}。` +
        "unit 的 label 是每用户一个常量,所以拆掉它影响的是那个 home 的数据面 —— " +
        "而这次调用连那边的接管快照(还原依据)都看不见,放行等于蒙着眼睛动别人的东西。"
      : `${mismatch.unitPath} 在,但里面读不出它服务的那个 A2_HOME —— 本内核写的 unit 必然带着这个指纹` +
        "(内核那份写在 A2_HOME 里,mihomo 那份写在它跑的二进制路径里)," +
        "所以这份要么不是本内核写的、要么被改坏了。删除不可逆,不猜。",
    guidance: {
      // **不许指引「到那个 home 下重跑 --purge」**(18 票 CR 尾款抓到的死路):
      //   mismatch 在 18 票之后唯一可达的形态是「当前=缺省 home、unit 记着某个自定义 home」,
      //   而 `A2_HOME=<那个自定义 home> … --purge` 必然被 ⓪0 当场再拒一次(6)。
      //   照那句话走的人会来回撞两堵墙。三条都真能走通的路才配叫指引。
      summary: known
        ? "先把服务拆掉(那一条不挑 home);那个 home 的数据要不要清、怎么清由你自己决定。"
        : "先看一眼那份 unit 到底是什么,再决定手工处置还是重装一次收敛回来。",
      steps: known
        ? [
            { description: "先拆服务(不动任何数据,这条对任何 A2_HOME 都成立)", command: "a2 service uninstall" },
            {
              description: `确认无误后自行清理那个 home(这条会真的删)`,
              command: `rm -rf ${known}`,
            },
            { description: "缺省 home 的清理照常重跑(此时 unit 已不在,这道门自然让开)", command: "a2 service uninstall --purge" },
            { description: "确认当前这次调用用的是哪个 home", command: "a2 service status --json" },
          ]
        : [
            { description: "看那份 unit 的内容", command: `cat ${mismatch.unitPath}` },
            { description: "重装一次让它收敛回本内核写的形状(幂等)", command: "a2 service install" },
            { description: "只拆服务、不动数据", command: "a2 service uninstall" },
          ],
      context: {
        unitPath: mismatch.unitPath,
        label: mismatch.label,
        home: plan.paths.home,
        ...(known ? { installedHome: known } : {}),
      },
    },
  };
}

/**
 * `--purge` 撞上**系统代理仍处接管态**(17 票)。**拒绝即指引**,而且拒绝时零删除。
 *
 * 为什么不"顺手替他还原了再删":还原是一条**显式命令**(ADR 0008 的立场,`a2 proxy off` /
 * 面板的「关闭系统代理(还原)」)。一次卸载顺手改掉用户的网络配置,与"卸载"这个词承诺的事无关 ——
 * 而且真出了岔子(某个网络服务写不回去),人会在一次他以为只是"删文件"的操作里丢掉网络。
 *
 * detail 里带上快照说了什么(接管时间与指向的 host:port):人得知道"现在系统指着谁"才敢下一步。
 * 快照读不出来(文件坏了)照样拒绝 —— **判据是文件在不在**,不是它内容合不合法:
 * 一个解不开的还原依据仍然是还原依据,把它删掉同样是不可逆的。
 */
async function purgeBlockedError(paths: KernelPaths): Promise<WireError> {
  const file = snapshotPath(paths);
  const snapshot = await readSnapshot(paths);
  const pointing = snapshot
    ? `接管于 ${snapshot.takenOverAt || "(时间未记)"},当前把系统代理指向 ${snapshot.host}:${snapshot.port}`
    : "快照文件解不开(内容坏了),但它在 —— 还原依据仍然只有它一份";
  return {
    code: ErrorCode.servicePurgeBlocked,
    message: "系统代理仍由 a2 接管着,已拒绝 --purge —— 什么都没删。",
    detail:
      `${file} 还在:${pointing}。` +
      "这份快照是把系统代理还原回接管前的唯一依据,而 --purge 要删的正是整个 $A2_HOME —— " +
      "连它一起删掉,系统就会一直指着一个马上不存在的端口:当场断网,而且再也还原不回去。",
    guidance: {
      summary: "先显式还原系统代理,再来 purge。还原是一条独立命令 —— 内核不在卸载里替你改网络设置。",
      steps: [
        { description: "还原系统代理(命令行,不需要 daemon 在跑)", command: "a2 proxy off" },
        { description: "或在面板里点:菜单「关闭系统代理(还原)」" },
        { description: "还原之后再来一次", command: "a2 service uninstall --purge --json" },
        { description: "或者这次就只拆服务(数据与 $A2_HOME 原样留下)", command: "a2 service uninstall" },
      ],
      context: { home: paths.home, snapshotPath: file },
    },
  };
}

/**
 * `--purge` 时 a2 自管的 mihomo 拆不干净。与内核那条(`stillRunningError`)同一种姿势:
 * **进程还在就绝不往下删数据** —— 删掉它的配置与数据目录只会让一个还活着的 mihomo 变成孤魂。
 */
function mihomoStillRunningError(plan: ServicePlan, pid: number): WireError {
  return {
    code: ErrorCode.serviceOperationFailed,
    message: "已从 supervisor 卸下 a2 自管的 mihomo,但它的进程仍在运行 —— 已停在这一步,$A2_HOME 未删。",
    detail: `supervisor 仍报告 ${plan.label} 的 pid ${pid}。`,
    guidance: {
      summary: "确认那个进程是不是 a2 自管的那份,是则显式停掉它,然后重跑(幂等)。",
      steps: [
        { description: "看它是谁(**别停不属于 a2 的那份**)", command: `ps -p ${pid} -o pid,command` },
        { description: "确认是 a2 自管的那份后停掉它", command: `kill ${pid}` },
        { description: "重跑清理", command: "a2 service uninstall --purge" },
      ],
      context: { unitPath: plan.unitPath, label: plan.label, pid: String(pid) },
    },
  };
}

function stillRunningError(plan: ServicePlan, pid: number): WireError {
  return {
    code: ErrorCode.serviceOperationFailed,
    message: "已从 supervisor 卸下 unit,但进程仍在运行。",
    detail: `supervisor 仍报告 pid ${pid}。`,
    guidance: {
      summary: "确认那个进程是不是本内核,是则显式停掉它,然后重跑卸载(幂等)。",
      steps: [
        { description: "看它是谁", command: `ps -p ${pid} -o pid,command` },
        { description: "确认是本内核后停掉它", command: `kill ${pid}` },
        { description: "重跑卸载", command: "a2 service uninstall" },
      ],
      context: { unitPath: plan.unitPath, label: plan.label, pid: String(pid) },
    },
  };
}
