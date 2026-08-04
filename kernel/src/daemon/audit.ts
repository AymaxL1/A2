// 仲裁审计:dangerous 的每一次仲裁、每一次角色进出、每一次被拒的对端,都在这里留痕。
//
// 三个去处,一次记账(票面:「NDJSON 日志 + 可查询 + 推送」):
//   ① `<A2_HOME>/log/arbitration.log` —— NDJSON,一行一条,**全量**;
//   ② 内存里最近若干条 —— `arbitration.status` 能力(与 `proxy.supervision.get` 同一种口径)读它;
//   ③ 推给已注册的长连接 —— 壳(10 票)据此显示"刚刚发生了什么"。
//
// 写日志是 best-effort:盘满/只读也不该让仲裁停摆(内存那份仍然可查,推送仍然发得出)。
// 与 `proxy/supervision.ts` 的事件日志同一种处置,理由也同一条。

import { appendFile, mkdir } from "node:fs/promises";
import path from "node:path";
import type { AuditEvent } from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { LOG_DIR_MODE, LOG_DIR_NAME } from "../service/unit.ts";
import type { ClientConnection } from "./hub.ts";

/** 审计日志文件名(NDJSON,一行一条)。 */
export const AUDIT_LOG_NAME = "arbitration.log";
/** 内存里留多少条最近事件(全量在日志文件里)。 */
const RECENT_EVENTS = 100;

export function auditLogPath(paths: KernelPaths): string {
  return path.join(paths.home, LOG_DIR_NAME, AUDIT_LOG_NAME);
}

export interface AuditLog {
  readonly logPath: string;
  /**
   * 记一条(`at` 由本模块统一打,调用方不必各自 `new Date()`)。返回补齐后的事件。
   *
   * `exceptPush` 让某一条连接**不收到**这条事件的推送(落盘与内存那两份照记)——
   * 唯一的用途是注册那一刻:进场事件不推给刚注册的自己(它的快照里已经含着了)。
   */
  record(event: Omit<AuditEvent, "at">, options?: { exceptPush?: ClientConnection }): AuditEvent;
  /** 最近若干条(新的在后)。 */
  recent(): AuditEvent[];
}

export function createAuditLog(
  paths: KernelPaths,
  publish: (event: AuditEvent, except?: ClientConnection) => void,
): AuditLog {
  const logPath = auditLogPath(paths);
  const events: AuditEvent[] = [];

  return {
    logPath,
    record(partial, options) {
      const event: AuditEvent = { at: new Date().toISOString(), ...partial };
      events.push(event);
      if (events.length > RECENT_EVENTS) events.splice(0, events.length - RECENT_EVENTS);
      // 落盘是异步的、且允许失败;推送与内存那份**同步**完成,断言不必等 I/O。
      void mkdir(path.dirname(logPath), { recursive: true, mode: LOG_DIR_MODE })
        .then(() => appendFile(logPath, `${JSON.stringify(event)}\n`))
        .catch(() => {});
      publish(event, options?.exceptPush);
      return event;
    },
    recent: () => [...events],
  };
}
