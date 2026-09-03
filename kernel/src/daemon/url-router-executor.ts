// 机械执行器那一侧的**在场与往返**(url-router 施工 04 票,spec §5/§6.3)。
//
// 这个模块只回答两个问题:
//   * 「此刻有没有执行器在场?」——在场 = 注册了 `url-router-executor` 角色的长连接(与确认器同一条口径);
//   * 「这条执行指令,壳到底做成了什么样?」——下发一帧、等一个回执、有界。
//
// 它与 `arbitration.ts` 是**对等的两条路,不是一条路的两种模式**,分别写下来是有意的:
//
//   | | confirm-agent(arbitration.ts) | url-router-executor(本文件) |
//   |---|---|---|
//   | 推什么 | 请求全文(descriptor + input) | 执行指令(op / schemes / bundleID) |
//   | 对方做什么 | **替人做决定** | **照做,然后如实回报** |
//   | 收场语义 | approve / deny | 系统 API 的 completion 结果 |
//   | 谁在确认 | 人在壳的确认框上点 | 人在**操作系统自己的弹框**上点 |
//
// 三条不变量与仲裁那边逐字同源(它们是同一套安全直觉在两条链上的投影):
//   1. **首个收场胜出**:超时、回执、执行器断线,谁先到算谁的;迟到的回执拿 `url_router_execution_unknown`。
//   2. **沉默不是成功**:等满窗口就是 `timeout`,内核绝不因为"没人说不行"就报成功。
//   3. **在场 = 长连接**:执行器在指令在途时断线 → 立即按不可用收尾,不等超时(人已经走了,那个框没人点了)。
//
// 有一条**不**同源:这里没有"发起方断线就取消"。理由是这条链的副作用发生在**别人的机器状态**上 ——
// 指令已经下发、系统弹框可能已经在用户屏幕上了,取消一条内核这侧的等待并不能把框收回去。
// 于是发起方走了,内核照样把这一趟等完并如实记账(留痕在审计里),只是没人接那个答案。

import {
  ErrorCode,
  type KernelEvent,
  type UrlRouterExecuteCommand,
  type UrlRouterExecutorReportParams,
  type WireError,
} from "../contract/wire.ts";
import type { AuditLog } from "./audit.ts";
import type { ClientHub } from "./hub.ts";

/** 等系统弹框的窗口(spec §5:**120 秒**,人的尺度)。 */
export const DEFAULT_EXECUTION_TIMEOUT_MS = 120_000;
/** 覆写执行窗口(毫秒)。测试与诊断用,与 `A2_CONFIRM_TIMEOUT_MS` 同一档。 */
export const EXECUTION_TIMEOUT_ENV = "A2_URL_ROUTER_EXECUTION_TIMEOUT_MS";

/**
 * `open -b com.a2.panel` 之后等它注册上来的窗口(spec §5 的「壳未跑 → 拉起」那一步)。
 *
 * 10 秒:壳是个菜单栏小程序,冷启动到连上 UDS 在本机是百毫秒量级;给到 10 秒是留给
 * 「机器很忙 / Gatekeeper 头一次校验签名」这类真实的慢,再久就该如实说"它没起来"了。
 */
export const DEFAULT_LAUNCH_WAIT_MS = 10_000;
/** 覆写拉起等待窗(毫秒)。 */
export const LAUNCH_WAIT_ENV = "A2_URL_ROUTER_EXECUTOR_WAIT_MS";

/** 一次执行的收场。三种,与三条不变量一一对应。 */
export type ExecutionSettlement =
  /** 壳回话了(内容可能是成、是败、是取消 —— 那由调用方去映射)。 */
  | { kind: "reported"; report: UrlRouterExecutorReportParams }
  /** 等满窗口没人回话(沉默不是成功)。 */
  | { kind: "timeout" }
  /** 在途时执行器全部断线,或内核收摊。 */
  | { kind: "gone"; detail: string };

export interface UrlRouterExecutorHub {
  /** 执行窗口(毫秒)—— 指令帧上的 `timeoutSeconds` 由它换算,两处永远是同一个数。 */
  readonly timeoutMs: number;
  /** 拉起壳之后等它注册的窗口(毫秒)。 */
  readonly launchWaitMs: number;
  /** 此刻有没有执行器在场。**每次现问**(在场 = 长连接)。 */
  present(): boolean;
  /**
   * 等到有执行器在场为止(有界)。已经在场就立刻 `true`,等满窗口还没有就 `false`。
   *
   * 为什么不是轮询:注册那一刻 `rosterChanged()` 会把等在这里的人叫醒 —— 于是壳刚连上的那一毫秒
   * 编排就往下走了,而不是"再睡 200ms 看看"。
   */
  waitForPresence(timeoutMs: number): Promise<boolean>;
  /** 下发一帧执行指令并等回执(有界)。**调用前必须确认 `present()`**,否则直接 `gone`。 */
  dispatch(command: UrlRouterExecuteCommand): Promise<ExecutionSettlement>;
  /** 壳回话。返回 undefined = 收下;否则是一条说明"为什么这条回执不作数"的报文。 */
  report(
    params: UrlRouterExecutorReportParams,
    by: { connection: string; name?: string },
  ): WireError | undefined;
  /** 有连接注册/断开之后调用:执行器归零就立刻把在途指令收成 `gone`,并叫醒等在场的人。 */
  rosterChanged(): void;
  /** daemon 收摊:在途指令一律按 `gone` 收尾,不留悬空的 promise。 */
  shutdown(): void;
}

interface PendingExecution {
  command: UrlRouterExecuteCommand;
  timer: ReturnType<typeof setTimeout>;
  /** 只会被调用一次(第一个到达的收场胜出)。 */
  settle: (settlement: ExecutionSettlement) => void;
}

export function createUrlRouterExecutorHub(options: {
  hub: ClientHub;
  audit: AuditLog;
  env?: Record<string, string | undefined>;
}): UrlRouterExecutorHub {
  const { hub, audit } = options;
  const env = options.env ?? process.env;
  const timeoutMs = positiveEnv(env[EXECUTION_TIMEOUT_ENV], DEFAULT_EXECUTION_TIMEOUT_MS);
  const launchWaitMs = positiveEnv(env[LAUNCH_WAIT_ENV], DEFAULT_LAUNCH_WAIT_MS);

  const pendings = new Map<string, PendingExecution>();
  /** 正等着"有执行器进场"的人(注册那一刻一并叫醒)。 */
  const presenceWaiters = new Set<() => void>();

  function present(): boolean {
    return hub.executorCount() > 0;
  }

  /** 收场的唯一出口:摘挂起、停表、记账,然后把结果交回给挂起的那次编排。 */
  function finish(id: string, settlement: ExecutionSettlement, detail: string): void {
    const entry = pendings.get(id);
    if (!entry) return;
    pendings.delete(id);
    clearTimeout(entry.timer);
    audit.record({
      // 执行指令的收场借用**已有的**审计动作词表(`approved` / `timed_out` / `downgraded`):
      // 它们说的正是同三件事(办成了 / 没人点 / 人不在了),而 `detail` 里写着这是哪一条链。
      action:
        settlement.kind === "reported"
          ? "approved"
          : settlement.kind === "timeout"
            ? "timed_out"
            : "downgraded",
      capability: `url-router.executor:${entry.command.op}`,
      confirmation: id,
      detail,
    });
    entry.settle(settlement);
  }

  return {
    timeoutMs,
    launchWaitMs,
    present,

    async waitForPresence(waitMs) {
      if (present()) return true;
      if (waitMs <= 0) return false;
      return await new Promise<boolean>((resolve) => {
        let settled = false;
        const done = (value: boolean) => {
          if (settled) return;
          settled = true;
          presenceWaiters.delete(wake);
          clearTimeout(timer);
          resolve(value);
        };
        // 被叫醒时**现问一次**在场,而不是无条件报 true:`shutdown()` 也会叫醒等在这儿的人,
        // 那一次的真话是"没有,而且不会有了"。
        const wake = () => done(present());
        const timer = setTimeout(() => done(false), waitMs);
        // 等一个可能永远不来的壳,不该把 daemon 钉在事件循环上。
        timer.unref?.();
        presenceWaiters.add(wake);
        // 防守一手:上面那次 `present()` 与这次登记之间理论上还有一个事件循环的缝。
        if (present()) done(true);
      });
    },

    async dispatch(command) {
      if (!present()) {
        return { kind: "gone", detail: "下发之前执行器就已经不在场了。" };
      }

      const settled = new Promise<ExecutionSettlement>((resolve) => {
        const timer = setTimeout(() => {
          finish(
            command.id,
            { kind: "timeout" },
            `等系统弹框的结果超过 ${timeoutMs}ms,沉默不构成成功。`,
          );
        }, timeoutMs);
        timer.unref?.();
        pendings.set(command.id, { command, timer, settle: resolve });
      });

      audit.record({
        action: "requested",
        capability: `url-router.executor:${command.op}`,
        confirmation: command.id,
        detail:
          `已下发执行指令帧给 ${hub.executorCount()} 个在场执行器:` +
          `${command.op} bundleID=${command.bundleID} schemes=${command.schemes.join("+")},窗口 ${timeoutMs}ms。`,
      });

      // **只推给执行器**(与 `confirmation` 只推给确认器同一条纪律)。
      const event: KernelEvent = {
        kind: "url-router-execute",
        at: new Date().toISOString(),
        command,
      };
      hub.toExecutors(event);

      return await settled;
    },

    report(params, by) {
      const entry = pendings.get(params.execution);
      if (!entry) {
        return {
          code: ErrorCode.urlRouterExecutionUnknown,
          message: `没有这条待执行指令(或它已经收场了):${params.execution}`,
          detail:
            "指令可能已超时、已被同一个执行器回过一次,或内核已经不在等它了。" +
            "**首个回话收场胜出** —— 迟到的那一条不会改写已经收场的结果。",
          guidance: {
            summary: "这条回执没有去处。执行器应当以内核推来的 `url-router-execute` 事件为准,一条指令只回一次。",
            steps: [
              { description: "确认这条指令的 id 来自最近一次 `url-router-execute` 推送" },
              {
                description: "要知道系统 handler 此刻到底是谁,直接问内核",
                command: "a2 url-router status --json",
              },
            ],
            context: { execution: params.execution, by: by.name ?? by.connection },
          },
        };
      }
      finish(
        params.execution,
        { kind: "reported", report: params },
        `执行器 ${by.name ?? by.connection} 回执:outcome=${params.outcome}` +
          `${params.error === undefined ? "" : `,${params.error}`}`,
      );
      return undefined;
    },

    rosterChanged() {
      if (present()) {
        // 有人进场了 —— 叫醒所有等在 `waitForPresence` 上的编排(拉起壳那一步靠它收工)。
        for (const wake of [...presenceWaiters]) wake();
        return;
      }
      // **在场 = 长连接**:执行器归零的那一刻,在途指令立即收尾 —— 不等 120s。
      // 那个系统弹框可能还在屏幕上,但没有人能把结果告诉我们了,继续等只是让发起方多站两分钟。
      for (const id of [...pendings.keys()]) {
        finish(
          id,
          { kind: "gone", detail: "执行器在指令在途期间断开(在场 = 长连接)。" },
          "执行器在指令在途期间全部断开,立即按不可用收尾。",
        );
      }
    },

    shutdown() {
      for (const id of [...pendings.keys()]) {
        finish(
          id,
          { kind: "gone", detail: "内核 daemon 停止。" },
          "内核 daemon 停止,在途执行指令按不可用收尾。",
        );
      }
      for (const wake of [...presenceWaiters]) wake();
      presenceWaiters.clear();
    },
  };
}

function positiveEnv(raw: string | undefined, fallback: number): number {
  const parsed = Number.parseInt(raw?.trim() ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}
