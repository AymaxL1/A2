// 仲裁面的可查询入口(08 票)。
//
// 为什么它是**能力**而不是又一条 `a2 xxx` 命令(与 `proxy.supervision.get` 同一条口径):
// 它问的是 **daemon 进程里那份状态** —— 谁在场、谁在等、刚刚发生过什么。这种事实只有一个持有者,
// 所以只能经注册表、经 daemon 拿。`a2 service` / `a2 mihomo` 那种"daemon 没跑时更要能答话"的命令
// 才不进这张表。
//
// 它是 `safe`(只读):看一眼仲裁面不该需要被确认 —— 否则"没有确认器时连查都查不了"就成了死锁。

import { auditLogPath } from "../daemon/audit.ts";
import type { Arbiter } from "../daemon/arbitration.ts";
import type { AuditLog } from "../daemon/audit.ts";
import type { JsonValue } from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import type { Capability } from "./registry.ts";

export function arbitrationCapabilities(context: {
  paths: KernelPaths;
  arbiter: Arbiter;
  audit: AuditLog;
}): Capability[] {
  const status: Capability = {
    descriptor: {
      id: "arbitration.status",
      risk: "safe",
      summary: "看仲裁面现状:确认器在不在场、有没有在途确认、最近的审计事件(只读)",
      parameters: [],
      cliAlias: ["arbitration", "status"],
    },
    handler: () =>
      // 一次类型放行(同 `capability/proxy.ts::payload` 的理由:具名 result 类型不结构化属于 JsonValue,
      // 运行时什么都没发生;真正的形状把关在 CLI 侧的 zod 校验上)。
      ({
        state: context.arbiter.state(),
        logPath: auditLogPath(context.paths),
        events: context.audit.recent(),
      }) as unknown as JsonValue,
  };
  return [status];
}
