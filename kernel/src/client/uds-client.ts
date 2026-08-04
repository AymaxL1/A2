// UDS 客户端:连上 → 写一行请求 → 读一行响应 → 关连接。
//
// 连不上**不是**一种响应,而是一类客户端侧事实(daemon 未装/未起/socket 陈旧),
// 由调用方翻译成「拒绝即指引」报文 —— 客户端**永不隐式拉起** daemon(ADR 0008 第 6 条)。

import { LineBuffer } from "../contract/ndjson.ts";
import {
  ResponseEnvelopeSchema,
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

/** 发一条请求、收一条响应。超时按不可达处理(daemon 卡死与不在,对调用方是同一件事:这条路走不通)。 */
export async function requestOnce(
  socketPath: string,
  message: RequestEnvelope,
  timeoutMs = 5000,
): Promise<ResponseEnvelope> {
  let resolveLine!: (line: string) => void;
  let rejectLine!: (error: Error) => void;
  const firstLine = new Promise<string>((resolve, reject) => {
    resolveLine = resolve;
    rejectLine = reject;
  });

  const lines = new LineBuffer();
  let socket: Awaited<ReturnType<typeof Bun.connect>>;
  try {
    socket = await Bun.connect({
      unix: socketPath,
      socket: {
        data(_socket, chunk) {
          // 一问一答:只认第一行,余料留给 08 票的长连接形态。
          const [first] = lines.push(chunk.toString());
          if (first !== undefined) resolveLine(first);
        },
        error(_socket, error) {
          rejectLine(new DaemonUnreachableError(String(error)));
        },
        close() {
          rejectLine(
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

  const timer = setTimeout(
    () => rejectLine(new DaemonUnreachableError(`等响应超时(${timeoutMs}ms)`)),
    timeoutMs,
  );
  let line: string;
  try {
    socket.write(encodeFrame(message));
    line = await firstLine;
  } finally {
    clearTimeout(timer);
    socket.end();
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch (error) {
    throw new ProtocolViolationError(`响应不是合法 JSON:${JSON.stringify(line)}`);
  }
  const result = ResponseEnvelopeSchema.safeParse(parsed);
  if (!result.success) {
    throw new ProtocolViolationError(result.error.message);
  }
  return result.data;
}
