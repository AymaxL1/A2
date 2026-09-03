// 机械执行器那一侧的**在场与往返**(url-router 施工 04 票),外加一条本票最要紧的守卫:
//
//   **除了 takeover/restore,任何既有 dangerous 能力的仲裁行为一个字都不许变。**
//
// 04 票往 registry 里加了一条岔路(`confirmation: "os-dialog"` 跳过 confirm-agent 三层)。
// 这种改动最危险的失手方式不是写错那条岔路,而是**让别的 dangerous 能力也走上去** ——
// 那等于把 ADR 0005 第 4 条在某几条命令上悄悄关掉,而且不会有任何测试自然地红。
// 于是这一份里有两组反证:
//   ① 名单钉死:全量能力表里标 os-dialog 的**恰好**是那两条(多一条即红);
//   ② 行为对照:同一个注册表里,confirm-agent 的 dangerous 照旧先默拒、handler 一次都不被碰到,
//      os-dialog 的 dangerous 直接进 handler —— 两条路在同一个断言里并排跑,谁串了线都看得见。
//
// 纪律:全程不起 daemon、不连 socket、不碰任何系统 API。

import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { CapabilityRegistry, confirmationModeOf, type Capability } from "../src/capability/registry.ts";
import { urlRouterCapabilities } from "../src/capability/url-router.ts";
import { BUILTIN_CAPABILITIES } from "../src/capability/builtin.ts";
import { proxyCapabilities } from "../src/capability/proxy.ts";
import { arbitrationCapabilities } from "../src/capability/arbitration.ts";
import { createAuditLog } from "../src/daemon/audit.ts";
import { createClientHub, type ClientConnection } from "../src/daemon/hub.ts";
import {
  createUrlRouterExecutorHub,
  EXECUTION_TIMEOUT_ENV,
  LAUNCH_WAIT_ENV,
} from "../src/daemon/url-router-executor.ts";
import { createProxySupervisor } from "../src/proxy/supervision.ts";
import { createArbiter } from "../src/daemon/arbitration.ts";
import {
  ErrorCode,
  type CapabilityDescriptor,
  type ClientRole,
  type KernelEvent,
  type UrlRouterExecuteCommand,
} from "../src/contract/wire.ts";
import { resolvePaths } from "../src/runtime/paths.ts";

/** 一次性临时 A2_HOME(审计口会往 `<home>/log/` 落盘,绝不落用户真实 ~/.a2)。 */
const HOME = mkdtempSync("/tmp/a2urlexec-");
const PATHS = resolvePaths({ A2_HOME: HOME });

afterAll(() => {
  rmSync(HOME, { recursive: true, force: true });
});

// MARK: - 夹具

/** 一条假连接(只记它收到了哪些帧)。 */
function fakeConnection(id: string, roles: ClientRole[]): ClientConnection & { frames: string[] } {
  const frames: string[] = [];
  return { id, roles: new Set(roles), frames, send: (frame) => frames.push(frame) };
}

/** 一个不推送的审计口(落盘走临时 home,断言一概不看它)。 */
function silentAudit() {
  return createAuditLog(PATHS, () => {});
}

function executorHub(env: Record<string, string | undefined> = {}) {
  const hub = createClientHub();
  return { hub, executor: createUrlRouterExecutorHub({ hub, audit: silentAudit(), env }) };
}

const COMMAND: UrlRouterExecuteCommand = {
  id: "exec-1",
  op: "set-default-handler",
  schemes: ["http", "https"],
  bundleID: "com.a2.panel",
  timeoutSeconds: 120,
};

function eventsOf(connection: { frames: string[] }): KernelEvent[] {
  return connection.frames.map((frame) => JSON.parse(frame).event);
}

// MARK: - 在场 = 长连接

test("在场判据 = 注册了 url-router-executor 的长连接(确认器不算,订阅者更不算)", () => {
  const { hub, executor } = executorHub();
  expect(executor.present()).toBe(false);

  const confirmer = fakeConnection("c1", []);
  hub.register(confirmer, "confirm-agent", { name: "假确认器" });
  // 注册了确认器 ≠ 有执行器:两把锁是分开的(确认器能替人做决定,执行器只能回报结果)。
  expect(executor.present()).toBe(false);

  const shell = fakeConnection("c2", []);
  hub.register(shell, "url-router-executor", { name: "假壳" });
  expect(executor.present()).toBe(true);

  hub.drop(shell);
  expect(executor.present()).toBe(false);
});

test("waitForPresence:壳一注册就立刻叫醒(不是轮询),等不到就有界返回 false", async () => {
  const { hub, executor } = executorHub();

  const waiting = executor.waitForPresence(2000);
  const shell = fakeConnection("c1", []);
  hub.register(shell, "url-router-executor", { name: "假壳" });
  executor.rosterChanged();
  expect(await waiting).toBe(true);

  hub.drop(shell);
  // 等不到:窗口很短,如实 false(拉起壳那一步据此报 confirmation_unavailable)。
  expect(await executor.waitForPresence(20)).toBe(false);
});

// MARK: - 指令帧的往返

test("指令帧**只推给执行器**:订阅者与确认器一帧都收不到(与 confirmation 同一条纪律)", async () => {
  const { hub, executor } = executorHub();
  const shell = fakeConnection("c1", []);
  const subscriber = fakeConnection("c2", []);
  const confirmer = fakeConnection("c3", []);
  hub.register(shell, "url-router-executor", { name: "假壳" });
  hub.register(subscriber, "subscriber", { name: "假订阅者" });
  hub.register(confirmer, "confirm-agent", { name: "假确认器" });

  const settled = executor.dispatch(COMMAND);
  executor.report(
    { execution: COMMAND.id, outcome: "confirmed", perScheme: { http: { ok: true }, https: { ok: true } } },
    { connection: "c1", name: "假壳" },
  );
  await settled;

  const pushed = eventsOf(shell).filter((event) => event.kind === "url-router-execute");
  expect(pushed).toHaveLength(1);
  expect(pushed[0]).toMatchObject({ command: { op: "set-default-handler", bundleID: "com.a2.panel" } });
  // **一个字节都不该漏到别人那儿**:那是"去改系统状态"的指令。
  expect(eventsOf(subscriber).some((event) => event.kind === "url-router-execute")).toBe(false);
  expect(eventsOf(confirmer).some((event) => event.kind === "url-router-execute")).toBe(false);
});

test("首个回话收场胜出:第二条回执拿 url_router_execution_unknown,不改写已经收场的结果", async () => {
  const { hub, executor } = executorHub();
  hub.register(fakeConnection("c1", []), "url-router-executor", { name: "假壳" });

  const settled = executor.dispatch(COMMAND);
  const first = executor.report(
    { execution: COMMAND.id, outcome: "confirmed", perScheme: { http: { ok: true }, https: { ok: true } } },
    { connection: "c1" },
  );
  expect(first).toBeUndefined();

  const second = executor.report(
    { execution: COMMAND.id, outcome: "denied", perScheme: {} },
    { connection: "c1" },
  );
  expect(second?.code).toBe(ErrorCode.urlRouterExecutionUnknown);
  expect(second?.guidance).toBeTruthy();

  // 结果仍是第一条说的那个 —— 迟到的回执改写不了任何东西。
  expect(await settled).toEqual({
    kind: "reported",
    report: { execution: COMMAND.id, outcome: "confirmed", perScheme: { http: { ok: true }, https: { ok: true } } },
  });
});

test("没这条指令 → url_router_execution_unknown(而不是静默收下一条没人要的回执)", () => {
  const { executor } = executorHub();
  const refusal = executor.report(
    { execution: "从来没有过的 id", outcome: "confirmed", perScheme: {} },
    { connection: "c1" },
  );
  expect(refusal?.code).toBe(ErrorCode.urlRouterExecutionUnknown);
});

test("沉默不是成功:等满窗口即 timeout(窗口可经环境变量覆写)", async () => {
  const { hub, executor } = executorHub({ [EXECUTION_TIMEOUT_ENV]: "30" });
  hub.register(fakeConnection("c1", []), "url-router-executor", { name: "假壳" });
  expect(executor.timeoutMs).toBe(30);

  expect(await executor.dispatch(COMMAND)).toEqual({ kind: "timeout" });
});

test("在场 = 长连接:执行器在指令在途时断线 → 立即收成 gone,**不等满窗口**", async () => {
  const { hub, executor } = executorHub({ [EXECUTION_TIMEOUT_ENV]: "60000" });
  const shell = fakeConnection("c1", []);
  hub.register(shell, "url-router-executor", { name: "假壳" });

  const settled = executor.dispatch(COMMAND);
  hub.drop(shell);
  executor.rosterChanged();

  const outcome = await settled;
  expect(outcome.kind).toBe("gone");
});

test("daemon 收摊:在途指令按 gone 收尾,不留悬空的 promise", async () => {
  const { hub, executor } = executorHub({ [EXECUTION_TIMEOUT_ENV]: "60000" });
  hub.register(fakeConnection("c1", []), "url-router-executor", { name: "假壳" });

  const settled = executor.dispatch(COMMAND);
  executor.shutdown();
  expect((await settled).kind).toBe("gone");
});

test("下发之前就没有执行器 → 直接 gone(不挂起一条没人收的指令)", async () => {
  const { executor } = executorHub();
  expect((await executor.dispatch(COMMAND)).kind).toBe("gone");
});

test("两个等待窗都有缺省值,也都能被环境变量覆写(120s / 10s,spec §5)", () => {
  expect(executorHub().executor.timeoutMs).toBe(120_000);
  expect(executorHub().executor.launchWaitMs).toBe(10_000);
  const overridden = executorHub({
    [EXECUTION_TIMEOUT_ENV]: "5000",
    [LAUNCH_WAIT_ENV]: "250",
  }).executor;
  expect(overridden.timeoutMs).toBe(5000);
  expect(overridden.launchWaitMs).toBe(250);
});

// MARK: - 硬边界:os-dialog 的名单钉死 + 既有 dangerous 行为不变

/** 生产注册表里那份**完整**的能力清单(与 `daemon/runtime.ts` 的登记顺序同源)。 */
function productionDescriptors(): CapabilityDescriptor[] {
  const hub = createClientHub();
  const audit = silentAudit();
  const arbiter = createArbiter({ paths: PATHS, hub, audit, env: {} });
  const supervisor = createProxySupervisor(PATHS, {}, () => {});
  const registry = new CapabilityRegistry([
    ...BUILTIN_CAPABILITIES,
    ...proxyCapabilities({ paths: PATHS, env: {}, supervisor }),
    ...urlRouterCapabilities({ paths: PATHS, env: {} }),
    ...arbitrationCapabilities({ paths: PATHS, arbiter, audit }),
  ]);
  supervisor.stop();
  return registry.list();
}

test("**os-dialog 的名单恰好是那两条** —— 别的 dangerous 能力标上它就是把仲裁悄悄关掉", () => {
  const osDialog = productionDescriptors()
    .filter((descriptor) => confirmationModeOf(descriptor) === "os-dialog")
    .map((descriptor) => descriptor.id);

  expect(osDialog.sort()).toEqual(["url-router.restore", "url-router.takeover"]);
});

test("**既有 dangerous 能力一个字都没变**:除那两条外,全部仍是 confirm-agent", () => {
  const dangerous = productionDescriptors().filter((descriptor) => descriptor.risk === "dangerous");
  // 先证明这张表不是空的(否则下面那条断言等于没跑)。
  expect(dangerous.length).toBeGreaterThan(2);

  const stillArbitrated = dangerous
    .filter((descriptor) => confirmationModeOf(descriptor) !== "os-dialog")
    .map((descriptor) => descriptor.id);
  expect(stillArbitrated.length).toBe(dangerous.length - 2);
  for (const descriptor of dangerous) {
    if (descriptor.id.startsWith("url-router.")) continue;
    expect(confirmationModeOf(descriptor)).toBe("confirm-agent");
    // manifest 上**根本没有这个字段**才是"一个字都没变"的字面意思。
    expect(descriptor.confirmation).toBeUndefined();
  }
});

test("行为对照:同一个注册表里,confirm-agent 的 dangerous 照旧默拒、handler 一次都不被碰到", async () => {
  let confirmAgentHandlerRan = 0;
  let osDialogHandlerRan = 0;
  const registry = new CapabilityRegistry([
    capabilityStub("demo.classic", { risk: "dangerous" }, () => {
      confirmAgentHandlerRan += 1;
      return { ran: true };
    }),
    capabilityStub("demo.os-dialog", { risk: "dangerous", confirmation: "os-dialog" }, () => {
      osDialogHandlerRan += 1;
      return { ran: true };
    }),
  ]);

  let confirmCalls = 0;
  const context = {
    // **一个确认器都没有**:第①层默拒的局面。
    confirmerPresent: () => false,
    refuseWithoutConfirmer: () => ({
      code: ErrorCode.confirmationUnavailable,
      message: "没有确认器",
    }),
    confirm: async () => {
      confirmCalls += 1;
      return undefined;
    },
  };

  const classic = await registry.invoke("demo.classic", {}, context);
  expect(classic.ok).toBe(false);
  expect(classic.ok === false && classic.error.code).toBe(ErrorCode.confirmationUnavailable);
  // 被拒时 handler **一次都不会被碰到** —— 这是 04 票之前就有的保证,本票一个字都没动它。
  expect(confirmAgentHandlerRan).toBe(0);

  const osDialog = await registry.invoke("demo.os-dialog", {}, context);
  // 它的确认由系统弹框承载,所以直接进 handler(handler 里那趟指令帧往返才是确认仪式)。
  expect(osDialog.ok).toBe(true);
  expect(osDialogHandlerRan).toBe(1);
  // 而且**一次都没去问确认器** —— 双确认正是 04 决策底账否掉的方案。
  expect(confirmCalls).toBe(0);
});

test("os-dialog 标在 safe/normal 上不改变任何行为(它们本来就直通)", async () => {
  let ran = 0;
  const registry = new CapabilityRegistry([
    capabilityStub("demo.normal", { risk: "normal", confirmation: "os-dialog" }, () => {
      ran += 1;
      return { ran: true };
    }),
  ]);
  const outcome = await registry.invoke("demo.normal", {}, {
    confirmerPresent: () => false,
    refuseWithoutConfirmer: () => ({ code: ErrorCode.confirmationUnavailable, message: "x" }),
    confirm: async () => undefined,
  });
  expect(outcome.ok).toBe(true);
  expect(ran).toBe(1);
});

function capabilityStub(
  id: string,
  descriptor: Partial<CapabilityDescriptor> & Pick<CapabilityDescriptor, "risk">,
  handler: () => object,
): Capability {
  return {
    descriptor: { id, summary: `测试桩 ${id}`, parameters: [], ...descriptor },
    handler: () => handler() as never,
  };
}
