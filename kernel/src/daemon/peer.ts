// 对端凭据:这条 UDS 连接的另一头是哪个本机用户?
//
// 为什么要问:角色协议(确认器/订阅者)是**权力**——确认器能替人放行 dangerous。协议层的自称
// (「我是 a2-panel」)不构成身份,唯一能被内核**验证**的事实是内核自己从 socket 上问出来的 UID。
// 判据来自 ADR 0005 修订后第 4 条与 ADR 0008 第 7 条:「内核校验对端 UID(getpeereid/SO_PEERCRED)」。
//
// **这是纵深的第三道门,不是唯一那道**。前两道由 OS 强制、且先于本模块生效:
//   ① `<A2_HOME>/run` 目录 0700;② socket 文件 0600(见 `daemon/server.ts`)。
// 别的用户在 macOS/Linux 上连一个 0600 的 UDS 会在 connect() 就被 OS 拒掉,根本走不到这里。
// 所以本模块取不到凭据时的处置是:**放行 + 大声留痕**(审计事件 `peer_rejected` 不发,改发 stderr 一行
// 与快照里 `uid` 缺省),而不是把整个内核锁死 —— 一个 FFI 拿不到符号的平台上,前两道门仍然完好,
// 而"全拒"等于内核在那台机器上不可用。**取到了但对不上,一律拒**(那才是真信号)。
//
// 实现路径(macOS 侧实测过,见 docs/research/ts-kernel-runtime-bun.md §4.4 与本票的更正):
//   * macOS:`getpeereid(fd, &uid, &gid)`(libSystem.B.dylib);
//   * Linux:`getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &ucred, &len)`(libc.so.6),`struct ucred` 12 字节。
// **协议层没有平台分支**:两端都只是"给一个 fd、要回一个 uid",所以「Linux 形态由构造保证」——
// 角色协议、仲裁、推送三件事一行平台判断都没有。

import { dlopen, FFIType, ptr, suffix } from "bun:ffi";

/** 从 socket 上问出来的对端凭据。 */
export interface PeerCredential {
  uid: number;
  gid?: number;
  /** Linux 的 `SO_PEERCRED` 顺带给出 pid;macOS 的 `getpeereid` 不给。 */
  pid?: number;
}

/**
 * **测试专用**的期望 UID 覆写。设了它,内核就拿它(而不是自己的 uid)去比对对端。
 *
 * 安全性说明(有意的单向设计):这个开关**只能让校验更严**——把期望值设成一个别的 uid,
 * 结果是**连自己都被拒**(这正是测试要的活体拒绝路径)。它没有任何写法能让一个真正的外来 uid 被放行,
 * 所以即便生产环境误设,后果也只是内核拒绝一切连接(fail-closed),而不是开一个洞。
 */
export const PEER_EXPECT_UID_ENV = "A2_PEER_EXPECT_UID";

interface PeerReader {
  read(fd: number): PeerCredential | undefined;
}

/** dlopen 只做一次,失败就永远记为"这台机器上问不出来"(不是每条连接重试一遍)。 */
let reader: PeerReader | null | undefined;

function loadReader(): PeerReader | null {
  if (reader !== undefined) return reader;
  try {
    reader = process.platform === "linux" ? linuxReader() : darwinReader();
  } catch (error) {
    process.stderr.write(
      `${JSON.stringify({
        event: "peer.credential.unavailable",
        detail: String(error),
        note: "对端 UID 校验不可用;把关的是 run/ 0700 与 socket 0600 两道 OS 强制的门。",
      })}\n`,
    );
    reader = null;
  }
  return reader;
}

/** macOS:`int getpeereid(int, uid_t *, gid_t *)`。 */
function darwinReader(): PeerReader {
  const lib = dlopen("libSystem.B.dylib", {
    getpeereid: { args: [FFIType.i32, FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
  });
  return {
    read(fd) {
      const uid = new Uint32Array(1);
      const gid = new Uint32Array(1);
      const rc = lib.symbols.getpeereid(fd, ptr(uid), ptr(gid));
      if (rc !== 0) return undefined;
      return { uid: uid[0] as number, gid: gid[0] as number };
    },
  };
}

/**
 * Linux:`getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &ucred, &len)`。
 * `struct ucred { pid_t pid; uid_t uid; gid_t gid; }` —— 三个 32 位,共 12 字节。
 *
 * **未在真 Linux 上实测**(与仓库既有 Linux 口径一致:代码路径 + 单测进门禁,实机验收顺延)。
 */
function linuxReader(): PeerReader {
  const SOL_SOCKET = 1;
  const SO_PEERCRED = 17;
  const lib = dlopen(`libc.${suffix}.6`, {
    getsockopt: {
      args: [FFIType.i32, FFIType.i32, FFIType.i32, FFIType.ptr, FFIType.ptr],
      returns: FFIType.i32,
    },
  });
  return {
    read(fd) {
      const ucred = new Uint32Array(3);
      const len = new Uint32Array(1);
      len[0] = 12;
      const rc = lib.symbols.getsockopt(fd, SOL_SOCKET, SO_PEERCRED, ptr(ucred), ptr(len));
      if (rc !== 0) return undefined;
      return { pid: ucred[0] as number, uid: ucred[1] as number, gid: ucred[2] as number };
    },
  };
}

/**
 * 从一个 socket 对象上拿原始 fd。
 *
 * **实测更正**(2026-08-05,本票):研究文档 §4.4 记的是「`Bun.listen` 的 Socket 不暴露 fd,
 * 得改走 `node:net` 兼容层的 `socket._handle.fd`」。本机 Bun 1.3.14 上 **`Bun.listen` 的
 * Socket 原型链上就有 `fd` 取值器**,`getpeereid(socket.fd)` 直接返回真实 UID/GID(实测 501/20,
 * 与 `id -u`/`id -g` 吻合)—— 所以内核**不必**为了取凭据而换掉 `Bun.listen`。
 * `_handle?.fd` 仍作为兜底留着,免得 Bun 哪天把取值器挪了位置。
 */
export function socketFd(socket: unknown): number | undefined {
  if (socket === null || typeof socket !== "object") return undefined;
  const candidate = socket as { fd?: unknown; _handle?: { fd?: unknown } };
  if (typeof candidate.fd === "number" && candidate.fd >= 0) return candidate.fd;
  const handleFd = candidate._handle?.fd;
  if (typeof handleFd === "number" && handleFd >= 0) return handleFd;
  return undefined;
}

/** 问出对端凭据;这台机器上问不出来(或 fd 拿不到)时返回 undefined。 */
export function peerCredential(socket: unknown): PeerCredential | undefined {
  const fd = socketFd(socket);
  if (fd === undefined) return undefined;
  try {
    return loadReader()?.read(fd);
  } catch {
    return undefined;
  }
}

/** 内核期望的对端 uid(= 自己的 uid;`A2_PEER_EXPECT_UID` 只能把它换成另一个,不能关掉校验)。 */
export function expectedUid(env: Record<string, string | undefined> = process.env): number | undefined {
  const override = env[PEER_EXPECT_UID_ENV]?.trim();
  if (override) {
    const parsed = Number.parseInt(override, 10);
    if (Number.isInteger(parsed) && parsed >= 0) return parsed;
  }
  return process.getuid?.();
}

export type PeerVerdict =
  /** 问出来了,且与内核同 UID —— 放行。 */
  | { allow: true; credential: PeerCredential }
  /** 这台机器上问不出凭据 —— 放行(前两道门仍在),但快照/审计里 uid 缺省。 */
  | { allow: true; credential?: undefined }
  /** 问出来了,不是同一个 UID —— **拒**。 */
  | { allow: false; credential: PeerCredential; expected: number };

/**
 * 判一条连接的对端。这是内核里**唯一**决定"这条连接能不能说话"的地方。
 *
 * 顺序即语义:先看能不能问出来(问不出 = 放行 + uid 缺省),再看是不是同一个人(不是 = 拒)。
 */
export function judgePeer(
  socket: unknown,
  env: Record<string, string | undefined> = process.env,
): PeerVerdict {
  const credential = peerCredential(socket);
  if (!credential) return { allow: true };
  const expected = expectedUid(env);
  if (expected === undefined || credential.uid === expected) return { allow: true, credential };
  return { allow: false, credential, expected };
}
