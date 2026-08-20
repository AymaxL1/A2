// CLI 缝:`a2 guide` —— 给 AI 助手的使用说明全文(08 票)。
//
// 这条命令的价值全在**它在什么时候还答得出话**:一个刚下载完面板、内核服务还没装起来的
// agent,恰恰最需要读到"CLI 在哪、先跑什么、什么不许干"。所以断言里除了形状与全文要件,
// 还专门钉着「daemon 没跑照样退出 0 且一个字节都不写」——与 `a2 about` 同一种纪律。
//
// 另一半是**单一事实源**:面板已装版的剪贴板文本从 05 票的"全文副本"缩成一句指针
// (见 Sources/A2Panel/A2AssistantGuide.swift),所以全文只剩这一份;它要是哪天不再提
// CLI 完整路径或边界两条,面板那句指针就成了指向空处的箭头。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { readdir } from "node:fs/promises";
import { GuideResultSchema } from "../src/contract/wire.ts";
import { cleanupHome, makeHome, parseJsonStdout, runCli, socketPathFor } from "./support/harness.ts";

let home: string;

beforeEach(async () => {
  home = await makeHome();
});

afterEach(async () => {
  await cleanupHome(home);
});

test("guide --json:一条包封,result 合 GuideResult 契约(text 是全文本身)", async () => {
  const result = await runCli(["guide", "--json"], { home });

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(true);
  expect(GuideResultSchema.safeParse(body.result).success).toBe(true);
  expect(Object.keys(body.result)).toEqual(["text"]);
  expect((body.result.text as string).startsWith("【给 AI 助手的 A2 使用说明】")).toBe(true);
});

test("全文要件:CLI 完整路径、--json 纪律、先跑哪三条 status、配置归 agent、边界两条", async () => {
  const text = parseJsonStdout(await runCli(["guide", "--json"], { home })).result.text as string;

  // 路径是这份说明存在的头号理由(刻意不在 PATH 上 —— agent 猜不到就用不上)。
  expect(text).toContain("~/.a2/bin/a2");
  expect(text).toContain("刻意不在 PATH 上");
  expect(text).toContain("~/.a2/bin/a2 mihomo status --json");
  expect(text).toContain("~/.a2/bin/a2 mihomo enable --mode=embedded --json");
  // 边界那一节必须在:它是写给 agent 的行为指令(转告、不绕过;别人的 mihomo 只读)。
  expect(text).toContain("■ 边界");
  expect(text).toContain("dangerous");
  expect(text).toContain("不要试图绕过");
  expect(text).toContain("不要动它");
  // 配置归 agent 直接改 —— 内核这边没有"帮你合并订阅"的命令,说明里也不许暗示有。
  expect(text).toContain("■ 配置归你(agent)管");
  expect(text).toContain("不要把订阅里的 rules 整份搬来覆盖用户已有策略");
});

test("版本号取内核既有常量:与 a2 version 报的是同一个数(说明随内核一起升级)", async () => {
  const text = parseJsonStdout(await runCli(["guide", "--json"], { home })).result.text as string;
  const version = (await runCli(["version"], { home })).stdout.trim();

  expect(text).toContain(`(A2 内核 ${version})`);
});

test("人类面:直接打印全文(不是 JSON),退出码 0", async () => {
  const result = await runCli(["guide"], { home });

  expect(result.exitCode).toBe(0);
  expect(result.stdout.startsWith("{")).toBe(false);
  expect(result.stdout).toContain("■ 调用方式");
  expect(result.stdout).toContain("~/.a2/bin/a2");
  // 机读面与人类面同源:同一段文本,不另写一套说辞。
  const text = parseJsonStdout(await runCli(["guide", "--json"], { home })).result.text as string;
  expect(result.stdout.trim()).toBe(text.trim());
});

test("**不依赖 daemon**:没跑也答得出,而且一个字节的状态都不写(与 about 同一种纪律)", async () => {
  const result = await runCli(["guide", "--json"], { home });

  expect(result.exitCode).toBe(0);
  expect(await Bun.file(socketPathFor(home)).exists()).toBe(false);
  expect(await readdir(home)).toEqual([]);
});

test("guide 用法:多余参数是用法错(退出码 1),指引给出那条正确写法;--help 给本面用法", async () => {
  const bad = await runCli(["guide", "extra", "--json"], { home });
  expect(bad.exitCode).toBe(1);
  const error = parseJsonStdout(bad).error;
  expect(error.code).toBe("usage");
  const commands = error.guidance.steps.map((step: { command?: string }) => step.command);
  expect(commands).toContain("a2 guide");

  const help = await runCli(["guide", "--help", "--json"], { home });
  expect(help.exitCode).toBe(0);
  expect(parseJsonStdout(help).result.usage as string).toContain("a2 guide");
});

test("顶层帮助列出 guide(可发现性:agent 不该靠猜才知道有这条命令)", async () => {
  const usage = parseJsonStdout(await runCli(["help", "--json"], { home })).result.usage as string;

  expect(usage).toContain("guide");
});
