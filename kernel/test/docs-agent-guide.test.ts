// agent 指引物(`docs/agents/a2-cli.md`)与内核的一致性 —— 旧 `aa docs agents-md` 那批断言的新落点。
//
// ============================================================================
// 为什么这批断言必须存在
// ============================================================================
// 旧仓有一条命令 `aa docs agents-md` 会**打印**一段接入指引,门禁逐条 grep 它(退出码表、
// dangerous 口径、能力 id 真实存在)。新架构里那条命令没了(分发形态改判),指引物变成一份文档 ——
// 但**文档比命令更容易撒谎**:它不会因为代码改了就红。所以这批断言把它钉回内核:
//   * 它提到的每一个能力 id,都必须在**真的跑着的那个内核**的注册表里(旧 FS5);
//   * 它写的退出码表,必须与 `exit-codes.ts` 逐值对得上(旧组 4 / 组 5);
//   * 它不许出现**已作废**的旧接入片段(10 票交接单点名的两条:`capabilities result` 与 pending 态)。
//
// 一条有意的取舍:这份指引**指向 CLI 帮助而不是复述它**(11/12 票交接单的要求 ——
// `a2 plugin --help` 是插件协议的规格书)。所以这里不断言"文档里有插件协议的细节",
// 只断言"它指过去了"。

import { afterEach, beforeEach, expect, test } from "bun:test";
import path from "node:path";
import { ExitCode } from "../src/contract/exit-codes.ts";
import {
  cleanupHome,
  makeHome,
  parseJsonStdout,
  runCli,
  startDaemon,
  stopDaemon,
  type DaemonHandle,
} from "./support/harness.ts";

const GUIDE = path.resolve(import.meta.dir, "../../docs/agents/a2-cli.md");

let home: string;
let daemon: DaemonHandle | undefined;
let guide: string;

beforeEach(async () => {
  home = await makeHome();
  daemon = undefined;
  guide = await Bun.file(GUIDE).text();
});

afterEach(async () => {
  if (daemon) await stopDaemon(daemon);
  await cleanupHome(home);
});

/**
 * 文档里出现的能力 id 候选:反引号或表格里那些形如 `a.b[.c]` 的小写点分词。
 *
 * 两类同形但显然不是能力 id 的东西先摘掉:**文件名**(`*.sh` / `*.json` / …)与
 * **报文字段路径**(`error.code` 之类)。判据是显式清单而不是"看着像" ——
 * 清单之外的一切都要真的在注册表里,包括写错一个字母的 `proxy.staus`。
 */
const REPORT_FIELD_PREFIXES = ["error.", "result.", "guidance.", "context.", "steps."];

function capabilityIdsIn(text: string): string[] {
  const found = new Set<string>();
  for (const match of text.matchAll(/`([a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+)`/g)) {
    const token = match[1] as string;
    if (/\.(sh|json|md|ts|js|txt|yaml|yml|plist|invalid)$/.test(token)) continue;
    if (REPORT_FIELD_PREFIXES.some((prefix) => token.startsWith(prefix))) continue;
    found.add(token);
  }
  // 表格与代码块里的裸写法(`a2 capabilities call proxy.status --json` 这种)也算数。
  for (const match of text.matchAll(/\b(?:call|describe)\s+([a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+)/g)) {
    found.add(match[1] as string);
  }
  return [...found].sort();
}

test("**FS5 的新落点**:指引里提到的每一个能力 id,在真的跑着的内核里都存在", async () => {
  daemon = await startDaemon(home);
  const listed = parseJsonStdout(await runCli(["capabilities", "list", "--json"], { home }));
  const real = new Set(
    (listed.result.capabilities as { id: string }[]).map((capability) => capability.id),
  );

  const mentioned = capabilityIdsIn(guide).filter(
    // 插件能力是现场装出来的,不该在内建注册表里找 —— 指引里那条是**写法示例**。
    (id) => !id.startsWith("plugin."),
  );

  expect(mentioned.length).toBeGreaterThan(0);
  const ghosts = mentioned.filter((id) => !real.has(id));
  expect(ghosts).toEqual([]);
});

test("退出码表与 exit-codes.ts 逐值对得上(文档不许自己编一套语义)", () => {
  const rows = [...guide.matchAll(/^\|\s*(\d)\s*\|\s*([^|]+)\|/gm)].map((match) => ({
    code: Number.parseInt(match[1] as string, 10),
    meaning: (match[2] as string).trim(),
  }));

  expect(new Set(rows.map((row) => row.code))).toEqual(new Set(Object.values(ExitCode)));
  // 逐条抽验关键语义(旧组 4 的 7 条 grep 在这里合成一条参数化断言)。
  const meaningOf = (code: number) => rows.find((row) => row.code === code)!.meaning;
  expect(meaningOf(ExitCode.success)).toContain("成功");
  expect(meaningOf(ExitCode.usage)).toContain("用法错");
  expect(meaningOf(ExitCode.denied)).toContain("denied");
  expect(meaningOf(ExitCode.timeout)).toContain("超时");
  expect(meaningOf(ExitCode.daemonUnreachable)).toContain("daemon 不可达");
  expect(meaningOf(ExitCode.protocolError)).toContain("校验错");
});

test("dangerous 口径:三层仲裁的三条收场与「没有 --yes 旁路」都写明", () => {
  expect(guide).toContain("confirmation_unavailable");
  expect(guide).toContain("confirmation_denied");
  expect(guide).toContain("confirmation_timeout");
  expect(guide).toContain("--yes");
  expect(guide).toContain("fail-closed");
  // 「拒绝即指引:agent 只转告」是这份文档最该说清的一条。
  expect(guide).toContain("guidance");
  expect(guide).toMatch(/转告/);
});

test("**已作废的旧接入片段不许出现**(10 票交接单点名的两条)", () => {
  // pending 态整体淘汰:旧指引教 agent 拿 request-id 去轮询结果,新架构里没有这回事。
  expect(guide).not.toContain("capabilities result");
  expect(guide).not.toContain("pending");
  // `aa` 系命令名也已退场(整份文档只该出现 a2)。
  expect(guide).not.toMatch(/\baa\s+(capabilities|proxy|docs|install-cli)\b/);
});

test("指引指向 CLI 帮助而不是复述它(11/12 票交接单的要求)", () => {
  expect(guide).toContain("a2 plugin --help");
  expect(guide).toContain("a2 capabilities list --json");
  expect(guide).toContain("a2 capabilities describe");
});

test("12 票交接单第 3 条:两个新环境变量进了用户可见的文档", () => {
  expect(guide).toContain("A2_PLUGIN_BUILD_TIMEOUT_MS");
  expect(guide).toContain("BUN_INSTALL_CACHE_DIR");
});

test("指引里出现的 a2 子命令都真的存在(顶层帮助逐条对账)", async () => {
  const help = parseJsonStdout(await runCli(["help", "--json"], { home })).result.usage as string;
  const subcommands = new Set(
    [...guide.matchAll(/\ba2\s+([a-z]+)\b/g)].map((match) => match[1] as string),
  );

  const ghosts = [...subcommands].filter((name) => !help.includes(name));
  expect(ghosts).toEqual([]);
});
