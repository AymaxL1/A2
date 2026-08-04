// `a2 service install|uninstall|status` 的实体:把「系统托管常驻」这件事收敛到一条命令。
//
// 深模块的边界:调用方(CLI)只拿到**一种东西** —— 一个 `OpOutcome`(成了带 result,没成带 WireError)。
// 平台差异、命令编排、幂等判定、失败指引全在这一层里消化掉。
//
// 幂等口径(票面第 1 条):三条命令都是**收敛**语义 —— 说的是"我要它是这个样子",不是"执行这几步"。
// 已经是那个样子就什么都不做,`actions` 为空数组;这就是幂等的可观察面(不必比对前后状态)。
//
// 「CLI 永不隐式拉起 daemon」不因本票而破:`install` 是**人类显式授权**的动作,由它把常驻交给系统
// supervisor 是合法的;`status` 只读;其余任何命令仍然只 connect、从不 spawn。

import { existsSync } from "node:fs";
import path from "node:path";
import { callKernel } from "../client/kernel-client.ts";
import {
  ErrorCode,
  Op,
  opFailure,
  opSuccess,
  type OpOutcome,
  type ServiceAction,
  type ServiceStatusResult,
  type WireError,
} from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { convergeUnit, removeUnit, SETTLE_POLL_MS } from "./converge.ts";
import {
  createSupervisor,
  SupervisorCommandError,
  type SupervisorState,
  type UnitAction,
} from "./supervisor.ts";
import {
  resolveSupervisorKind,
  servicePlan,
  STDERR_LOG_NAME,
  STDOUT_LOG_NAME,
  type ServicePlan,
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

export async function serviceInstall(paths: KernelPaths): Promise<OpOutcome> {
  return await withPlan(paths, async (plan) => {
    const supervisor = createSupervisor(plan);
    const { actions, state } = await convergeUnit(plan, supervisor);

    if (state.pid === undefined) {
      return opFailure(notRunningError(plan));
    }
    // 有 pid ≠ 能用。等它在 socket 上真的应答,`install` 才算兑现"装完就是跑着的"。
    if (!(await settleDaemonReachable(plan))) {
      return opFailure(notAnsweringError(plan));
    }

    return opSuccess({ status: statusResult(plan, state), actions: kernelActions(actions) });
  });
}

export async function serviceUninstall(paths: KernelPaths): Promise<OpOutcome> {
  return await withPlan(paths, async (plan) => {
    const supervisor = createSupervisor(plan);
    // 卸载的承诺是"干净移除",所以要真的确认进程没了 —— 否则下一次 install 会撞上一个野生实例。
    const { actions, state } = await removeUnit(plan, supervisor);
    if (state.pid !== undefined) {
      return opFailure(stillRunningError(plan, state.pid));
    }

    return opSuccess({ status: statusResult(plan, state), actions: kernelActions(actions) });
  });
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

/** 三条命令共用的前置:选 supervisor → 算 plan → 把两类失败(平台不支持 / 命令失败)翻成 WireError。 */
async function withPlan(
  paths: KernelPaths,
  body: (plan: ServicePlan) => Promise<OpOutcome>,
): Promise<OpOutcome> {
  const choice = resolveSupervisorKind();
  if (!choice.ok) return opFailure(unsupportedPlatformError(choice.reason, paths));

  const plan = servicePlan(choice.kind, paths);
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
    registered: state.registered,
    ...(state.pid === undefined ? {} : { pid: state.pid }),
    home: plan.paths.home,
    socketPath: plan.paths.socketPath,
  };
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
