// NDJSON 拆行 —— 帧边界这件事,全内核只有这一份实现。
//
// TCP/UDS 上一次 `data` 回调可能带来半行、一行或好几行,拆行逻辑写歪了就是"偶发丢报文"。
//
// **必须在字节层面拆行**(08 票 CR 修的一处真缺陷)。原来的写法是每片先 `chunk.toString()` 再按 `\n` 切:
// 报文全是 ASCII 时没事,但本内核的报文里全是中文 —— 一个汉字 3 个 UTF-8 字节,而分片边界**落在哪儿
// 完全由内核缓冲说了算**(11KB 的快照必然分好几片到达)。边界一旦切进某个汉字中间,那一片的
// `toString()` 就把半个字符解成 U+FFFD,拼回去也回不来 —— 报文**静默污损**,且只在报文够大、
// 内容够"中文"时才出现,是最难查的那类偶发。
//
// 所以:**缓冲字节,按 `\n`(0x0A)切,整行到齐了才 decode**。分片边界与字符边界从此互不相干。
//
// 注:测试夹具 `test/support/harness.ts` 与 `test/support/fake-client.ts` **有意**不用本模块
// (理由见那两个文件的头注),它们是独立事实源,不是重复 —— 它们各自也在字节层面拆。

const DECODER = new TextDecoder();
const ENCODER = new TextEncoder();
/** 换行符的字节值。帧边界只认它。 */
const NEWLINE = 0x0a;

/** 收字节、吐完整行。未收尾的残料留在内部缓冲里等下一片。 */
export class LineBuffer {
  #buffer = new Uint8Array(0);

  /**
   * 吃一片数据,返回其中**已完整**的行(不含 '\n');空白行被丢弃(NDJSON 的凑数行不是报文)。
   *
   * 接受字节或字符串:socket 给的是字节(那是主路径),字符串入口留给单测与手搓样本。
   * **传进来的字节一律被复制**——Bun 的 socket 缓冲是复用的,留引用会在下一片到达时被改写。
   */
  push(chunk: Uint8Array | string): string[] {
    const bytes = typeof chunk === "string" ? ENCODER.encode(chunk) : chunk;
    if (bytes.length === 0) return [];

    const merged = new Uint8Array(this.#buffer.length + bytes.length);
    merged.set(this.#buffer, 0);
    merged.set(bytes, this.#buffer.length);

    const lines: string[] = [];
    let start = 0;
    for (let index = 0; index < merged.length; index += 1) {
      if (merged[index] !== NEWLINE) continue;
      // 整行到齐了才解码 —— 这一步是本文件存在的理由。
      const line = DECODER.decode(merged.subarray(start, index));
      if (line.trim().length > 0) lines.push(line);
      start = index + 1;
    }
    this.#buffer = start === 0 ? merged : merged.slice(start);
    return lines;
  }

  /**
   * 尚未成行的残料(诊断用:连接被掐断时报"响应不完整:<残料>")。
   * **只用于给人看的错误文案**:残料末尾可能正好是半个多字节字符,解出来是 U+FFFD ——
   * 那不影响判断"响应不完整",但别拿它当数据用。
   */
  get pending(): string {
    return DECODER.decode(this.#buffer);
  }
}
