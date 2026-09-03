// 测试夹具:一个**长连接客户端**(假确认器 / 假订阅者)。
//
// 它是 08 票协议面的被测缝:注册角色、收全量快照、收增量推送、回一个确认决定。
// 门禁里没有真的菜单栏壳(那是 10 票),但协议不该等壳出来才有活体验证 —— 这个夹具就是那个替身。
//
// **有意不复用 `src/` 里的任何一行**(与 `harness.ts` 同一条纪律,04 票 CR 尾款 f 定的口径):
// 拆行、帧判别、请求-响应相关性,这里全部手写一遍。用被测代码去读被测代码的输出,写歪了会一起歪。
// 判别帧的规则也刻意手写成"有 ok 的是响应、有 push 的是推送",这样契约若改了判别方式,这里会吵。
// 拆行**在字节层面**(整行到齐才 decode):快照报文十几 KB 且全是中文,分片边界切进汉字中间时,
// 先 `toString()` 的写法会静默解出 U+FFFD —— 那正是 08 票 CR 抓到的实现侧缺陷,夹具不能陪着一起错。

import { setTimeout as delay } from "node:timers/promises";

/** 收到确认请求时这个假确认器怎么办。`ignore` 是给超时那条断言用的(沉默不构成同意)。 */
export type ConfirmBehavior = "approve" | "deny" | "ignore";

/**
 * 收到**执行指令帧**时这个假执行器怎么办(url-router 施工 04 票)。
 *
 * 它站的正是真壳的位置,只是**手里没有系统 API** —— 于是门禁能验完"下发 → 执行 → 回执"整条链,
 * 而永远不会真的改掉跑测试这台机器的默认浏览器、也永远不会弹出一个系统框。
 *
 *   * `confirmed` —— 两个 scheme 都成(用户在两个框上都点了「使用」);
 *   * `denied`    —— 用户点了取消;
 *   * `partial`   —— 一个成一个没成(http 与 https 是两次独立的框,这是 spec §5 明写的一种收场);
 *   * `ignore`    —— **一个字都不回**(验内核那侧的 120s 窗与"沉默不是成功")。
 */
export type ExecuteBehavior = "confirmed" | "denied" | "partial" | "ignore";

export interface FakeClientOptions {
  socketPath: string;
  /** 自报的名字(**不构成身份**;内核只把它记进审计)。 */
  name?: string;
  /** 注册报文里的加固字段。V1 内核不校验 —— 有断言证明"填了也不会被当真"。 */
  codeDirectoryHash?: string;
  teamIdentifier?: string;
  /** 只对确认器有意义。 */
  behavior?: ConfirmBehavior;
  /** 拒绝时给的理由(进审计与拒绝报文)。 */
  reason?: string;
  /** 只对执行器有意义(缺省 `ignore`:没注册执行器角色的客户端本来也收不到指令帧)。 */
  executeBehavior?: ExecuteBehavior;
}

export interface FakeClient {
  /** 在这条连接上注册一个角色,返回内核回的 result(含全量快照)。 */
  register(role: "confirm-agent" | "subscriber" | "url-router-executor"): Promise<any>;
  /** 在这条连接上发一条普通请求,拿它的响应包封。 */
  request(op: string, params?: Record<string, unknown>): Promise<any>;
  /** 至今收到的全部推送事件(按到达顺序)。 */
  events(kind?: string): any[];
  /** 等一个满足条件的推送事件(默认 5s)。 */
  waitForEvent(predicate: (event: any) => boolean, timeoutMs?: number): Promise<any>;
  /** 这个假确认器至今回过的决定(便于断言"它确实被问过")。 */
  resolved: { confirmation: string; decision: ConfirmBehavior }[];
  /** 这个假执行器至今回过的执行结果(便于断言"指令确实下发到了它手上")。 */
  executed: { execution: string; outcome: string }[];
  /**
   * 帧的**到达顺序**(`push` / `response`)。「快照即基线,此后才是增量」这条协议保证靠它:
   * 注册连接收到的第一帧必须是自己那条响应,不能先来一条推送。
   */
  arrivals: ("push" | "response")[];
  /**
   * 这个客户端**主动发出去过的每一条 op**。「零轮询」这条断言就靠它:
   * 订阅者除了那一次 `roles.register` 之外一条请求都不该发,却照样收得到状态变化。
   */
  sent: string[];
  close(): Promise<void>;
}

export async function connectFakeClient(options: FakeClientOptions): Promise<FakeClient> {
  const name = options.name ?? "fake-client";
  const behavior = options.behavior ?? "ignore";
  const executeBehavior = options.executeBehavior ?? "ignore";

  const executed: { execution: string; outcome: string }[] = [];
  const pushEvents: any[] = [];
  const sent: string[] = [];
  /** 到达顺序(`"push"` / `"response"`)—— 「快照即基线」那条断言靠它:第一帧必须是注册响应。 */
  const arrivals: ("push" | "response")[] = [];
  const resolved: { confirmation: string; decision: ConfirmBehavior }[] = [];
  const waiters: { predicate: (event: any) => boolean; resolve: (event: any) => void }[] = [];
  const inflight = new Map<string, (envelope: any) => void>();
  let closed = false;
  let buffer = new Uint8Array(0);
  const decoder = new TextDecoder();

  const socket = await Bun.connect({
    unix: options.socketPath,
    socket: {
      data(_socket, chunk) {
        const merged = new Uint8Array(buffer.length + chunk.length);
        merged.set(buffer, 0);
        merged.set(chunk, buffer.length);
        buffer = merged;
        let newline = buffer.indexOf(0x0a);
        while (newline >= 0) {
          // **整行到齐了才 decode**(手写第二份,理由见文件头)。
          const line = decoder.decode(buffer.subarray(0, newline));
          buffer = buffer.slice(newline + 1);
          if (line.trim().length > 0) accept(line);
          newline = buffer.indexOf(0x0a);
        }
      },
      close() {
        closed = true;
      },
    },
  });

  function accept(line: string): void {
    let frame: any;
    try {
      frame = JSON.parse(line);
    } catch {
      throw new Error(`假客户端收到不是 JSON 的一帧:${line}`);
    }
    // 手写的帧判别:有 push 的是推送,有 ok 的是响应。两者永不同时出现。
    if (frame.push === true) {
      arrivals.push("push");
      pushEvents.push(frame.event);
      for (let index = waiters.length - 1; index >= 0; index -= 1) {
        const waiter = waiters[index]!;
        if (waiter.predicate(frame.event)) {
          waiters.splice(index, 1);
          waiter.resolve(frame.event);
        }
      }
      if (frame.event?.kind === "confirmation" && behavior !== "ignore") {
        void answer(frame.event.request.id);
      }
      if (frame.event?.kind === "url-router-execute" && executeBehavior !== "ignore") {
        void execute(frame.event.command);
      }
      return;
    }
    arrivals.push("response");
    const settle = inflight.get(frame.id);
    if (settle) {
      inflight.delete(frame.id);
      settle(frame);
    }
  }

  function write(op: string, params?: Record<string, unknown>): Promise<any> {
    sent.push(op);
    const id = crypto.randomUUID();
    const message: Record<string, unknown> = { v: 1, id, op };
    if (params !== undefined) message.params = params;
    const answered = new Promise<any>((resolve, reject) => {
      inflight.set(id, resolve);
      void delay(5000).then(() => {
        if (inflight.delete(id)) reject(new Error(`假客户端等 ${op} 的响应超时`));
      });
    });
    socket.write(`${JSON.stringify(message)}\n`);
    return answered;
  }

  async function answer(confirmation: string): Promise<void> {
    const decision = behavior === "approve" ? "approve" : "deny";
    resolved.push({ confirmation, decision: behavior });
    await write("confirmations.resolve", {
      confirmation,
      decision,
      ...(options.reason === undefined ? {} : { reason: options.reason }),
    });
  }

  /**
   * 照剧本回一条执行回执。**这里没有一个判断是关于"该不该做"的** —— 真壳也一样:
   * 它收到帧就调系统 API,把 completion 原样送回来。剧本决定的是"系统会怎么答",不是"壳怎么想"。
   *
   * 那三个 NSError 字段是**编的**:真机上用户取消时的 domain/code 归 06 票实测回填(spec §11),
   * 在那之前没有人编造它 —— 这里只用来验"原样带出来",不用来验"内核怎么认出取消"
   * (内核认的是 `outcome`,不是 domain/code)。
   */
  async function execute(command: any): Promise<void> {
    const outcome = executeBehavior === "partial" ? "confirmed" : executeBehavior;
    const failure = {
      ok: false,
      error: { domain: "假件域", code: -1, description: "假件造的一条错误(真机域/码归 06 票)" },
    };
    const perScheme =
      executeBehavior === "confirmed"
        ? { http: { ok: true }, https: { ok: true } }
        : executeBehavior === "partial"
          ? { http: { ok: true }, https: failure }
          : { http: failure, https: failure };
    executed.push({ execution: command.id, outcome });
    await write("url-router.executor.report", {
      execution: command.id,
      outcome,
      perScheme,
      ...(executeBehavior === "denied" ? { error: "用户在系统弹框上点了取消" } : {}),
    });
  }

  return {
    resolved,
    executed,
    sent,
    arrivals,
    async register(role) {
      const response = await write("roles.register", {
        role,
        identity: {
          name,
          version: "0.0.0-fake",
          ...(options.codeDirectoryHash === undefined
            ? {}
            : { codeDirectoryHash: options.codeDirectoryHash }),
          ...(options.teamIdentifier === undefined
            ? {}
            : { teamIdentifier: options.teamIdentifier }),
        },
      });
      if (!response.ok) {
        throw new Error(`假客户端注册 ${role} 失败:${JSON.stringify(response.error)}`);
      }
      return response.result;
    },
    request: write,
    events: (kind) => (kind ? pushEvents.filter((event) => event.kind === kind) : [...pushEvents]),
    waitForEvent(predicate, timeoutMs = 5000) {
      const already = pushEvents.find(predicate);
      if (already) return Promise.resolve(already);
      return new Promise((resolve, reject) => {
        const waiter = { predicate, resolve };
        waiters.push(waiter);
        void delay(timeoutMs).then(() => {
          const index = waiters.indexOf(waiter);
          if (index >= 0) {
            waiters.splice(index, 1);
            reject(
              new Error(
                `假客户端等推送事件超时(${timeoutMs}ms)。至今收到:${JSON.stringify(
                  pushEvents.map((event) => event.kind),
                )}`,
              ),
            );
          }
        });
      });
    },
    async close() {
      if (closed) return;
      socket.end();
      // 让内核那侧真的处理完 close 回调(角色离场、在途确认降级)再往下走。
      await delay(50);
    },
  };
}
