// 长连接与角色注册表 —— 「在场」这件事在内核里的唯一持有者。
//
// 一条原则贯穿本文件:**角色是连接的属性,不是报文里的一句自称**。
// 注册写在连接对象上,连接一断,角色随之消失 —— 不需要心跳、不需要 TTL、不存在"它其实早走了"的
// 陈旧窗口(ADR 0005 修订后第 4 条「在场 = 长连接」)。这也是为什么确认器不能"重连恢复会话":
// 断线的那一刻,在途的 dangerous 请求就该按默拒收尾,而不是等它回来。
//
// 推送对象是协议的一部分,不是实现细节:
//   * `confirmation` 事件带着本次调用的真实入参 —— **只发给 confirm-agent**;
//   * 其余事件(仲裁状态/审计/存活监督/能力变化)发给全体已注册连接。
// 有断言守这条(订阅者拿不到 input)。

import { encodeFrame, pushEnvelope, type ClientIdentity, type ClientRole, type KernelEvent } from "../contract/wire.ts";

/** 一条客户端连接。`send` 由 server 注入(写 socket),hub 只管"发给谁"。 */
export interface ClientConnection {
  /** 内核给的连接 id(进审计,便于把日志与连接对上)。 */
  readonly id: string;
  /** 内核校验到的对端 uid;这台机器上问不出凭据时缺省(见 `peer.ts` 的口径)。 */
  readonly uid?: number;
  /** 已注册的角色(可以两个都有:菜单栏壳既确认也投影)。 */
  readonly roles: Set<ClientRole>;
  /** 最近一次注册时自报的身份(**不构成身份**,只进审计与展示)。 */
  identity?: ClientIdentity;
  /** 往这条连接写一帧;对端已断则静默丢弃(推送失败不该把内核拖下水)。 */
  send(frame: string): void;
}

export interface ClientHub {
  /** 在这条连接上登记一个角色。返回是否**新增**(重复注册同一角色 = 幂等,返回 false)。 */
  register(connection: ClientConnection, role: ClientRole, identity: ClientIdentity): boolean;
  /** 连接断了。返回它离场时带走的角色(供审计逐条留痕)。 */
  drop(connection: ClientConnection): ClientRole[];
  confirmerCount(): number;
  subscriberCount(): number;
  /** 发给全体已注册连接(确认器 + 订阅者)。 */
  broadcast(event: KernelEvent): void;
  /** 只发给确认器。带 input 的确认请求走这条。 */
  toConfirmers(event: KernelEvent): void;
}

export function createClientHub(): ClientHub {
  /** 只装**已注册**的连接:没注册角色的连接(比如一次性的 CLI 调用)不该收到任何推送。 */
  const registered = new Set<ClientConnection>();

  function countOf(role: ClientRole): number {
    let count = 0;
    for (const connection of registered) if (connection.roles.has(role)) count += 1;
    return count;
  }

  function deliver(event: KernelEvent, predicate: (c: ClientConnection) => boolean): void {
    const frame = encodeFrame(pushEnvelope(event));
    for (const connection of registered) {
      if (predicate(connection)) connection.send(frame);
    }
  }

  return {
    register(connection, role, identity) {
      connection.identity = identity;
      const added = !connection.roles.has(role);
      connection.roles.add(role);
      registered.add(connection);
      return added;
    },
    drop(connection) {
      const roles = [...connection.roles];
      connection.roles.clear();
      registered.delete(connection);
      return roles;
    },
    confirmerCount: () => countOf("confirm-agent"),
    subscriberCount: () => countOf("subscriber"),
    broadcast(event) {
      deliver(event, () => true);
    },
    toConfirmers(event) {
      deliver(event, (connection) => connection.roles.has("confirm-agent"));
    },
  };
}
