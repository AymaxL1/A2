// UDS server:起监听、收紧权限、校验对端、逐行路由、干净收摊。
//
// 权限的三道门(纵深,从外到内):
//   1. `<A2_HOME>/run` 自建并 **显式 chmod 0700**(mkdir 的 mode 会被 umask 削,必须补一刀);
//   2. socket **bind 之后 chmod 0600**(bind 时的权限同样随 umask,0755 是常见默认值);
//      —— 前两道由 OS 强制,别的用户 connect() 就会被拒,连字节都发不进来。
//   3. **对端 UID 校验**(08 票,`peer.ts`:getpeereid / SO_PEERCRED):问出来对不上就当场拒 + 留痕。
//      它是纵深,不是唯一那道;取不到凭据的平台上放行 + 大声留痕,理由见 `peer.ts` 文件头。
// (ADR 0010 Consequences:Bun 的 UDS 权限跟随 umask,内核不能指望它。)
//
// 08 票起这条 socket 是**长连接**:同一条连接上既有一问一答,也有内核单向推来的帧(推送)。
// 每连接一份状态因此长出了角色与身份 —— 那正是 03 票留在 `socket.data` 上的那个位置。

import { chmod, mkdir, stat, unlink } from "node:fs/promises";
import { LineBuffer } from "../contract/ndjson.ts";
import { ErrorCode, encodeFrame, failureResponse } from "../contract/wire.ts";
import { RUN_DIR_MODE, SOCKET_MODE, type KernelPaths } from "../runtime/paths.ts";
import type { ClientConnection } from "./hub.ts";
import { judgePeer } from "./peer.ts";
import { handleLine } from "./router.ts";
import type { KernelRuntime } from "./runtime.ts";

/** socket 上已经有个活着的 daemon —— 不抢,报错退出(自愈归系统 supervisor,应用层不造看门狗)。 */
export class AlreadyRunningError extends Error {
  constructor(readonly socketPath: string) {
    super(`socket 上已有活着的 daemon:${socketPath}`);
    this.name = "AlreadyRunningError";
  }
}

export interface KernelServer {
  socketPath: string;
  /** 关监听、断连接、删 socket 文件。可重复调用。 */
  stop(): Promise<void>;
}

interface ConnectionState {
  lines: LineBuffer;
  /** 同一连接上的应答串行化:handler 可以是异步的,但**响应顺序必须等于请求顺序**。 */
  queue: Promise<void>;
  /** 这条连接在 hub 眼里的样子(角色、身份、怎么给它写帧)。 */
  client: ClientConnection;
  /** 写不完的字节暂存在这儿,等 `drain` 再续(见 `createWriter`)。 */
  flush(): void;
}

/**
 * 一条连接的**唯一写出口**(响应与推送都走它)。两件事必须由它统一管:
 *
 * 1. **半写**。`socket.write()` 只保证写"能写多少写多少",返回实际写进去的**字节数**;
 *    剩下的**不会**被自动缓冲。快照报文有十几 KB,一次写不完是常态 —— 不接住就是"报文被截断"
 *    (本票实测踩到:注册响应写到一半没了,客户端读到半个 JSON)。剩料留在这里,等 `drain` 再续。
 * 2. **顺序**。推送是内核随时发起的,响应是排队产出的;两者若各写各的,先来的半截会被后来的插队。
 *    统一从一个队列出去,先进先出。
 *
 * 缓冲用 `Uint8Array` 而不是字符串:`write` 的返回值是字节数,而报文里全是中文 —— 按字符切会切碎多字节序列。
 */
function createWriter(socket: { write(data: Uint8Array): number }): {
  send(frame: string): void;
  flush(): void;
} {
  const encoder = new TextEncoder();
  let backlog: Uint8Array | undefined;

  function flush(): void {
    while (backlog && backlog.length > 0) {
      let written = 0;
      try {
        written = socket.write(backlog);
      } catch {
        backlog = undefined; // 对端已断,这些字节没有去处了。
        return;
      }
      if (written <= 0) return; // 缓冲满了,等 drain。
      backlog = written >= backlog.length ? undefined : backlog.subarray(written);
    }
    backlog = undefined;
  }

  return {
    send(frame) {
      const bytes = encoder.encode(frame);
      if (backlog && backlog.length > 0) {
        const merged = new Uint8Array(backlog.length + bytes.length);
        merged.set(backlog, 0);
        merged.set(bytes, backlog.length);
        backlog = merged;
      } else {
        backlog = bytes;
      }
      flush();
    },
    flush,
  };
}

export async function startKernelServer(runtime: KernelRuntime): Promise<KernelServer> {
  const paths = runtime.paths;
  await prepareRunDirectory(paths);
  await clearStaleSocket(paths.socketPath);

  const listener = Bun.listen<ConnectionState>({
    unix: paths.socketPath,
    socket: {
      open(socket) {
        // 第三道门:先验对端,再谈别的。**验不过的连接一个字节都不路由**。
        const verdict = judgePeer(socket);
        if (!verdict.allow) {
          runtime.audit.record({
            action: "peer_rejected",
            client: { uid: verdict.credential.uid },
            detail: `对端 uid=${verdict.credential.uid},内核期望 ${verdict.expected};连接已拒绝。`,
          });
          const frame = encodeFrame(
            failureResponse(crypto.randomUUID(), {
              code: ErrorCode.peerRejected,
              message: "这条连接的对端不是内核所属的用户,已拒绝。",
              detail: `对端 uid=${verdict.credential.uid},内核期望 uid=${verdict.expected}。`,
              guidance: {
                summary: "a2 的控制面只服务于内核自己所属的那个本机用户。",
                steps: [
                  { description: "以内核所属用户的身份运行 a2", command: "a2 status --json" },
                  { description: "确认这台机器上跑的是你自己的内核", command: "a2 service status --json" },
                ],
                context: { socketPath: paths.socketPath },
              },
            }),
          );
          // **写在下一拍**:在 `open` 回调里立刻写再关,编译产物上实测会丢这一帧(源码模式不丢),
          // 客户端于是只看到"连接被关闭",拿到 `daemon_unreachable` 而不是被拒的**理由**。
          // 拒绝本身在这一刻已经成立(下面 return,这条连接永远不会被路由);推迟的只是把理由说出口。
          setTimeout(() => {
            try {
              socket.write(frame);
            } catch {
              /* 对端已经走了,理由没人听 */
            }
            socket.end();
          }, 0);
          return;
        }

        const writer = createWriter(socket);
        const client: ClientConnection = {
          id: crypto.randomUUID(),
          ...(verdict.credential === undefined ? {} : { uid: verdict.credential.uid }),
          roles: new Set(),
          // 推送失败不该把内核拖下水:对端可能刚好断了,那是它的事(writer 自己吞掉写异常)。
          send: writer.send,
        };
        socket.data = {
          lines: new LineBuffer(),
          queue: Promise.resolve(),
          client,
          flush: writer.flush,
        };
      },
      drain(socket) {
        // 内核缓冲腾出来了 —— 把上次没写完的续上(半写不接住就是"报文被截断")。
        socket.data?.flush();
      },
      data(socket, chunk) {
        const state = socket.data;
        // 被拒的连接没有 state(open 里已经 end 掉了),它后面若还发字节,一律不理。
        if (!state) return;
        for (const line of state.lines.push(chunk.toString())) {
          // 串成一条链:上一条应答写完才处理下一条,请求-响应顺序天然对齐(handler 可异步)。
          state.queue = state.queue
            .then(async () => {
              // 响应与推送共用同一个写队列 —— 否则推送会插到半写的响应中间去。
              state.client.send(await handleLine(line, runtime, state.client));
            })
            // `handleLine` 永不抛(router 的铁律),写出口也自己吞掉对端已断的写异常 —— 所以这条
            // catch 是**兜底**:万一还是漏出来一个,未捕获的 rejection 会掀掉整个 daemon。
            // 这条连接从此无法保证"请求-响应一一对应",静默留着只会让对方一直等 ——
            // 落一行日志到 stderr,然后断连,让客户端立刻拿到"连接关闭"而不是超时。
            .catch((error) => {
              process.stderr.write(
                `${JSON.stringify({ event: "connection.aborted", detail: String(error) })}\n`,
              );
              socket.end();
            });
        }
      },
      close(socket) {
        // **在场 = 长连接**:断连即离场。角色随连接一起消失,在途的 dangerous 请求由 arbiter
        // 在确认器归零时立即按默拒收尾 —— 不等超时,也没有"重连恢复会话"这回事。
        const state = socket.data;
        if (!state) return;
        dropClient(runtime, state.client);
      },
    },
  });

  // bind 之后立刻收紧:在此之前的窗口里 socket 的权限来自 umask,不可信。
  await chmod(paths.socketPath, SOCKET_MODE);

  let stopped = false;
  return {
    socketPath: paths.socketPath,
    async stop() {
      if (stopped) return;
      stopped = true;
      // 先把在途确认按降级收尾,再断连接:否则挂起的那次调用会随连接一起消失,发起方只看到"断了"。
      runtime.arbiter.shutdown();
      listener.stop(true);
      // UDS 文件不随进程退出自动消失,自己收拾干净(留下的陈旧 socket 会骗到下一次 status)。
      await unlink(paths.socketPath).catch(() => {});
    },
  };
}

/** 一条连接走了:摘角色、逐个留痕、让 arbiter 重新看一眼在场情况。 */
function dropClient(runtime: KernelRuntime, client: ClientConnection): void {
  const roles = runtime.hub.drop(client);
  for (const role of roles) {
    runtime.audit.record({
      action: role === "confirm-agent" ? "confirmer_left" : "subscriber_left",
      client: {
        role,
        ...(client.identity?.name === undefined ? {} : { name: client.identity.name }),
        ...(client.uid === undefined ? {} : { uid: client.uid }),
      },
      detail: `连接 ${client.id} 断开,${role} 角色随之离场。`,
    });
  }
  if (roles.length > 0) runtime.arbiter.rosterChanged();
}

/** 自建 `<home>/run` 并显式收紧到 0700(已存在但权限松的目录也一并纠正)。 */
async function prepareRunDirectory(paths: KernelPaths): Promise<void> {
  await mkdir(paths.runDir, { recursive: true, mode: RUN_DIR_MODE });
  await chmod(paths.runDir, RUN_DIR_MODE);
}

/**
 * socket 文件存在时先探活:连得上 = 真有 daemon 在跑(拒绝启动);连不上 = 上次没收摊干净的残骸(删掉)。
 * 不这么做的话,bind 会直接 EADDRINUSE,而人看到的错误分不清"已经在跑"和"上次崩了"。
 *
 * 注:这里**只探连得上连不上**,不写请求也不读响应 —— 所以它不碰 NDJSON 拆行(`LineBuffer`),
 * 空的 `data(){}` 只是 `Bun.connect` 的必填回调,不是又一份"读一行"实现。
 */
async function clearStaleSocket(socketPath: string): Promise<void> {
  const exists = await stat(socketPath).then(
    () => true,
    () => false,
  );
  if (!exists) return;

  try {
    // 注:Bun.connect 至少要一个 data/drain 回调,空 handler 会 TypeError(探活本身不读数据)。
    const probe = await Bun.connect({ unix: socketPath, socket: { data() {} } });
    probe.end();
    throw new AlreadyRunningError(socketPath);
  } catch (error) {
    if (error instanceof AlreadyRunningError) throw error;
    await unlink(socketPath).catch(() => {});
  }
}
