// 一条连接的**唯一写出口**(响应与推送都走它)。三件事必须由它统一管:
//
// 1. **半写**。`socket.write()` 只保证"能写多少写多少",返回实际写进去的**字节数**;剩下的**不会**
//    被自动缓冲。快照报文十几 KB,一次写不完是常态 —— 不接住就是"报文被截断"(08 票实测踩到:
//    注册响应写到一半没了,客户端读到半个 JSON)。剩料留在队列里,等 `drain` 再续。
// 2. **顺序**。推送是内核随时发起的,响应是排队产出的;两者若各写各的,先来的半截会被后来的插队。
//    统一从一个队列出去,先进先出。
// 3. **背压有上限**。一个连上来就不读的订阅者(卡死的壳、被 SIGSTOP 的进程)会让积压无限长大,
//    最终是内核自己 OOM —— 那是**别人的故障拖垮内核**。所以队列有字节上限,超了就判定为
//    **慢消费者**:断连 + 留痕。在"零轮询 + 全量快照"的模型下这是正确收场 —— 它重连时会拿到
//    一份新的全量快照,不会因为丢了中间那些增量而错乱。
//
// 缓冲用 `Uint8Array` 而不是字符串:`write` 的返回值是字节数,而报文里全是中文 ——
// 按字符切会切碎多字节序列。队列是**数组 + 游标**,`send` 摊还 O(1)(不是每次 concat 出一整块新缓冲)。

/** 积压上限(字节)。给到 4 MiB:正常订阅者永远碰不到,卡死的那个几百条事件内就会撞上。 */
export const DEFAULT_BACKLOG_LIMIT_BYTES = 4 * 1024 * 1024;

/** 只需要 `write` 的那一点点 socket 面 —— 这样写队列可以脱离真 socket 单测。 */
export interface WritableSocket {
  write(data: Uint8Array): number;
}

export interface FrameWriter {
  /** 排一帧出去(立即尝试冲刷)。 */
  send(frame: string): void;
  /** 内核缓冲腾出来了,把没写完的续上(挂在 socket 的 `drain` 上)。 */
  flush(): void;
  /** 当前积压字节数(诊断与断言用)。 */
  readonly backlogBytes: number;
}

export function createFrameWriter(
  socket: WritableSocket,
  options: {
    /** 积压超限时叫一次(调用方负责断连 + 留痕);叫过之后本写出口就废了,不再接收新帧。 */
    onOverflow?: (bytes: number, limit: number) => void;
    limitBytes?: number;
  } = {},
): FrameWriter {
  const encoder = new TextEncoder();
  const limit = options.limitBytes ?? DEFAULT_BACKLOG_LIMIT_BYTES;

  /** 待写队列。`head` 是当前正在写的那块,`offset` 是它已经写出去多少字节。 */
  const queue: Uint8Array[] = [];
  let head = 0;
  let offset = 0;
  let bytes = 0;
  let dead = false;

  function flush(): void {
    while (!dead && head < queue.length) {
      const chunk = queue[head] as Uint8Array;
      const rest = offset === 0 ? chunk : chunk.subarray(offset);
      let written = 0;
      try {
        written = socket.write(rest);
      } catch {
        // 对端已断,这些字节没有去处了。
        discard();
        return;
      }
      if (written <= 0) return; // 缓冲满了,等 drain。
      bytes -= written;
      if (written >= rest.length) {
        head += 1;
        offset = 0;
      } else {
        offset += written;
        return; // 只写进去一部分 = 缓冲已满,别空转。
      }
    }
    // 队列排空,把数组也收掉(否则 head 一直涨,数组永不释放)。
    discard();
  }

  function discard(): void {
    queue.length = 0;
    head = 0;
    offset = 0;
    bytes = 0;
  }

  return {
    send(frame) {
      if (dead) return;
      const encoded = encoder.encode(frame);
      queue.push(encoded);
      bytes += encoded.length;
      flush();
      if (bytes > limit) {
        // 冲刷完还这么多 = 对端不读。判定慢消费者,交给调用方收场。
        dead = true;
        const overflow = bytes;
        discard();
        options.onOverflow?.(overflow, limit);
      }
    },
    flush,
    get backlogBytes() {
      return bytes;
    },
  };
}
