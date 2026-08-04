// CLI 缝(最高缝):`a2 capabilities list|describe|call` 的行为契约。
//
// 断言的全是外部可观察的东西:stdout 上那一条 JSON 包封、退出码、以及"响应里有没有出现 handler 的产物"。
// 旧 Swift 控制面的对应断言逐条映射见 `test/swift-parity-map.md`。
//
// 退出码语义(固定,进契约):0 成功 / 2 dangerous 被拒 / 4 daemon 不可达 / 5 能力业务失败 /
// 6 能力或参数不合契约 / 1 用法错。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { CapabilityRegistry, DuplicateCapabilityError } from "../src/capability/registry.ts";
import {
  cleanupHome,
  makeHome,
  parseJsonStdout,
  runCli,
  sendRawLine,
  socketPathFor,
  startDaemon,
  stopDaemon,
  type DaemonHandle,
} from "./support/harness.ts";

let home: string;
let daemon: DaemonHandle | undefined;

beforeEach(async () => {
  home = await makeHome();
  daemon = undefined;
});

afterEach(async () => {
  if (daemon) await stopDaemon(daemon);
  await cleanupHome(home);
});

// MARK: - 清单与 manifest

test("list --json:三档自检样本各一档在前、代理域真能力随后,顺序 = 登记顺序", async () => {
  daemon = await startDaemon(home);

  const result = await runCli(["capabilities", "list", "--json"], { home });

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(true);
  const capabilities = body.result.capabilities as { id: string; risk: string }[];
  // 三档自检样本仍在最前,且档位顺序不变(04 票立的那条断言原样保留)。
  expect(capabilities.slice(0, 3).map((c) => c.id)).toEqual([
    "demo.echo",
    "demo.note.set",
    "demo.wipe",
  ]);
  expect(capabilities.slice(0, 3).map((c) => c.risk)).toEqual(["safe", "normal", "dangerous"]);
  // 07 票起,真能力(代理域)也在这张表上 —— 它们必须经 daemon,所以只能从这里露出来。
  const ids = capabilities.map((c) => c.id);
  expect(ids).toContain("proxy.mode.set");
  expect(ids).toContain("proxy.system.disable");
  expect(ids).toContain("proxy.subscription.add");
  // 风险档随 manifest 下发,且**订阅换源仍是 dangerous**(沿旧 Swift 逐字)。
  const byId = new Map(capabilities.map((c) => [c.id, c.risk]));
  expect(byId.get("proxy.status")).toBe("safe");
  expect(byId.get("proxy.mode.set")).toBe("normal");
  expect(byId.get("proxy.subscription.add")).toBe("dangerous");
});

test("describe --json:交回可据以构造调用的参数声明(名/类型/必填/取值域)", async () => {
  daemon = await startDaemon(home);

  const echo = parseJsonStdout(
    await runCli(["capabilities", "describe", "demo.echo", "--json"], { home }),
  );
  expect(echo.result.descriptor.id).toBe("demo.echo");
  expect(echo.result.descriptor.parameters[0].name).toBe("message");
  expect(echo.result.descriptor.parameters[0].type).toBe("string");
  expect(echo.result.descriptor.parameters[0].required).toBe(true);

  const note = parseJsonStdout(
    await runCli(["capabilities", "describe", "demo.note.set", "--json"], { home }),
  );
  const scope = (note.result.descriptor.parameters as { name: string; allowedValues?: string[] }[])
    .find((p) => p.name === "scope");
  expect(scope?.allowedValues).toEqual(["session", "persistent"]);
});

test("describe 未知能力:unknown_capability + 退出码 6 + 指引给出「去哪儿看全集」", async () => {
  daemon = await startDaemon(home);

  const result = await runCli(["capabilities", "describe", "demo.nope", "--json"], { home });

  expect(result.exitCode).toBe(6);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(false);
  expect(body.error.code).toBe("unknown_capability");
  expect(body.error.guidance.steps.map((s: { command?: string }) => s.command)).toContain(
    "a2 capabilities list --json",
  );
});

// MARK: - 调用闭环

test("call safe:结构化结果 {capability, output} + 退出码 0;多余字段静默放行", async () => {
  daemon = await startDaemon(home);

  const result = await runCli(
    ["capabilities", "call", "demo.echo", "--input", '{"message":"hi","没声明的字段":1}', "--json"],
    { home },
  );

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(true);
  expect(body.result.capability).toBe("demo.echo");
  expect(body.result.output).toEqual({ echo: "hi" });
});

test("call normal:直通执行、零确认打断,退出码 0", async () => {
  daemon = await startDaemon(home);

  const result = await runCli(
    ["capabilities", "call", "demo.note.set", "--input", '{"key":"k","value":"v"}', "--json"],
    { home },
  );

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.result.output.set).toBe(true);
  expect(body.result.output.scope).toBe("session");
});

test("call:能力执行了但业务失败 → capability_failed + 退出码 5(与校验失败的 6 分开)", async () => {
  daemon = await startDaemon(home);

  const result = await runCli(
    ["capabilities", "call", "demo.echo", "--input", '{"message":"boom"}', "--json"],
    { home },
  );

  expect(result.exitCode).toBe(5);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("capability_failed");
});

test("call 参数校验:缺必填 / 类型不符 / 取值不在 allowedValues 内,各自收敛到对的 code 且退出码 6", async () => {
  daemon = await startDaemon(home);

  const missing = await runCli(["capabilities", "call", "demo.echo", "--input", "{}", "--json"], {
    home,
  });
  expect(missing.exitCode).toBe(6);
  expect(parseJsonStdout(missing).error.code).toBe("missing_parameter");

  const mismatch = await runCli(
    ["capabilities", "call", "demo.echo", "--input", '{"message":123}', "--json"],
    { home },
  );
  expect(mismatch.exitCode).toBe(6);
  expect(parseJsonStdout(mismatch).error.code).toBe("type_mismatch");

  const bogus = await runCli(
    [
      "capabilities",
      "call",
      "demo.note.set",
      "--input",
      '{"key":"k","value":"v","scope":"bogus"}',
      "--json",
    ],
    { home },
  );
  expect(bogus.exitCode).toBe(6);
  expect(parseJsonStdout(bogus).error.code).toBe("invalid_params");

  // 声明内的取值照常放行(allowedValues 不是"一律拒绝",是"只认这几个")。
  const allowed = await runCli(
    [
      "capabilities",
      "call",
      "demo.note.set",
      "--input",
      '{"key":"k","value":"v","scope":"persistent"}',
      "--json",
    ],
    { home },
  );
  expect(allowed.exitCode).toBe(0);
  expect(parseJsonStdout(allowed).result.output.scope).toBe("persistent");
});

test("call 参数出错时报文自带「去看这条能力的 manifest」的精确命令", async () => {
  daemon = await startDaemon(home);

  const result = await runCli(["capabilities", "call", "demo.echo", "--input", "{}", "--json"], {
    home,
  });

  const body = parseJsonStdout(result);
  expect(body.error.guidance.steps.map((s: { command?: string }) => s.command)).toContain(
    "a2 capabilities describe demo.echo --json",
  );
  expect(body.error.guidance.context.parameter).toBe("message");
});

// MARK: - dangerous:默拒 fail-closed + 拒绝即指引

test("call dangerous:无确认器 → confirmation_unavailable + 退出码 2,且 handler 一次都没执行", async () => {
  daemon = await startDaemon(home);

  const result = await runCli(["capabilities", "call", "demo.wipe", "--json"], { home });

  expect(result.exitCode).toBe(2);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(false);
  expect(body.error.code).toBe("confirmation_unavailable");
  // 反证:handler 的产物("wiped")在整条 stdout 里都不该出现 —— 被拒 = 压根没跑。
  expect(result.stdout).not.toContain("wiped");
});

test("dangerous 拒绝报文即指引:带机器可读的「人类如何完成」精确命令 + 免猜的上下文事实", async () => {
  daemon = await startDaemon(home);

  const body = parseJsonStdout(await runCli(["capabilities", "call", "demo.wipe", "--json"], { home }));

  const guidance = body.error.guidance;
  expect(guidance.summary.length).toBeGreaterThan(0);
  expect(guidance.steps.length).toBeGreaterThan(0);
  // 至少有一步是能原样敲的命令(agent 只转告,人类自己执行)。
  expect(guidance.steps.some((s: { command?: string }) => typeof s.command === "string")).toBe(true);
  expect(guidance.context.capability).toBe("demo.wipe");
  expect(guidance.context.risk).toBe("dangerous");
  expect(guidance.context.socketPath).toBe(socketPathFor(home));
});

test("带参数的 dangerous 调用同样默拒:参数合法与否都不改变结论", async () => {
  daemon = await startDaemon(home);

  const result = await runCli(
    ["capabilities", "call", "demo.wipe", "--input", '{"target":"disk9"}', "--json"],
    { home },
  );

  expect(result.exitCode).toBe(2);
  expect(parseJsonStdout(result).error.code).toBe("confirmation_unavailable");
  expect(result.stdout).not.toContain("wiped");
});

test("裸 UDS 直连绕开 CLI:dangerous 仍然默拒 —— 仲裁在内核里,不在客户端里", async () => {
  daemon = await startDaemon(home);

  const line = await sendRawLine(
    daemon.socketPath,
    JSON.stringify({
      v: 1,
      id: "raw-wipe",
      op: "capabilities.call",
      params: { capability: "demo.wipe", input: { target: "disk9" } },
    }),
  );

  const response = JSON.parse(line);
  expect(response.id).toBe("raw-wipe");
  expect(response.ok).toBe(false);
  expect(response.error.code).toBe("confirmation_unavailable");
  expect(line).not.toContain("wiped");
});

test("永不交互阻塞:没有 --yes 之类的旁路,dangerous 调用立刻返回而不是等谁来点头", async () => {
  daemon = await startDaemon(home);

  const bypass = await runCli(["capabilities", "call", "demo.wipe", "--yes", "--json"], { home });
  // `--yes` 不是"被忽略",是"根本不存在"——未知选项当场报用法错。
  expect(bypass.exitCode).toBe(1);
  expect(parseJsonStdout(bypass).error.code).toBe("usage");

  const started = Date.now();
  const refused = await runCli(["capabilities", "call", "demo.wipe", "--json"], { home });
  expect(refused.exitCode).toBe(2);
  expect(Date.now() - started).toBeLessThan(5000);
});

// MARK: - daemon 不可达与用法错

test("daemon 未运行:能力面同样是 daemon_unreachable + 退出码 4,且绝不隐式拉起", async () => {
  const result = await runCli(["capabilities", "list", "--json"], { home });

  expect(result.exitCode).toBe(4);
  expect(parseJsonStdout(result).error.code).toBe("daemon_unreachable");
  expect(existsSync(socketPathFor(home))).toBe(false);
});

test("用法错一律退出码 1、ok=false,且指引指向能力面自己的帮助", async () => {
  daemon = await startDaemon(home);

  const cases = [
    ["capabilities"],
    ["capabilities", "frobnicate"],
    ["capabilities", "describe"],
    ["capabilities", "describe", "demo.echo", "extra"],
    ["capabilities", "describe", "--nope", "demo.echo"],
    ["capabilities", "call"],
    ["capabilities", "call", "demo.echo", "--input"],
    ["capabilities", "call", "demo.echo", "--input", "not-json"],
    ["capabilities", "call", "demo.echo", "--input", "[1,2]"],
    ["capabilities", "list", "extra"],
  ];

  for (const args of cases) {
    const result = await runCli([...args, "--json"], { home });
    expect({ args, exitCode: result.exitCode }).toEqual({ args, exitCode: 1 });
    const body = parseJsonStdout(result);
    expect(body.ok).toBe(false);
    expect(body.error.code).toBe("usage");
    expect(body.error.guidance.steps.map((s: { command?: string }) => s.command)).toContain(
      "a2 capabilities --help",
    );
  }

  // 入参不是合法 JSON 时,错误得说清是"这串东西不是 JSON",而不是笼统的用法错。
  const badJson = parseJsonStdout(
    await runCli(["capabilities", "call", "demo.echo", "--input", "not-json", "--json"], { home }),
  );
  expect(badJson.error.message).toContain("不是合法 JSON");
});

test("可发现性:顶层帮助里能看到 capabilities,`capabilities --help` 自己也是一条包封", async () => {
  const top = parseJsonStdout(await runCli(["help", "--json"], { home }));
  expect(top.result.usage).toContain("capabilities");

  const inner = await runCli(["capabilities", "--help", "--json"], { home });
  expect(inner.exitCode).toBe(0);
  const body = parseJsonStdout(inner);
  expect(body.ok).toBe(true);
  expect(body.result.usage).toContain("dangerous");
});

// MARK: - 注册表的启动期契约(CLI 表达不了的那条:重复 id)

test("注册表拒绝重复 id:启动即失败,而不是让后者静默覆盖前者", () => {
  const one = {
    descriptor: { id: "dup", risk: "safe" as const, summary: "一号", parameters: [] },
    handler: () => ({ which: 1 }),
  };
  const two = { ...one, handler: () => ({ which: 2 }) };

  expect(() => new CapabilityRegistry([one, two])).toThrow(DuplicateCapabilityError);
});
