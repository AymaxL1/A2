// 对端凭据:这条 UDS 连接的另一头是哪个本机用户?
//
// 为什么要问:角色协议(确认器/订阅者)是**权力**——确认器能替人放行 dangerous。协议层的自称
// (「我是 a2-panel」)不构成身份,唯一能被内核**验证**的事实是内核自己从 socket 上问出来的 UID。
// 判据来自 ADR 0005 修订后第 4 条:「在场 = 长连接……内核校验对端 UID(`getpeereid`/`SO_PEERCRED`)」。
//
// **这是纵深的第三道门,不是唯一那道**。前两道由 OS 强制、且先于本模块生效:
//   ① `<A2_HOME>/run` 目录 0700;② socket 文件 0600(见 `daemon/server.ts`)。
// 别的用户在 macOS/Linux 上连一个 0600 的 UDS 会在 connect() 就被 OS 拒掉,根本走不到这里。
//
// **取不到凭据时放行(fail-open),这是一处经裁定的安全取舍**(08 票 CR 采纳):
//   * 收益侧:前两道门完好;同 UID 的敌意进程本来就能绕过内核(它可以直接替换 `a2` 这个二进制),
//     UID 校验保护的是「受认可路径上的 AI agent 不能自批」,不是对抗已拿到该用户身份的任意本机代码;
//   * 代价侧:一个 `dlopen` 拿不到符号的平台上"全拒"等于内核不可用 —— 零收益换不可用。
//   * 但**不能静默**:凭据问不出来正是「Bun 把 fd 取值器挪走了」这类失效最可能的表现,所以每一次
//     都要留痕(`peer_unverified` 审计事件,按原因去重 + 限频,见 `createUnverifiedPeerLog`)。
//   * 已知边界(同 UID 冒充 + fail-open)已写进 ADR 0005 与 ADR 0008 的修订记录。
// **取到了但对不上,一律拒**——那才是真信号。
//
// 实现路径(macOS 侧实测过,见 `docs/research/ts-kernel-runtime-bun.md` §4.4 与其中本票加的更正框;
// **该研究文档未入库**):
//   * macOS:`getpeereid(fd, &uid, &gid)`(libSystem.B.dylib);
//   * Linux:`getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &ucred, &len)`(libc.so.6),`struct ucred` 12 字节。
// **协议层没有平台分支**:两端都只是"给一个 fd、要回一个 uid",所以「Linux 形态由构造保证」——
// 角色协议、仲裁、推送三件事一行平台判断都没有(有断言守着)。

import { dlopen, FFIType, ptr, suffix } from "bun:ffi";

/** 从 socket 上问出来的对端凭据。 */
export interface PeerCredential {
  uid: number;
  gid?: number;
  /** Linux 的 `SO_PEERCRED` 顺带给出 pid;macOS 的 `getpeereid` 不给。 */
  pid?: number;
}

/** 凭据问不出来的三种原因(进审计 detail,便于分辨是哪一层失效了)。 */
export type UnverifiedReason =
  /** socket 对象上拿不到原始 fd —— Bun 换了实现最可能长这样。 */
  | "fd-unavailable"
  /** 这台机器上装不上凭据读取器(dlopen 失败 / 平台不支持)。 */
  | "reader-unavailable"
  /** 读了,但系统调用返回非零(连接已半关等)。 */
  | "credential-unreadable";

/**
 * **测试专用**的期望 UID 覆写。设了它,内核就拿它(而不是自己的 uid)去比对对端。
 *
 * 准确的安全性表述(08 票 CR 更正了此前那句过头的话):它**只能替换「唯一被允许的那个 uid」**,
 * 不能把允许集合变大、也不能把校验关掉。所以它最常见的后果是**拒绝一切连接**(fail-closed);
 * 若有人把它设成某个真实存在的其它 uid,那等价于"把内核让给那个人"—— 但能设内核环境变量的人,
 * 本来就能替换内核二进制,这不构成新的攻击面。
 *
 * **`0` 被显式拒绝**:root 该走 OS 那两道门,不该由一个测试开关授权。设成 0(或任何非正整数)时
 * 覆写整条作废,回落到内核自己的 uid。
 */
export const PEER_EXPECT_UID_ENV = "A2_PEER_EXPECT_UID";

interface PeerReader {
  read(fd: number): PeerCredential | undefined;
}

/** dlopen 只做一次,失败就永远记为"这台机器上装不上读取器"(不是每条连接重试一遍)。 */
let reader: PeerReader | null | undefined;

function loadReader(): PeerReader | null {
  if (reader !== undefined) return reader;
  try {
    reader = process.platform === "linux" ? linuxReader() : darwinReader();
  } catch (error) {
    process.stderr.write(
      `${JSON.stringify({
        event: "peer.reader.unavailable",
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
 * **未在真 Linux 上实测**(与仓库既有 Linux 口径一致:代码路径 + 类型进门禁,实机验收顺延)。
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
 * **实测更正**(2026-08-05,08 票):研究文档 §4.4(**未入库**)记的是「`Bun.listen` 的 Socket 不暴露 fd,
 * 得改走 `node:net` 兼容层的 `socket._handle.fd`」。本机 Bun 1.3.14 上 **`Bun.listen` 的 Socket 原型链上
 * 就有 `fd` 取值器**,`getpeereid(socket.fd)` 直接返回真实 UID/GID(实测 501/20,与 `id -u`/`id -g` 吻合)——
 * 所以内核**不必**为了取凭据而换掉 `Bun.listen`。`_handle?.fd` 仍作兜底,免得 Bun 哪天挪了取值器;
 * 真挪了也不会静默 —— 那会走到 `fd-unavailable`,每条连接都留痕(限频)。
 */
export function socketFd(socket: unknown): number | undefined {
  if (socket === null || typeof socket !== "object") return undefined;
  const candidate = socket as { fd?: unknown; _handle?: { fd?: unknown } };
  if (typeof candidate.fd === "number" && candidate.fd >= 0) return candidate.fd;
  const handleFd = candidate._handle?.fd;
  if (typeof handleFd === "number" && handleFd >= 0) return handleFd;
  return undefined;
}

/** 内核期望的对端 uid(= 自己的 uid;`A2_PEER_EXPECT_UID` 只能把它换成另一个,不能扩集、不能关)。 */
export function expectedUid(env: Record<string, string | undefined> = process.env): number | undefined {
  const override = env[PEER_EXPECT_UID_ENV]?.trim();
  if (override) {
    const parsed = Number.parseInt(override, 10);
    // 0 = root:那是 OS 那两道门的事,不该由一个测试开关授权。覆写整条作废。
    if (Number.isInteger(parsed) && parsed > 0) return parsed;
    process.stderr.write(
      `${JSON.stringify({
        event: "peer.expect.rejected",
        detail: `${PEER_EXPECT_UID_ENV}=${override} 不是一个大于 0 的整数(0 = root 被显式拒绝),覆写已作废。`,
      })}\n`,
    );
  }
  return process.getuid?.();
}

export type PeerVerdict =
  /** 问出来了,且与内核同 UID —— 放行。 */
  | { allow: true; credential: PeerCredential; unverified?: undefined }
  /** 这台机器上问不出凭据 —— 放行(前两道门仍在),但**必须留痕**,且快照里 uid 缺省。 */
  | { allow: true; credential?: undefined; unverified: UnverifiedReason }
  /** 问出来了,不是同一个 UID —— **拒**。 */
  | { allow: false; credential: PeerCredential; expected: number };

/**
 * 判一条连接的对端。这是内核里**唯一**决定"这条连接能不能说话"的地方。
 *
 * 顺序即语义:先看能不能问出来(问不出 = 放行 + 留痕 + uid 缺省),再看是不是同一个人(不是 = 拒)。
 */
export function judgePeer(
  socket: unknown,
  env: Record<string, string | undefined> = process.env,
): PeerVerdict {
  const fd = socketFd(socket);
  if (fd === undefined) return { allow: true, unverified: "fd-unavailable" };

  const active = loadReader();
  if (!active) return { allow: true, unverified: "reader-unavailable" };

  let credential: PeerCredential | undefined;
  try {
    credential = active.read(fd);
  } catch {
    credential = undefined;
  }
  if (!credential) return { allow: true, unverified: "credential-unreadable" };

  const expected = expectedUid(env);
  if (expected === undefined || credential.uid === expected) return { allow: true, credential };
  return { allow: false, credential, expected };
}

/** 同一原因两次留痕之间的最短间隔。第一次永远记;之后每 60 秒记一次并带上累计数。 */
export const UNVERIFIED_PEER_WINDOW_MS = 60_000;

/** 「凭据问不出来」的留痕器:按原因去重 + 限频,既不静默也不刷屏。 */
export interface UnverifiedPeerLog {
  /**
   * 记一次。返回 `undefined` = 本次被限频吞掉(计数照涨);
   * 返回一段 detail 文本 = 调用方该把它写进审计。
   */
  note(reason: UnverifiedReason, at?: number): string | undefined;
}

/**
 * **纯逻辑,可单测**(所以时钟是参数而不是 `Date.now()`)。
 *
 * 设计取舍:凭据问不出来在正常机器上**一次都不该发生**,一旦发生就是持续发生(每条连接都撞上)——
 * 所以「第一次必记 + 之后限频并带累计数」既保证不静默,也保证 `a2 status` 跑一万次不会把审计刷爆。
 */
export function createUnverifiedPeerLog(windowMs = UNVERIFIED_PEER_WINDOW_MS): UnverifiedPeerLog {
  const counts = new Map<UnverifiedReason, number>();
  const lastAt = new Map<UnverifiedReason, number>();

  return {
    note(reason, at = Date.now()) {
      const count = (counts.get(reason) ?? 0) + 1;
      counts.set(reason, count);
      const previous = lastAt.get(reason);
      if (previous !== undefined && at - previous < windowMs) return undefined;
      lastAt.set(reason, at);
      return `对端凭据问不出来(${reason}),连接照常放行 —— 把关的是 run/ 0700 与 socket 0600 两道 OS 强制的门。本原因累计 ${count} 次。`;
    },
  };
}
