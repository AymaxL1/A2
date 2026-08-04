// NDJSON 拆行 —— 帧边界这件事,全内核只有这一份实现。
//
// TCP/UDS 上一次 `data` 回调可能带来半行、一行或好几行,拆行逻辑写歪了就是"偶发丢报文";
// 08 票要把 UDS 面改成长连接(订阅推送 + 确认器角色),那时改的也是这里,而不是散在 server/client 各一份。
//
// 注:测试夹具 `test/support/harness.ts` **有意**不用本模块(理由见该文件头),那是独立事实源,不是重复。

/** 收字节、吐完整行。未收尾的残行留在内部缓冲里等下一片。 */
export class LineBuffer {
  #buffer = "";

  /** 吃一片数据,返回其中**已完整**的行(不含 '\n');空行被丢弃(NDJSON 的心跳/凑数行不是报文)。 */
  push(chunk: string): string[] {
    this.#buffer += chunk;
    const lines: string[] = [];
    let newline = this.#buffer.indexOf("\n");
    while (newline >= 0) {
      const line = this.#buffer.slice(0, newline);
      this.#buffer = this.#buffer.slice(newline + 1);
      if (line.trim().length > 0) lines.push(line);
      newline = this.#buffer.indexOf("\n");
    }
    return lines;
  }

  /** 尚未成行的残料(诊断用:连接被掐断时报"响应不完整:<残料>")。 */
  get pending(): string {
    return this.#buffer;
  }
}
