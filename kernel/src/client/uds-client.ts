// UDS 客户端:连上 → 写一行请求 → 读到自己的那一行响应 → 关连接。
//
// 连不上**不是**一种响应,而是一类客户端侧事实(daemon 未装/未起/socket 陈旧),
// 由调用方翻译成「拒绝即指引」报文 —— 客户端**永不隐式拉起** daemon(ADR 0008 第 6 条)。
//
// 08 票起这条连接上不只有响应:内核可能先推一帧 `confirmation-pending`
// (「你这条 dangerous 调用我转给人了,最多等 N 毫秒」)。所以读取从"只认第一行"变成
// **"读到响应包封为止,推送帧顺路处理"**。
//
// 这条设计解掉的是一个真问题:确认窗口是**内核**的配置,而超时判定发生在**客户端**。
// 让客户端去猜(或去读同一个环境变量)迟早会两边不一致 —— 一致性由**协议**保证:
// 内核先说"最多这么久",客户端据此把自己的截止时间往后推,不共享任何进程外的约定。

import { LineBuffer } from "../contract/ndjson.ts";
import {
  ServerFrameSchema,
  encodeFrame,
  type RequestEnvelope,
  type ResponseEnvelope,
} from "../contract/wire.ts";

/** socket 连不上 / 连上又断了 —— 一律归为「daemon 不可达」。 */
export class DaemonUnreachableError extends Error {
  constructor(readonly detail: string) {
    super(`daemon 不可达:${detail}`);
    this.name = "DaemonUnreachableError";
  }
}

/** 连上了但对方说的不是我们的协议(响应非 JSON 或不符包封 schema)。 */
export class ProtocolViolationError extends Error {
  constructor(readonly detail: string) {
    super(`响应不符合线协议:${detail}`);
    this.name = "ProtocolViolationError";
  }
}

/** 内核说"我在等人点头"之后,客户端在它承诺的窗口之外再多给的余量(网络与调度的毛边)。 */
export const PENDING_GRACE_MS = 3000;

/**
 * 发一条请求、收一条响应。超时按不可达处理(daemon 卡死与不在,对调用方是同一件事:这条路走不通)。
 *
 * `timeoutMs` 是**默认**截止时间;若内核推来 `confirmation-pending`,截止时间按它承诺的窗口顺延。
 */
export async function requestOnce(
  socketPath: string,
  message: RequestEnvelope,
  timeoutMs = 5000,
): Promise<ResponseEnvelope> {
  let resolveResponse!: (envelope: ResponseEnvelope) => void;
  let rejectResponse!: (error: Error) => void;
  const settled = new Promise<ResponseEnvelope>((resolve, reject) => {
    resolveResponse = resolve;
    rejectResponse = reject;
  });

  let timer: ReturnType<typeof setTimeout> | undefined;
  let waiting = timeoutMs;
  function armTimer(ms: number): void {
    if (timer) clearTimeout(timer);
    waiting = ms;
    timer = setTimeout(() => rejectResponse(new DaemonUnreachableError(`等响应超时(${ms}ms)`)), ms);
  }

  const lines = new LineBuffer();

  /** 一帧进来:是响应就收工;是"我在等人点头"就把截止时间往后推;别的推送与一问一答无关,忽略。 */
  function consume(line: string): void {
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      rejectResponse(new ProtocolViolationError(`响应不是合法 JSON:${JSON.stringify(line)}`));
      return;
    }
    const frame = ServerFrameSchema.safeParse(parsed);
    if (!frame.success) {
      rejectResponse(new ProtocolViolationError(frame.error.message));
      return;
    }
    if (!("push" in frame.data)) {
      resolveResponse(frame.data);
      return;
    }
    const event = frame.data.event;
    if (event.kind === "confirmation-pending" && event.requestId === message.id) {
      armTimer(event.timeoutMs + PENDING_GRACE_MS);
    }
  }

  let socket: Awaited<ReturnType<typeof Bun.connect>>;
  try {
    socket = await Bun.connect({
      unix: socketPath,
      socket: {
        data(_socket, chunk) {
          // **喂字节,不喂字符串**:分片边界可能切在多字节字符中间,先 toString 就会静默污损
          // (11KB 的快照必然分片到达,而报文里全是中文 —— 见 `contract/ndjson.ts` 文件头)。
          for (const line of lines.push(chunk)) consume(line);
        },
        error(_socket, error) {
          rejectResponse(new DaemonUnreachableError(String(error)));
        },
        close() {
          rejectResponse(
            new DaemonUnreachableError(
              lines.pending.length === 0
                ? "连接被关闭,未收到响应"
                : `连接被关闭,响应不完整:${JSON.stringify(lines.pending)}`,
            ),
          );
        },
      },
    });
  } catch (error) {
    throw new DaemonUnreachableError(String(error));
  }

  armTimer(waiting);
  try {
    socket.write(encodeFrame(message));
    return await settled;
  } finally {
    if (timer) clearTimeout(timer);
    socket.end();
  }
}
