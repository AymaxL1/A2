// 三层仲裁的第③层:带外确认。
//
// 这个模块只回答一个问题:「这次 dangerous 调用,人到底同不同意?」——
// 它把一次调用挂起,把请求全文推给在场的确认器,然后等三件事之一发生:
//   * 有确认器 `confirmations.resolve`(批准 / 拒绝);
//   * 超时窗口到(**沉默不是同意**,超时即拒);
//   * **确认器全断线**(在场 = 长连接,人走了就没人能确认了)→ 立即按默拒收尾,不等超时;
//   * **发起方自己断线**(agent 被 Ctrl-C、CLI 进程被杀)→ 立即取消,不再打扰任何人。
//     这条同样重要:没有它,一次早已无人等待的调用照样会被人批准、handler 照样会执行副作用,
//     而那个答案没有任何去处 —— 「批了个没人要的东西」是最难解释的一类事故。
//
// 三条不变量,值得写在最前面:
//   1. **确认信息永不过 AI agent 之手**:发起方那条连接上只会收到"我转给人了、最多等这么久"
//      (`confirmation-pending`),以及最终的成败。它拿不到 confirmation id 以外的东西,
//      更没有任何报文能让它替人做决定 —— 决定只能来自**注册了 confirm-agent 角色的另一条连接**。
//   2. **默认拒绝**:每一条出口(超时、断线、内核自己出错)都收敛到拒绝;放行只有一条路,
//      就是确认器明说 approve。
//   3. **每一次都留痕**:requested → approved/denied/timed_out/downgraded,配对可查(见 `audit.ts`)。

import {
  confirmationDeniedError,
  confirmationTimeoutError,
  confirmationUnavailableError,
  type CapabilityInput,
} from "../capability/registry.ts";
import {
  ErrorCode,
  type ArbitrationState,
  type CapabilityDescriptor,
  type ConfirmationDecision,
  type PendingConfirmation,
  type WireError,
} from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import type { AuditLog } from "./audit.ts";
import type { ClientConnection, ClientHub } from "./hub.ts";

/** 确认超时的默认窗口。人要看清参数、走到菜单栏、再点一下 —— 两分钟是「人的尺度」。 */
export const DEFAULT_CONFIRM_TIMEOUT_MS = 120_000;
/** 覆写确认超时(毫秒)。测试与诊断用。 */
export const CONFIRM_TIMEOUT_ENV = "A2_CONFIRM_TIMEOUT_MS";

/** 一条挂起请求被通知给发起方时带的信息(由 router 转成 `confirmation-pending` 推送)。 */
export type PendingNotifier = (pending: PendingConfirmation, timeoutMs: number) => void;

export interface Arbiter {
  /** 确认超时窗口(毫秒)—— 客户端要靠它决定自己等多久,所以是对外事实。 */
  readonly timeoutMs: number;
  /** 第①层:没有确认器时的默拒报文(**顺带留痕**:审计里 `unavailable` 那一条就在这里产生)。 */
  refuseWithoutConfirmer(descriptor: CapabilityDescriptor): WireError;
  /**
   * 第③层:挂起、推给确认器、等决定。放行返回 undefined,四种拒绝各返回一条报文。
   * `requester` 是**发起这次调用的那条连接** —— 它断了,这次确认就没有意义了(见 `cancelFor`)。
   */
  confirm(
    descriptor: CapabilityDescriptor,
    input: CapabilityInput,
    notify: PendingNotifier,
    requester: ClientConnection,
  ): Promise<WireError | undefined>;
  /** 确认器做决定。返回 undefined = 成功;否则是一条说明"为什么这个决定不作数"的报文。 */
  resolve(
    confirmationId: string,
    decision: ConfirmationDecision,
    by: { connection: string; name?: string; uid?: number },
    reason?: string,
  ): WireError | undefined;
  /** 有连接注册/断开之后调用:确认器归零就立刻降级在途请求,并把仲裁面状态推出去。 */
  rosterChanged(except?: ClientConnection): void;
  /**
   * 某条连接断了:把**由它发起**的在途确认全部取消。
   *
   * 收场方式选的是**最简的那一种**(CR 允许二选一,如实记录):不新增事件族,
   * 取消照走 `finish` 的统一出口 —— 于是确认器会收到一条 `arbitration` 状态推送(待办列表少了一条)
   * 与一条 `audit`(`cancelled`);它若仍拿旧 id 来 `resolve`,拿到的是 `confirmation_unknown`,
   * 而那条报文早已写明「发起方已断开」是收场原因之一。这样契约形状一个字都不用改(09 票正在消费金标)。
   */
  cancelFor(connection: ClientConnection): void;
  /** 仲裁面此刻的状态(快照与 `arbitration.status` 都读它)。 */
  state(): ArbitrationState;
  /** daemon 收摊:在途请求一律按降级收尾,不留悬空的 promise。 */
  shutdown(): void;
}

interface PendingEntry {
  pending: PendingConfirmation;
  descriptor: CapabilityDescriptor;
  /** 发起这次调用的连接 —— 它断了就没人在等这个答案了。 */
  requester: ClientConnection;
  timer: ReturnType<typeof setTimeout>;
  /** 只会被调用一次(第一个到达的收场胜出);之后的决定一律 `confirmation_unknown`。 */
  settle: (refusal: WireError | undefined) => void;
}

export function createArbiter(options: {
  paths: KernelPaths;
  hub: ClientHub;
  audit: AuditLog;
  env?: Record<string, string | undefined>;
}): Arbiter {
  const { paths, hub, audit } = options;
  const env = options.env ?? process.env;
  const parsed = Number.parseInt(env[CONFIRM_TIMEOUT_ENV]?.trim() ?? "", 10);
  const timeoutMs = Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_CONFIRM_TIMEOUT_MS;

  const pendings = new Map<string, PendingEntry>();

  function state(): ArbitrationState {
    return {
      confirmerPresent: hub.confirmerCount() > 0,
      confirmers: hub.confirmerCount(),
      subscribers: hub.subscriberCount(),
      timeoutMs,
      pending: [...pendings.values()].map((entry) => entry.pending),
    };
  }

  function publishState(except?: ClientConnection): void {
    hub.broadcast({ kind: "arbitration", at: new Date().toISOString(), state: state() }, except);
  }

  /** 收场的唯一出口:摘挂起、停表、记账、推状态,然后把结果交回给挂起的那次 invoke。 */
  function finish(
    id: string,
    outcome: {
      action: "approved" | "denied" | "timed_out" | "downgraded" | "cancelled";
      refusal: WireError | undefined;
      detail?: string;
      client?: { connection: string; name?: string; uid?: number };
    },
  ): void {
    const entry = pendings.get(id);
    if (!entry) return;
    pendings.delete(id);
    clearTimeout(entry.timer);
    audit.record({
      action: outcome.action,
      capability: entry.pending.capability,
      confirmation: id,
      ...(outcome.detail === undefined ? {} : { detail: outcome.detail }),
      ...(outcome.client === undefined
        ? {}
        : {
            client: {
              role: "confirm-agent" as const,
              ...(outcome.client.name === undefined ? {} : { name: outcome.client.name }),
              ...(outcome.client.uid === undefined ? {} : { uid: outcome.client.uid }),
            },
          }),
    });
    publishState();
    entry.settle(outcome.refusal);
  }

  /** 第①层的报文 + 留痕。**函数而不是方法**:调用方解构走也不会因为 `this` 丢了而炸。 */
  function refuseWithoutConfirmer(descriptor: CapabilityDescriptor): WireError {
    const error = confirmationUnavailableError(descriptor, paths);
    audit.record({
      action: "unavailable",
      capability: descriptor.id,
      confirmation: crypto.randomUUID(),
      detail: "无确认器在场,fail-closed 默拒(ADR 0005 第 4 条第①层)。",
    });
    return error;
  }

  return {
    timeoutMs,

    refuseWithoutConfirmer,

    async confirm(descriptor, input, notify, requester) {
      // 防守一手:`confirmerPresent()` 与本调用之间理论上还有一个事件循环的缝。
      // 这里再问一次,把"挂起一个没人能收的请求"这条路彻底堵死(默认拒绝)。
      if (hub.confirmerCount() === 0) return refuseWithoutConfirmer(descriptor);

      const id = crypto.randomUUID();
      const requestedAt = new Date();
      const pending: PendingConfirmation = {
        id,
        capability: descriptor.id,
        risk: descriptor.risk,
        requestedAt: requestedAt.toISOString(),
        expiresAt: new Date(requestedAt.getTime() + timeoutMs).toISOString(),
      };

      const settled = new Promise<WireError | undefined>((resolve) => {
        const timer = setTimeout(() => {
          finish(id, {
            action: "timed_out",
            refusal: confirmationTimeoutError(descriptor, paths, timeoutMs),
            detail: `等待确认超过 ${timeoutMs}ms,沉默不构成同意。`,
          });
        }, timeoutMs);
        // 挂起的确认不该把 daemon 钉在事件循环上:该退的时候 shutdown() 会把它们按降级收尾。
        timer.unref?.();
        pendings.set(id, { pending, descriptor, requester, timer, settle: resolve });
      });

      audit.record({
        action: "requested",
        capability: descriptor.id,
        confirmation: id,
        detail: `已推给 ${hub.confirmerCount()} 个在场确认器,窗口 ${timeoutMs}ms。`,
      });

      // 先告诉发起方"我转给人了、最多等这么久" —— 它据此延长自己的等待,不必与内核共享环境变量。
      notify(pending, timeoutMs);
      // 再把**全文**(descriptor + 真实入参)推给确认器。这一份**只有确认器收得到**。
      hub.toConfirmers({
        kind: "confirmation",
        at: pending.requestedAt,
        request: {
          id,
          capability: descriptor.id,
          descriptor,
          input,
          requestedAt: pending.requestedAt,
          expiresAt: pending.expiresAt,
        },
      });
      publishState();

      return await settled;
    },

    resolve(confirmationId, decision, by, reason) {
      const entry = pendings.get(confirmationId);
      if (!entry) {
        return {
          code: ErrorCode.confirmationUnknown,
          message: `没有这条待确认请求(或它已经收场了):${confirmationId}`,
          detail:
            "确认请求可能已超时、已被别的确认器决定,或发起方已断开。" +
            "确认器应当以内核推来的 `arbitration` 事件为准刷新自己的待办列表。",
        };
      }
      finish(confirmationId, {
        action: decision === "approve" ? "approved" : "denied",
        refusal:
          decision === "approve"
            ? undefined
            : confirmationDeniedError(entry.descriptor, paths, reason),
        ...(reason === undefined ? {} : { detail: reason }),
        client: by,
      });
      return undefined;
    },

    rosterChanged(except) {
      // **在场 = 长连接**:确认器归零的那一刻,在途请求立即按默拒收尾 —— 不等超时、不留悬念。
      if (hub.confirmerCount() === 0) {
        for (const [id, entry] of [...pendings]) {
          finish(id, {
            action: "downgraded",
            refusal: confirmationUnavailableError(entry.descriptor, paths),
            detail: "确认器在请求挂起期间全部断开,立即降回默拒(在场 = 长连接)。",
          });
        }
      }
      publishState(except);
    },

    cancelFor(connection) {
      for (const [id, entry] of [...pendings]) {
        if (entry.requester !== connection) continue;
        finish(id, {
          action: "cancelled",
          // **必须给一条拒绝**:返回 undefined 会让 registry 认为"放行",handler 就跑了 ——
          // 而这次调用早已无人等待。报文本身没有去处(发起方的 socket 已经没了),
          // 复用默拒那一条即可,真相在审计的 `cancelled` 里。
          refusal: confirmationUnavailableError(entry.descriptor, paths),
          detail: "发起这次调用的连接已断开,确认请求随之取消 —— 没有人在等这个答案了。",
        });
      }
    },

    state,

    shutdown() {
      for (const [id, entry] of [...pendings]) {
        finish(id, {
          action: "downgraded",
          refusal: confirmationUnavailableError(entry.descriptor, paths),
          detail: "内核 daemon 停止,在途确认按默拒收尾。",
        });
      }
    },
  };
}
