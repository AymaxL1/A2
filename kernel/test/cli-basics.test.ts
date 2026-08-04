// CLI 缝:不走 daemon 的那几条(help / version / 用法错)的机读面契约。
//
// 一条自述必须处处为真:**`--json` 时 stdout 上只有一条 JSON 包封**。
// 只要有一条命令在 `--json` 下吐散文,agent 的 `JSON.parse` 就得配一张"哪些命令例外"的表 —— 那张表不该存在。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { HelpResultSchema, VersionResultSchema } from "../src/contract/wire.ts";
import { cleanupHome, makeHome, parseJsonStdout, runCli } from "./support/harness.ts";

let home: string;

beforeEach(async () => {
  home = await makeHome();
});

afterEach(async () => {
  await cleanupHome(home);
});

test("version --json:一条包封而非裸版本号,result 合 VersionResult 契约", async () => {
  const result = await runCli(["version", "--json"], { home });

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(true);
  expect(body.v).toBe(1);
  expect(VersionResultSchema.safeParse(body.result).success).toBe(true);
  expect(body.result.protocol).toBe(1);
});

test("version(无 --json):人类面仍是裸版本号一行,脚本里的 $(a2 version) 不被 JSON 污染", async () => {
  const result = await runCli(["version"], { home });

  expect(result.exitCode).toBe(0);
  expect(result.stdout.trim()).toMatch(/^\d+\.\d+\.\d+$/);
});

test("help --json:帮助文本进 result,机读面不留散文空洞", async () => {
  const result = await runCli(["help", "--json"], { home });

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(true);
  expect(HelpResultSchema.safeParse(body.result).success).toBe(true);
  expect(body.result.usage).toContain("a2 [--json] <子命令>");
});

test("光敲 a2 --json:是用法错(ok=false + 退出码 1),不是成功地打了个帮助", async () => {
  const result = await runCli(["--json"], { home });

  expect(result.exitCode).toBe(1);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(false);
  expect(body.error.code).toBe("usage");
  expect(body.error.guidance.steps.map((step: { command?: string }) => step.command)).toContain(
    "a2 help",
  );
});
