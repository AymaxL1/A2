// CLI 缝:订阅管理(07 票)—— 清单 / 激活 / 更新 / 换源 / 删除。
//
// **一处必须先说清的测试形状**:`proxy.subscription.add` 与 `.remove` 是 **dangerous**。
// 07 票时没有确认器,所以它们只能验一件事 —— **fail-closed 默拒 + 不留痕**;`list` / `activate` /
// `update` 这三条 safe/normal 档的全链路,用**直接把清单与物化配置写进沙盒**的方式起头
// (那两份文件的格式是登记在案的落盘约定,不是内部细节)。
// **08 票补上确认器之后,文件末尾新增了一组「经 add 造数据」的链路**,与前面那组默拒断言并存对照 ——
// 同一条能力,有人在场与无人在场是两种收场,两种都得有活体证据。
//
// 订阅源一律用 `file://` 指向沙盒里的文件:**门禁不出网**。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { SubscriptionListResultSchema } from "../src/contract/wire.ts";
import { subscriptionId } from "../src/proxy/subscriptions.ts";
import { connectFakeClient, type FakeClient } from "./support/fake-client.ts";
import { runCli } from "./support/harness.ts";
import {
  body,
  cleanupProxySandbox,
  makeProxySandbox,
  out,
  provisionManaged,
  proxy,
  startForeignInstance,
  startProxyDaemon,
  type ProxySandbox,
} from "./support/proxy-sandbox.ts";

const BASE_GROUPS = "PROXY=A1,A2;GLOBAL=,A1";

/**
 * 一份订阅正文。**头几行有意与 a2 头部撞名**(mixed-port / external-controller / secret):
 * 它们必须被摘掉,否则 a2 一重载就把自己的控制端点交出去了 —— 那等于把内核的手脚砍了。
 */
function subscriptionBody(groups: string, marker: string): string {
  return [
    `# fake-groups: ${groups}`,
    `# marker: ${marker}`,
    "mixed-port: 1234",
    "external-controller: 127.0.0.1:1",
    "secret: not-mine",
    "proxies: []",
    "proxy-groups: []",
    "rules:",
    "  - MATCH,DIRECT",
    "",
  ].join("\n");
}

let sandbox: ProxySandbox | undefined;
/** 本文件里连过的假确认器(08 票起有了确认器,teardown 必须把它们收干净)。 */
let confirmers: FakeClient[] = [];

beforeEach(() => {
  sandbox = undefined;
  confirmers = [];
});

afterEach(async () => {
  for (const client of confirmers) await client.close();
  confirmers = [];
  if (sandbox) await cleanupProxySandbox(sandbox);
  sandbox = undefined;
});

async function managedBox(extraEnv: Record<string, string> = {}): Promise<ProxySandbox> {
  const box = (sandbox = await makeProxySandbox({ groups: BASE_GROUPS }));
  Object.assign(box.env, extraEnv);
  await provisionManaged(box);
  await startProxyDaemon(box);
  return box;
}

/** 直接把一条订阅落进沙盒(清单 + 物化配置),绕开 dangerous 的 add(理由见文件头)。 */
async function seed(
  box: ProxySandbox,
  entries: { name: string; body: string; source?: string }[],
  activeName?: string,
): Promise<Record<string, string>> {
  const dir = path.join(box.home, "mihomo", "subscriptions");
  await mkdir(path.join(dir, "configs"), { recursive: true });
  const ids: Record<string, string> = {};
  const subscriptions = [];
  for (const entry of entries) {
    const id = subscriptionId(entry.name) as string;
    ids[entry.name] = id;
    await writeFile(path.join(dir, "configs", `${id}.conf`), entry.body);
    subscriptions.push({
      id,
      name: entry.name,
      source: entry.source ?? `file://${path.join(box.root, `${id}.yaml`)}`,
      lastUpdatedAt: "2026-08-05T00:00:00.000Z",
      bytes: new TextEncoder().encode(entry.body).byteLength,
    });
  }
  await writeFile(
    path.join(dir, "catalog.json"),
    `${JSON.stringify({ activeId: activeName ? ids[activeName] : null, subscriptions }, null, 2)}\n`,
  );
  return ids;
}

// MARK: - dangerous 档(本票内默拒)

test("subscription add 是 dangerous:无确认器 → 默拒 + 退出码 2,且**一点痕迹都没留**", async () => {
  const box = await managedBox();
  const catalogPath = path.join(box.home, "mihomo", "subscriptions", "catalog.json");

  const result = await proxy(box, [
    "subscription",
    "add",
    "--name",
    "机场甲",
    "--source",
    `file://${path.join(box.root, "any.yaml")}`,
  ]);

  expect(result.exitCode).toBe(2);
  const parsed = body(result);
  expect(parsed.ok).toBe(false);
  expect(parsed.error.code).toBe("confirmation_unavailable");
  expect(parsed.error.guidance.steps.length).toBeGreaterThan(0);
  // handler 一次都没被碰到:既没有清单,也没有物化配置。
  expect(existsSync(catalogPath)).toBe(false);
  expect(existsSync(path.join(box.home, "mihomo", "subscriptions", "configs"))).toBe(false);
}, 30000);

test("subscription remove 同样是 dangerous:默拒之后那条订阅原封不动", async () => {
  const box = await managedBox();
  const ids = await seed(box, [{ name: "甲", body: subscriptionBody("S=S1", "v1") }]);

  const result = await proxy(box, ["subscription", "remove", "--id", ids["甲"] as string]);

  expect(result.exitCode).toBe(2);
  expect(body(result).error.code).toBe("confirmation_unavailable");
  const listed = out(await proxy(box, ["subscription", "list"]));
  expect(listed.subscriptions.map((s: { id: string }) => s.id)).toEqual([ids["甲"]]);
}, 30000);

// MARK: - list

test("subscription list:空清单 → active=null、条目为空,退出码 0(不报错)", async () => {
  const box = await managedBox();

  const result = await proxy(box, ["subscription", "list"]);

  expect(result.exitCode).toBe(0);
  const listed = out(result);
  expect(SubscriptionListResultSchema.safeParse(listed).success).toBe(true);
  expect(listed.active).toBeNull();
  expect(listed.subscriptions).toEqual([]);
}, 30000);

test("id 由名字确定性派生:同名(大小写不敏感)同 id,两个不同的纯中文名不塌成同一个", () => {
  expect(subscriptionId("subA")).toBe(subscriptionId("SUBA"));
  expect(subscriptionId("机场甲")).not.toBe(subscriptionId("机场乙"));
  // 纯非 ASCII 名抠不出 slug,但仍有确定性哈希后缀 —— id 永不为空。
  expect(subscriptionId("机场甲")).toMatch(/^[0-9a-f]{8}$/);
  expect(subscriptionId("  ")).toBeUndefined();
  expect(subscriptionId("")).toBeUndefined();
});

// MARK: - activate

test("subscription activate:正文渲染进自管配置、内核重载、分组真的换了;a2 头部把控制端点保住", async () => {
  const box = await managedBox();
  const ids = await seed(box, [{ name: "甲", body: subscriptionBody("SUBA=S1,S2", "v1") }]);

  // 激活前:分组来自沙盒的默认注入。
  expect(
    out(await proxy(box, ["groups"])).groups.map((g: { name: string }) => g.name),
  ).toEqual(["GLOBAL", "PROXY"]);

  const result = await proxy(box, ["subscription", "activate", "--id", ids["甲"] as string]);

  expect(result.exitCode).toBe(0);
  const activated = out(result);
  expect(activated.action).toBe("activated");
  expect(activated.active).toBe(ids["甲"]);
  expect(activated.reloaded).toBe(true);

  // 内核**重载之后**报的分组换成了订阅里那份 —— 这条才是"真的生效了"。
  const groups = out(await proxy(box, ["groups"]));
  expect(groups.groups.map((g: { name: string }) => g.name)).toEqual(["SUBA"]);
  expect(groups.groups[0].all).toEqual(["S1", "S2"]);

  // a2 头部赢了:订阅里那几个撞名的顶层键被摘掉,控制端点与 secret 仍是 a2 的。
  const config = await readFile(box.managedConfig, "utf8");
  expect(config).toContain(`external-controller: 127.0.0.1:${box.controllerPort}`);
  expect(config).not.toContain("127.0.0.1:1");
  expect(config).not.toContain("not-mine");
  expect(config).toContain(`mixed-port: ${box.mixedPort}`);
  expect(config).not.toContain("mixed-port: 1234");
  expect(config).toContain("订阅正文里这些顶层键由 a2 接管、已摘除");
  // 订阅自己的正文照样在(注释与规则都留着)。
  expect(config).toContain("# marker: v1");
  expect(config).toContain("- MATCH,DIRECT");

  // 配置面也如实反映激活项。
  expect(out(await proxy(box, ["config"])).activeSubscription).toBe(ids["甲"]);
}, 30000);

test("subscription activate:已经是激活项 → 幂等(不再打扰内核,reloaded=false)", async () => {
  const box = await managedBox();
  const ids = await seed(box, [{ name: "甲", body: subscriptionBody("SUBA=S1", "v1") }]);
  await proxy(box, ["subscription", "activate", "--id", ids["甲"] as string]);

  const again = out(await proxy(box, ["subscription", "activate", "--id", ids["甲"] as string]));

  expect(again.action).toBe("activated");
  expect(again.reloaded).toBe(false);
}, 30000);

test("subscription activate:未知 id → subscription_failed + 退出码 5,激活项不变", async () => {
  const box = await managedBox();
  const ids = await seed(box, [{ name: "甲", body: subscriptionBody("SUBA=S1", "v1") }], "甲");

  const result = await proxy(box, ["subscription", "activate", "--id", "nope-00000000"]);

  expect(result.exitCode).toBe(5);
  const parsed = body(result);
  expect(parsed.error.code).toBe("subscription_failed");
  expect(out(await proxy(box, ["subscription", "list"])).active).toBe(ids["甲"]);
}, 30000);

test("subscription activate:内核不认那份配置 → 回滚,清单与磁盘配置都退回上一态(无半态)", async () => {
  const box = (sandbox = await makeProxySandbox({ groups: BASE_GROUPS }));
  await provisionManaged(box);
  const ids = await seed(box, [{ name: "甲", body: subscriptionBody("SUBA=S1", "v1") }]);
  const before = await readFile(box.managedConfig, "utf8");

  // 换成一个"拒绝一切重载"的假内核实例。
  await runCli(["mihomo", "uninstall", "--json"], { home: box.home, env: box.env });
  await runCli(["mihomo", "install", "--json"], {
    home: box.home,
    env: { ...box.env, A2_FAKE_MIHOMO_REJECT_RELOAD: "1" },
  });
  await startProxyDaemon(box);

  const result = await proxy(box, ["subscription", "activate", "--id", ids["甲"] as string]);

  expect(result.exitCode).toBe(5);
  expect(body(result).error.code).toBe("proxy_operation_failed");
  // 清单退回"没有激活项",磁盘上的配置逐字回到激活前。
  expect(out(await proxy(box, ["subscription", "list"])).active).toBeNull();
  expect(await readFile(box.managedConfig, "utf8")).toBe(before);
}, 30000);

// MARK: - update

test("subscription update:重新拉取 file:// 源、激活项重载、分组换成新版本", async () => {
  const box = await managedBox();
  const sourcePath = path.join(box.root, "feed.yaml");
  await writeFile(sourcePath, subscriptionBody("SUBA=S1,S2", "v2"));
  const ids = await seed(
    box,
    [{ name: "甲", body: subscriptionBody("SUBA=S1", "v1"), source: `file://${sourcePath}` }],
    "甲",
  );
  await proxy(box, ["subscription", "activate", "--id", ids["甲"] as string]);
  expect(out(await proxy(box, ["groups"])).groups[0].all).toEqual(["S1"]);

  const result = await proxy(box, ["subscription", "update", "--id", ids["甲"] as string]);

  expect(result.exitCode).toBe(0);
  const updated = out(result);
  expect(updated.action).toBe("updated");
  expect(updated.reloaded).toBe(true);
  expect(updated.subscription.lastUpdatedAt).not.toBe("2026-08-05T00:00:00.000Z");
  // 拉到的新正文真的生效了。
  expect(out(await proxy(box, ["groups"])).groups[0].all).toEqual(["S1", "S2"]);
  expect(await readFile(box.managedConfig, "utf8")).toContain("# marker: v2");
}, 30000);

test("subscription update:拉取失败 → 什么都没改(物化配置与激活项原封不动)", async () => {
  const box = await managedBox();
  const ids = await seed(
    box,
    [
      {
        name: "甲",
        body: subscriptionBody("SUBA=S1", "v1"),
        source: `file://${path.join(box.root, "missing.yaml")}`,
      },
    ],
    "甲",
  );
  await proxy(box, ["subscription", "activate", "--id", ids["甲"] as string]);
  const configBefore = await readFile(box.managedConfig, "utf8");

  const result = await proxy(box, ["subscription", "update", "--id", ids["甲"] as string]);

  expect(result.exitCode).toBe(5);
  expect(body(result).error.code).toBe("subscription_failed");
  expect(await readFile(box.managedConfig, "utf8")).toBe(configBefore);
  expect(
    await readFile(
      path.join(box.home, "mihomo", "subscriptions", "configs", `${ids["甲"]}.conf`),
      "utf8",
    ),
  ).toContain("# marker: v1");
}, 30000);

test("subscription update:内容为空 → 拒绝落盘(空订阅比坏订阅更难查)", async () => {
  const box = await managedBox();
  const sourcePath = path.join(box.root, "empty.yaml");
  await writeFile(sourcePath, "   \n\n");
  const ids = await seed(
    box,
    [{ name: "甲", body: subscriptionBody("SUBA=S1", "v1"), source: `file://${sourcePath}` }],
    "甲",
  );

  const result = await proxy(box, ["subscription", "update", "--id", ids["甲"] as string]);

  expect(result.exitCode).toBe(5);
  expect(body(result).error.message).toContain("为空");
  expect(
    await readFile(
      path.join(box.home, "mihomo", "subscriptions", "configs", `${ids["甲"]}.conf`),
      "utf8",
    ),
  ).toContain("# marker: v1");
}, 30000);

// MARK: - 正文里的 YAML 文档分隔符(拒绝,不摘除)

test("update:拉到的正文含 `---` → 结构化拒绝(带行号),旧的那份一个字节都不动", async () => {
  const box = await managedBox();
  const sourcePath = path.join(box.root, "two-docs.yaml");
  // 两份配置被粘在了一起 —— 拼进 a2 头部之后 mihomo 只会读到第一个文档(只剩 a2 那几行),
  // 重载"成功"而订阅整份静默失效。这正是必须**拒绝**而不是摘除的那种输入。
  await writeFile(
    sourcePath,
    ["# fake-groups: SUBA=S9", "proxies: []", "---", "rules:", "  - MATCH,DIRECT", ""].join("\n"),
  );
  const ids = await seed(
    box,
    [{ name: "甲", body: subscriptionBody("SUBA=S1", "v1"), source: `file://${sourcePath}` }],
    "甲",
  );
  await proxy(box, ["subscription", "activate", "--id", ids["甲"] as string]);
  const configBefore = await readFile(box.managedConfig, "utf8");

  const result = await proxy(box, ["subscription", "update", "--id", ids["甲"] as string]);

  expect(result.exitCode).toBe(5);
  const parsed = body(result);
  expect(parsed.error.code).toBe("subscription_failed");
  expect(parsed.error.message).toContain("文档分隔符");
  // 行号要指得准(第 3 行就是那条 `---`),人才知道去哪儿裁。
  expect(parsed.error.message).toContain("第 3 行");
  expect(parsed.error.guidance.context.line).toBe("3");
  // **失败不留痕**:物化配置与已生效的自管配置都还是旧的那一份。
  expect(
    await readFile(
      path.join(box.home, "mihomo", "subscriptions", "configs", `${ids["甲"]}.conf`),
      "utf8",
    ),
  ).toContain("# marker: v1");
  expect(await readFile(box.managedConfig, "utf8")).toBe(configBefore);
}, 30000);

test("activate:物化配置在 a2 背后被改成多文档 → 渲染前那道闸把它拦下(不静默失效)", async () => {
  const box = await managedBox();
  const ids = await seed(box, [
    { name: "甲", body: ["proxies: []", "...", "rules: []", ""].join("\n") },
  ]);

  const result = await proxy(box, ["subscription", "activate", "--id", ids["甲"] as string]);

  expect(result.exitCode).toBe(5);
  const parsed = body(result);
  expect(parsed.error.code).toBe("subscription_failed");
  expect(parsed.error.message).toContain("文档分隔符");
  // 拒绝即指引:告诉人去哪一行看、裁好之后怎么换源。
  const commands = parsed.error.guidance.steps.map((s: { command?: string }) => s.command);
  expect(commands.some((c: string | undefined) => c?.includes("subscription add"))).toBe(true);
  // 激活项没被改成它(半态都没留下)。
  expect(out(await proxy(box, ["subscription", "list"])).active).toBeNull();
}, 30000);

// MARK: - http(s) 订阅源(回环,不出网)

test("update:http:// 源走真 HTTP 往返(回环夹具),拉到的正文生效", async () => {
  const box = await managedBox();
  // 起一个**回环**上的订阅源。与假 mihomo 同一种姿势:门禁里的"网络"只到 127.0.0.1 为止,
  // 「门禁不出网」这条纪律说的是不连外网,不是不许有 HTTP 往返。
  let hits = 0;
  const feed = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request) {
      if (!new URL(request.url).pathname.endsWith("/sub.yaml")) {
        return new Response("not found", { status: 404 });
      }
      hits += 1;
      return new Response(subscriptionBody("SUBA=H1,H2", "http-v2"));
    },
  });
  try {
    const source = `http://127.0.0.1:${feed.port}/sub.yaml`;
    const ids = await seed(
      box,
      [{ name: "甲", body: subscriptionBody("SUBA=S1", "v1"), source }],
      "甲",
    );
    await proxy(box, ["subscription", "activate", "--id", ids["甲"] as string]);

    const result = await proxy(box, ["subscription", "update", "--id", ids["甲"] as string]);

    expect(result.exitCode).toBe(0);
    expect(out(result).reloaded).toBe(true);
    expect(hits).toBeGreaterThan(0);
    // 拉到的新正文真的生效了(分组换成 http 那份)。
    expect(out(await proxy(box, ["groups"])).groups[0].all).toEqual(["H1", "H2"]);
    expect(await readFile(box.managedConfig, "utf8")).toContain("# marker: http-v2");
  } finally {
    feed.stop(true);
  }
}, 30000);

test("update:http 源返回 404 → subscription_failed,什么都没改", async () => {
  const box = await managedBox();
  const feed = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch: () => new Response("gone", { status: 404 }),
  });
  try {
    const ids = await seed(
      box,
      [
        {
          name: "甲",
          body: subscriptionBody("SUBA=S1", "v1"),
          source: `http://127.0.0.1:${feed.port}/sub.yaml`,
        },
      ],
      "甲",
    );

    const result = await proxy(box, ["subscription", "update", "--id", ids["甲"] as string]);

    expect(result.exitCode).toBe(5);
    const parsed = body(result);
    expect(parsed.error.code).toBe("subscription_failed");
    expect(parsed.error.detail).toContain("404");
    expect(
      await readFile(
        path.join(box.home, "mihomo", "subscriptions", "configs", `${ids["甲"]}.conf`),
        "utf8",
      ),
    ).toContain("# marker: v1");
  } finally {
    feed.stop(true);
  }
}, 30000);

// MARK: - 清单损坏

test("清单文件损坏:一切读写都停手 + 指引,**绝不把它当空清单覆盖掉**", async () => {
  const box = await managedBox();
  const dir = path.join(box.home, "mihomo", "subscriptions");
  await mkdir(dir, { recursive: true });
  const catalogPath = path.join(dir, "catalog.json");
  await writeFile(catalogPath, "{ 这不是 JSON");

  const listed = await proxy(box, ["subscription", "list"]);
  expect(listed.exitCode).toBe(5);
  const parsed = body(listed);
  expect(parsed.error.code).toBe("subscription_failed");
  expect(parsed.error.message).toContain("损坏");
  expect(parsed.error.guidance.context.catalogPath).toBe(catalogPath);

  const activated = await proxy(box, ["subscription", "activate", "--id", "whatever"]);
  expect(activated.exitCode).toBe(5);

  // 那份坏文件**一个字节都没被改**(内核不替你删,也绝不覆盖)。
  expect(await readFile(catalogPath, "utf8")).toBe("{ 这不是 JSON");
}, 30000);

// MARK: - 收编档的边界

test("收编档:订阅激活一律 mihomo_not_managed(别人的实例其配置归它的主人)", async () => {
  const box = (sandbox = await makeProxySandbox());
  await startForeignInstance(box, { groups: "PROXY=F1,F2" });
  await runCli(["mihomo", "install", "--json"], { home: box.home, env: box.env });
  await startProxyDaemon(box);
  const ids = await seed(box, [{ name: "甲", body: subscriptionBody("SUBA=S1", "v1") }]);

  const result = await proxy(box, ["subscription", "activate", "--id", ids["甲"] as string]);

  expect(result.exitCode).toBe(5);
  const parsed = body(result);
  expect(parsed.error.code).toBe("mihomo_not_managed");
  const commands = parsed.error.guidance.steps.map((s: { command?: string }) => s.command);
  expect(commands).toContain("a2 mihomo install --isolated --json");
  // list 仍然可用(它压根不碰内核)。
  expect((await proxy(box, ["subscription", "list"])).exitCode).toBe(0);
}, 30000);

// MARK: - 08 票补上确认器之后:「经 add 造数据」的那条链路(文件头留的账)
//
// 07 票在这里写下:`add` 是 dangerous、当时没有确认器,所以 S-2/S-4/S-5/S-6 四条旧断言只能顺延 08。
// 现在确认器有了 —— 下面这组就是那笔账的兑现,与上面那组「无确认器 → 默拒不留痕」并存对照。

async function withConfirmer(
  box: ProxySandbox,
  behavior: "approve" | "deny",
): Promise<FakeClient> {
  const client = await connectFakeClient({
    socketPath: box.daemon!.socketPath,
    name: "fake-panel",
    behavior,
  });
  confirmers.push(client);
  await client.register("confirm-agent");
  return client;
}

test("add 经确认器批准:真的新增了、id 带名字派生的前缀、**不自动激活**", async () => {
  const box = await managedBox();
  const confirmer = await withConfirmer(box, "approve");
  const sourcePath = path.join(box.root, "sub-a.yaml");
  await writeFile(sourcePath, subscriptionBody("SUBA=S1,S2", "v1"));

  const result = await proxy(box, [
    "subscription",
    "add",
    "--name",
    "机场甲",
    "--source",
    `file://${sourcePath}`,
  ]);

  expect(result.exitCode).toBe(0);
  const added = out(result);
  expect(added.action).toBe("added");
  expect(added.id).toBe(subscriptionId("机场甲"));
  expect(added.subscription.name).toBe("机场甲");
  expect(added.subscription.bytes).toBeGreaterThan(0);
  // **add 绝不自动激活**:引入一份来源与让它生效是两个决定。
  expect(added.reloaded).toBe(false);
  expect(added.active).toBe(null);
  expect(out(await proxy(box, ["subscription", "list"])).active).toBe(null);

  // 确认器看到的是**这一次**的真实参数(防盲批;旧 Swift 那条 `[confirm]` 日志的对位物)。
  expect(confirmer.events("confirmation")[0].request.input).toEqual({
    name: "机场甲",
    source: `file://${sourcePath}`,
  });
}, 30000);

test("add 同名再来一次 = 换源:同一个 id、action=replaced、正文被替换", async () => {
  const box = await managedBox();
  await withConfirmer(box, "approve");
  const first = path.join(box.root, "first.yaml");
  const second = path.join(box.root, "second.yaml");
  await writeFile(first, subscriptionBody("SUBA=S1", "v1"));
  await writeFile(second, subscriptionBody("SUBB=T1", "v2"));

  const added = out(
    await proxy(box, ["subscription", "add", "--name", "机场甲", "--source", `file://${first}`]),
  );
  const replaced = out(
    await proxy(box, ["subscription", "add", "--name", "机场甲", "--source", `file://${second}`]),
  );

  expect(replaced.id).toBe(added.id);
  expect(replaced.action).toBe("replaced");
  expect(replaced.subscription.source).toBe(`file://${second}`);
  const listed = out(await proxy(box, ["subscription", "list"]));
  expect(listed.subscriptions.length).toBe(1);
  const materialized = await readFile(
    path.join(box.home, "mihomo", "subscriptions", "configs", `${replaced.id}.conf`),
    "utf8",
  );
  expect(materialized).toContain("# marker: v2");
}, 30000);

test("add 空名:先于任何 I/O 就被拒(invalid_params),源一次都没被读过", async () => {
  const box = await managedBox();
  await withConfirmer(box, "approve");
  // 这个源**根本不存在** —— 若实现先去拉再校验名字,错误就会变成 subscription_failed。
  const missing = path.join(box.root, "根本没有这个文件.yaml");

  const result = await proxy(box, [
    "subscription",
    "add",
    "--name",
    "   ",
    "--source",
    `file://${missing}`,
  ]);

  expect(result.exitCode).toBe(6);
  const parsed = body(result);
  expect(parsed.error.code).toBe("invalid_params");
  expect(parsed.error.message).toContain("订阅名");
  // 什么都没落盘。
  expect(existsSync(path.join(box.home, "mihomo", "subscriptions", "catalog.json"))).toBe(false);
}, 30000);

test("add 拉取失败不留痕:清单与物化目录都不该因为一次失败的 add 而出现", async () => {
  const box = await managedBox();
  await withConfirmer(box, "approve");

  const result = await proxy(box, [
    "subscription",
    "add",
    "--name",
    "机场甲",
    "--source",
    `file://${path.join(box.root, "missing.yaml")}`,
  ]);

  expect(result.exitCode).toBe(5);
  expect(body(result).error.code).toBe("subscription_failed");
  expect(existsSync(path.join(box.home, "mihomo", "subscriptions", "catalog.json"))).toBe(false);
  expect(existsSync(path.join(box.home, "mihomo", "subscriptions", "configs"))).toBe(false);
}, 30000);

test("add 被确认器拒绝:confirmation_denied + 退出码 2,同样一点痕迹都没留", async () => {
  const box = await managedBox();
  const sourcePath = path.join(box.root, "sub-a.yaml");
  await writeFile(sourcePath, subscriptionBody("SUBA=S1", "v1"));
  await withConfirmer(box, "deny");

  const result = await proxy(box, [
    "subscription",
    "add",
    "--name",
    "机场甲",
    "--source",
    `file://${sourcePath}`,
  ]);

  expect(result.exitCode).toBe(2);
  expect(body(result).error.code).toBe("confirmation_denied");
  expect(existsSync(path.join(box.home, "mihomo", "subscriptions", "catalog.json"))).toBe(false);
}, 30000);

test("remove 经确认器批准:清单条目与物化配置一起消失", async () => {
  const box = await managedBox();
  await withConfirmer(box, "approve");
  const ids = await seed(box, [{ name: "甲", body: subscriptionBody("S=S1", "v1") }]);
  const configPath = path.join(box.home, "mihomo", "subscriptions", "configs", `${ids["甲"]}.conf`);
  expect(existsSync(configPath)).toBe(true);

  const result = await proxy(box, ["subscription", "remove", "--id", ids["甲"] as string]);

  expect(result.exitCode).toBe(0);
  expect(out(result).action).toBe("removed");
  expect(existsSync(configPath)).toBe(false);
  expect(out(await proxy(box, ["subscription", "list"])).subscriptions).toEqual([]);
}, 30000);
