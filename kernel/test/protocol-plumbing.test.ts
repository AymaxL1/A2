// 长连接的**管道层**:拆行与写队列。
//
// 这两样都不是"业务",但它们错了会以最难查的方式错:拆行错 = 报文里的汉字变成 U+FFFD(只在报文够大、
// 内容够中文时偶发);写队列错 = 要么报文被截断(半写没接住),要么内核被一个不读的客户端拖到 OOM。
// 所以这里直接在这两个**纯模块的公开面**上测 —— 它们各自都是"给字节、要行"和"给帧、要写"的窄接口,
// 用假 socket 就能把真实网络里难以复现的时序(分片、缓冲满)变成确定性的输入。
//
// 08 票 CR 抓到的两条真缺陷就是这两条,这个文件是它们的活体防线。

import { expect, test } from "bun:test";
import { LineBuffer } from "../src/contract/ndjson.ts";
import { createUnverifiedPeerLog, expectedUid, PEER_EXPECT_UID_ENV } from "../src/daemon/peer.ts";
import { createFrameWriter, type WritableSocket } from "../src/daemon/writer.ts";

// MARK: - 拆行:分片边界不许切碎多字节字符

test("LineBuffer:把一个汉字精确切在分片边界上,拼回来仍是原字(不是 U+FFFD)", () => {
  const frame = `${JSON.stringify({ 名: "中文报文", 值: "確認器" })}\n`;
  const bytes = new TextEncoder().encode(frame);
  // 找一个**落在多字节字符中间**的切点:第一个后继字节(10xxxxxx)的位置。
  const cut = bytes.findIndex((byte) => (byte & 0b1100_0000) === 0b1000_0000);
  expect(cut).toBeGreaterThan(0);

  const buffer = new LineBuffer();
  expect(buffer.push(bytes.subarray(0, cut))).toEqual([]);
  const lines = buffer.push(bytes.subarray(cut));

  expect(lines).toEqual([frame.slice(0, -1)]);
  expect(lines[0]).not.toContain("�");
});

test("LineBuffer:逐字节喂一整帧也拼得回来(最坏的分片)", () => {
  const frame = `${JSON.stringify({ 说明: "确认器在场时 dangerous 走带外确认" })}\n`;
  const bytes = new TextEncoder().encode(frame);
  const buffer = new LineBuffer();

  const lines: string[] = [];
  for (const byte of bytes) lines.push(...buffer.push(Uint8Array.of(byte)));

  expect(lines).toEqual([frame.slice(0, -1)]);
});

test("LineBuffer:一片里带好几帧、末尾残半行 —— 全帧照吐,残料留着", () => {
  const one = JSON.stringify({ a: "甲" });
  const two = JSON.stringify({ b: "乙" });
  const buffer = new LineBuffer();

  const lines = buffer.push(new TextEncoder().encode(`${one}\n${two}\n{"c":"丙`));

  expect(lines).toEqual([one, two]);
  expect(buffer.pending).toBe('{"c":"丙');
});

test("LineBuffer:空白行被丢弃(NDJSON 的凑数行不是报文)", () => {
  const buffer = new LineBuffer();
  expect(buffer.push('\n  \n{"a":1}\n')).toEqual(['{"a":1}']);
});

test("LineBuffer:传进来的字节被复制 —— 复用缓冲在下一片被改写也不影响已缓存的残料", () => {
  const buffer = new LineBuffer();
  // 模拟 Bun 复用的 socket 缓冲:同一块内存喂两次,中间被改写。
  const reused = new TextEncoder().encode('{"a":"甲"}');
  buffer.push(reused);
  reused.fill(0x58); // "XXXX…":若实现留了引用,残料会变成一串 X

  expect(buffer.pending).toBe('{"a":"甲"}');
  expect(buffer.push("\n")).toEqual(['{"a":"甲"}']);
});

// MARK: - 写队列:半写要接住、积压要有天花板

/** 一个可控的假 socket:`accept` 决定这一次肯收多少字节。 */
function fakeSocket(accept: (length: number) => number): WritableSocket & { written: Uint8Array[] } {
  const written: Uint8Array[] = [];
  return {
    written,
    write(data) {
      const take = Math.max(0, Math.min(data.length, accept(data.length)));
      if (take > 0) written.push(data.slice(0, take));
      return take;
    },
  };
}

function joined(socket: { written: Uint8Array[] }): string {
  const total = socket.written.reduce((sum, chunk) => sum + chunk.length, 0);
  const merged = new Uint8Array(total);
  let at = 0;
  for (const chunk of socket.written) {
    merged.set(chunk, at);
    at += chunk.length;
  }
  return new TextDecoder().decode(merged);
}

test("写队列:一次只收 7 个字节的 socket 上,帧仍然一字节不差地写完(半写被接住)", () => {
  const socket = fakeSocket(() => 7);
  const writer = createFrameWriter(socket);
  const frame = `${JSON.stringify({ 快照: "十几 KB 的中文报文" })}\n`;

  writer.send(frame);
  // 缓冲一直只肯收 7 字节 —— 靠 drain 反复续写才能写完。
  for (let round = 0; round < 200 && writer.backlogBytes > 0; round += 1) writer.flush();

  expect(writer.backlogBytes).toBe(0);
  expect(joined(socket)).toBe(frame);
});

test("写队列:对端完全不读时,先进先出的顺序仍然保持(响应不会被推送插队)", () => {
  let open = false;
  const socket = fakeSocket((length) => (open ? length : 0));
  const writer = createFrameWriter(socket);

  writer.send("一\n");
  writer.send("二\n");
  writer.send("三\n");
  expect(joined(socket)).toBe("");

  open = true;
  writer.flush();
  expect(joined(socket)).toBe("一\n二\n三\n");
});

test("写队列:积压超限 → 判定慢消费者,叫一次 onOverflow 并把队列清干净", () => {
  const socket = fakeSocket(() => 0); // 连上来就不读
  const overflows: { bytes: number; limit: number }[] = [];
  const writer = createFrameWriter(socket, {
    limitBytes: 64,
    onOverflow: (bytes, limit) => overflows.push({ bytes, limit }),
  });

  // 每帧 ~20 字节,灌到超过 64。
  for (let index = 0; index < 20; index += 1) writer.send(`{"事件":${index}}\n`);

  expect(overflows.length).toBe(1);
  expect(overflows[0]!.limit).toBe(64);
  expect(overflows[0]!.bytes).toBeGreaterThan(64);
  // 判死之后不再吃新帧,也不再占内存。
  expect(writer.backlogBytes).toBe(0);
  writer.send("还来?\n");
  expect(writer.backlogBytes).toBe(0);
  expect(overflows.length).toBe(1);
});

test("写队列:正常消费者永远碰不到上限(写完即清零,不随帧数累积)", () => {
  const socket = fakeSocket((length) => length);
  const writer = createFrameWriter(socket, { limitBytes: 64 });

  for (let index = 0; index < 1000; index += 1) writer.send(`{"事件":${index}}\n`);

  expect(writer.backlogBytes).toBe(0);
});

// MARK: - 对端凭据:测试开关只能更严;fail-open 留痕限频

test("A2_PEER_EXPECT_UID:只能替换那个唯一允许值;0(root)与非正整数一律作废", () => {
  const self = process.getuid?.();
  expect(expectedUid({ [PEER_EXPECT_UID_ENV]: "4242" })).toBe(4242);
  // **0 = root 被显式拒绝**:root 该走 OS 那两道门,不该由一个测试开关授权。
  expect(expectedUid({ [PEER_EXPECT_UID_ENV]: "0" })).toBe(self);
  expect(expectedUid({ [PEER_EXPECT_UID_ENV]: "-1" })).toBe(self);
  expect(expectedUid({ [PEER_EXPECT_UID_ENV]: "不是数字" })).toBe(self);
  expect(expectedUid({})).toBe(self);
});

test("fail-open 留痕:第一次必记,窗口内去重,窗口外再记一次并带累计数", () => {
  const log = createUnverifiedPeerLog(1000);

  const first = log.note("fd-unavailable", 0);
  expect(first).toContain("fd-unavailable");
  expect(first).toContain("累计 1 次");

  // 同一原因、窗口内:吞掉(但计数照涨)。
  expect(log.note("fd-unavailable", 500)).toBeUndefined();
  expect(log.note("fd-unavailable", 999)).toBeUndefined();

  // 另一个原因是独立的一路,第一次照记。
  expect(log.note("reader-unavailable", 500)).toContain("reader-unavailable");

  // 窗口外:再记一次,带上这一路的累计数。
  expect(log.note("fd-unavailable", 1500)).toContain("累计 4 次");
});
