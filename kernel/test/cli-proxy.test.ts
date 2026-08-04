// CLI 缝(最高缝):代理控制面 —— 状态 / 模式 / 分组 / 节点 / 测速 / 配置面(07 票)。
//
// 与 06 票那份测试同一条红线:这里的每一个「mihomo」都是 `support/fake-mihomo/` 的行为假件,
// 每一次 `networksetup` 都打在 `support/fake-networksetup/` 上,supervisor 是假的,
// 扫描面/端口/发布渠道全部注入到沙盒 —— **没有一条断言会碰到用户自己那份 mihomo 或真的系统代理**。
//
// 假件不是打桩:mihomo 假件是**有状态**的(切了模式读回来真的变了、选了节点 `now` 真的换了、
// `PUT /configs` 真的重读那份文件),所以这一组断言是端到端的:
// CLI → UDS → 注册表仲裁 → REST 写 → 再读回来。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { ProxyGroupsResultSchema, ProxyStatusResultSchema } from "../src/contract/wire.ts";
import { runCli } from "./support/harness.ts";
import {
  body,
  call,
  cleanupProxySandbox,
  makeProxySandbox,
  out,
  provisionManaged,
  proxy,
  startForeignInstance,
  startProxyDaemon,
  type ProxySandbox,
} from "./support/proxy-sandbox.ts";

// GLOBAL 有意写成 `=,A1`:第一个 token 为空 = 真核回的 `now: ""`,内核必须把它归一成缺省。
const GROUPS = "PROXY=A1,A2,SLOW;GLOBAL=,A1";
// **SLOW 有意不在延迟表里** —— 它就是"缺席即超时,绝不臆造 0"那条断言的活体样本。
const DELAYS = "A1=120;A2=300";

let sandbox: ProxySandbox | undefined;

beforeEach(() => {
  sandbox = undefined;
});

afterEach(async () => {
  if (sandbox) await cleanupProxySandbox(sandbox);
  sandbox = undefined;
});

async function managedBox(): Promise<ProxySandbox> {
  const box = (sandbox = await makeProxySandbox({ groups: GROUPS, delays: DELAYS }));
  await provisionManaged(box);
  await startProxyDaemon(box);
  return box;
}

// MARK: - 状态

test("proxy status:本机一个实例都没有 → running=false,退出码 0,且**不臆造** mode/端口/节点", async () => {
  const box = (sandbox = await makeProxySandbox());
  await startProxyDaemon(box);

  const result = await proxy(box, ["status"]);

  // 「没在跑」是这条查询的合法答案,不是查询失败(与 a2 service status 同一口径)。
  expect(result.exitCode).toBe(0);
  const parsed = body(result);
  expect(parsed.ok).toBe(true);
  const status = parsed.result.output;
  expect(ProxyStatusResultSchema.safeParse(status).success).toBe(true);
  expect(status.running).toBe(false);
  expect(status.apiReachable).toBe(false);
  expect(status.mode).toBeUndefined();
  expect(status.mixedPort).toBeUndefined();
  expect(status.node).toBeUndefined();
  expect(status.endpoint).toBeUndefined();
  // 系统代理那一格照样有答案:平台支持、但 a2 手里没有接管快照。
  expect(status.systemProxy.supported).toBe(true);
  expect(status.systemProxy.takenOver).toBe(false);
});

test("proxy status:自管实例在跑 → 两条独立事实都为真,并如实反映 mode/入站端口/当前节点", async () => {
  const box = await managedBox();

  const status = out(await proxy(box, ["status"]));

  expect(ProxyStatusResultSchema.safeParse(status).success).toBe(true);
  expect(status.running).toBe(true);
  expect(status.apiReachable).toBe(true);
  expect(status.endpoint.owner).toBe("a2");
  expect(status.endpoint.managed).toBe(true);
  expect(status.endpoint.controller).toBe(`127.0.0.1:${box.controllerPort}`);
  expect(status.endpoint.configPath).toBe(box.managedConfig);
  expect(status.mode).toBe("rule");
  // 入站端口是**内核实况**报的(不是配置文件里读的)。
  expect(status.mixedPort).toBe(box.mixedPort);
  expect(status.node).toBe("A1");
  expect(status.version).toBe("v1.19.28");
});

// MARK: - 模式

test("proxy mode:set 之后 get 读回来真的变了(PATCH /configs,不换配置文件、不碰进程)", async () => {
  const box = await managedBox();

  expect(out(await proxy(box, ["mode", "get"])).mode).toBe("rule");

  const setResult = await proxy(box, ["mode", "--mode", "global"]);
  expect(setResult.exitCode).toBe(0);
  const set = out(setResult);
  expect(set.mode).toBe("global");
  expect(set.set).toBe(true);

  // 改后读回 —— 这一条才是"真的生效了"的证据(不是回显参数)。
  expect(out(await proxy(box, ["mode", "get"])).mode).toBe("global");
  expect(out(await proxy(box, ["status"])).mode).toBe("global");
  // 配置文件一个字节都没被改:切模式是运行时开关,不落盘。
  expect(await readFile(box.managedConfig, "utf8")).toContain("mode: rule");
});

test("proxy mode:非法取值被**校验层**拦下 —— invalid_params + 退出码 6,且没触达内核", async () => {
  const box = await managedBox();
  await proxy(box, ["mode", "--mode", "global"]);

  // 大小写敏感(与旧 aa 同口径):RULE 不是 rule。
  const result = await proxy(box, ["mode", "--mode", "RULE"]);

  expect(result.exitCode).toBe(6);
  const parsed = body(result);
  expect(parsed.ok).toBe(false);
  expect(parsed.error.code).toBe("invalid_params");
  // **没触达内核**:模式仍是上一步设的 global。
  expect(out(await proxy(box, ["mode", "get"])).mode).toBe("global");
});

// MARK: - 分组 / 节点

test("proxy groups:按组名排序,候选与当前选中都是从内核读回来的", async () => {
  const box = await managedBox();

  const groups = out(await proxy(box, ["groups"]));

  expect(ProxyGroupsResultSchema.safeParse(groups).success).toBe(true);
  expect(groups.groups.map((g: { name: string }) => g.name)).toEqual(["GLOBAL", "PROXY"]);
  const group = groups.groups.find((g: { name: string }) => g.name === "PROXY");
  expect(group.all).toEqual(["A1", "A2", "SLOW"]);
  expect(group.now).toBe("A1");
  expect(group.type).toBe("Selector");
  // 内核回的 `now: ""` **归一成缺省**(而不是原样透传一个空串)。
  const global = groups.groups.find((g: { name: string }) => g.name === "GLOBAL");
  expect(global.now).toBeUndefined();
  expect(global.all).toEqual(["A1"]);
});

test("proxy node:选中之后 groups 与 status 两处读回都变了", async () => {
  const box = await managedBox();

  const result = await proxy(box, ["node", "--group", "PROXY", "--node", "A2"]);

  expect(result.exitCode).toBe(0);
  const selected = out(result);
  expect(selected.selected).toBe(true);
  expect(selected.group).toBe("PROXY");
  expect(selected.node).toBe("A2");

  const groups = out(await proxy(box, ["groups"]));
  expect(groups.groups.find((g: { name: string }) => g.name === "PROXY").now).toBe("A2");
  // status 的 `node` 是 best-effort:按组名排序后**第一个 now 非空的组**(沿旧口径)——
  // GLOBAL 的 now 是空的,所以这里读到的就是刚切过的 PROXY。
  expect(out(await proxy(box, ["status"])).node).toBe("A2");
});

test("proxy node:组不存在 → proxy_operation_failed + 退出码 5 + 指引指向 groups", async () => {
  const box = await managedBox();

  const result = await proxy(box, ["node", "--group", "NOPE", "--node", "A1"]);

  expect(result.exitCode).toBe(5);
  const parsed = body(result);
  expect(parsed.error.code).toBe("proxy_operation_failed");
  const commands = parsed.error.guidance.steps.map((s: { command?: string }) => s.command);
  expect(commands).toContain("a2 proxy groups --json");
});

// MARK: - 测速

test("proxy ping:逐节点延迟对齐候选清单,缺席的节点如实标注超时(不臆造 0)", async () => {
  const box = await managedBox();

  const result = await proxy(box, ["ping", "--group", "PROXY"]);

  expect(result.exitCode).toBe(0);
  const ping = out(result);
  expect(ping.url).toBe("http://www.gstatic.com/generate_204");
  expect(ping.timeoutMs).toBe(5000);
  // 顺序 = 该组 all 的顺序;条数 = 候选数(不是内核回了几条)。
  expect(ping.results).toEqual([
    { node: "A1", delayMs: 120, timeout: false },
    { node: "A2", delayMs: 300, timeout: false },
    // **SLOW 没有 delayMs 这个键**,而不是 delayMs: 0。
    { node: "SLOW", timeout: true },
  ]);
});

test("proxy ping:timeout 防呆 —— CLI 层挡住 inf/nan(退出码 1),内核层挡住越界有限数(退出码 6)", async () => {
  const box = await managedBox();

  for (const value of ["inf", "nan"]) {
    const result = await proxy(box, ["ping", "--group", "PROXY", "--timeout", value]);
    expect(result.exitCode).toBe(1);
    expect(body(result).error.code).toBe("usage");
  }

  // 有限但荒谬的大数:CLI 转得动,必须由内核在**发任何请求之前**拒掉。
  const huge = await call(box, "proxy.latency.test", { group: "PROXY", timeout: 1e300 });
  expect(huge.exitCode).toBe(6);
  expect(body(huge).error.code).toBe("invalid_params");
  // 越界之后 daemon 还活着(这条防呆修的正是"把宿主打崩"那个洞)。
  expect((await proxy(box, ["status"])).exitCode).toBe(0);

  // 合法的边界值照常放行。
  const ok = await proxy(box, ["ping", "--group", "PROXY", "--timeout", "1000"]);
  expect(ok.exitCode).toBe(0);
  expect(out(ok).timeoutMs).toBe(1000);
});

// MARK: - 两种写法同一条路

test("域子命令 ≡ 能力调用:a2 proxy groups 与 capabilities call proxy.groups.list 结果完全相同", async () => {
  const box = await managedBox();

  const viaDomain = body(await proxy(box, ["groups"]));
  const viaCall = body(await call(box, "proxy.groups.list"));

  // 包封的 id 是每次现造的相关性 id,别的**逐字段相同** —— 域子命令只是 argv 的门面,
  // 走的是同一个 registry.invoke(仲裁、校验、dangerous 默拒全都原样发生)。
  expect(viaDomain.result).toEqual(viaCall.result);
  expect(viaDomain.ok).toBe(true);
  expect(viaDomain.result.capability).toBe("proxy.groups.list");
});

// MARK: - 配置面

test("proxy config:改可调项 → 落盘 + 让内核重载 + 读回真的换了端口;再来一次是幂等的", async () => {
  const box = await managedBox();
  const before = out(await proxy(box, ["config"]));
  expect(before.settings.mixedPort).toBe(box.mixedPort);
  expect(before.inSync).toBe(true);
  expect(before.activeSubscription).toBeNull();

  const nextPort = box.mixedPort + 1;
  const changed = await proxy(box, ["config", "set", "--mixedPort", String(nextPort), "--logLevel", "debug"]);

  expect(changed.exitCode).toBe(0);
  const applied = out(changed);
  expect(applied.settings.mixedPort).toBe(nextPort);
  expect(applied.settings.logLevel).toBe("debug");
  expect(applied.actions).toEqual(["settings_written", "config_written", "config_reloaded"]);
  // 磁盘上的配置真的改了,而且 secret 留着(换钥匙会把已连着的客户端踢掉)。
  const config = await readFile(box.managedConfig, "utf8");
  expect(config).toContain(`mixed-port: ${nextPort}`);
  expect(config).toContain("log-level: debug");
  expect(/^secret: .+$/m.test(config)).toBe(true);
  // 内核**重载后**报的也是新端口(这才是"生效了")。
  expect(out(await proxy(box, ["status"])).mixedPort).toBe(nextPort);

  // 幂等:同样的设置再来一次,什么都没改、也没打扰内核。
  const again = out(await proxy(box, ["config", "set", "--mixedPort", String(nextPort)]));
  expect(again.actions).toEqual([]);
});

test("proxy config set:内核不认新配置 → 回滚到上一份并如实报错(磁盘与内核都不留半态)", async () => {
  const box = (sandbox = await makeProxySandbox({ groups: GROUPS }));
  await provisionManaged(box);
  await startProxyDaemon(box);
  const before = await readFile(box.managedConfig, "utf8");

  // 让假内核从此拒绝一切重载(伪造"这份配置我解析不了")。
  // 它是**进程级**旋钮,所以要重起一个带这个旋钮的实例。
  await runCli(["mihomo", "uninstall", "--json"], { home: box.home, env: box.env });
  await runCli(["mihomo", "install", "--json"], {
    home: box.home,
    env: { ...box.env, A2_FAKE_MIHOMO_REJECT_RELOAD: "1" },
  });

  const result = await proxy(box, ["config", "set", "--logLevel", "silent"]);

  expect(result.exitCode).toBe(5);
  const parsed = body(result);
  expect(parsed.error.code).toBe("proxy_operation_failed");
  expect(parsed.error.message).toContain("回滚");
  // **回滚到位**:磁盘上是回滚前那一份(逐字)。
  expect(await readFile(box.managedConfig, "utf8")).toBe(before);
}, 30000);

// MARK: - 收编档的边界(写面到配置为止)

test("收编档:改模式/选节点照做,但**换配置文件**类的动作一律 mihomo_not_managed", async () => {
  const box = (sandbox = await makeProxySandbox());
  const foreign = await startForeignInstance(box, { groups: "PROXY=F1,F2" });
  // 先真的收编一次(落一笔收编记录),这样端点解析才指向别人那个实例。
  await runCli(["mihomo", "install", "--json"], { home: box.home, env: box.env });
  await startProxyDaemon(box);

  const status = out(await proxy(box, ["status"]));
  expect(status.endpoint.owner).toBe("foreign");
  expect(status.endpoint.managed).toBe(false);
  expect(status.endpoint.controller).toBe(`127.0.0.1:${foreign.port}`);
  expect(status.endpoint.configPath).toBeUndefined();

  // ① 改运行时开关:可以(票面「收编档的写面到配置为止」)。
  expect((await proxy(box, ["mode", "--mode", "direct"])).exitCode).toBe(0);
  expect(out(await proxy(box, ["mode", "get"])).mode).toBe("direct");
  expect((await proxy(box, ["node", "--group", "PROXY", "--node", "F2"])).exitCode).toBe(0);

  // ② 换配置文件:一律拒(那是别人的文件,内核不替它换)。
  const configSet = await proxy(box, ["config", "set", "--logLevel", "debug"]);
  expect(configSet.exitCode).toBe(5);
  expect(body(configSet).error.code).toBe("mihomo_not_managed");

  // 别人的进程从头到尾活得好好的。
  expect(box.foreignProc && !box.foreignProc.killed).toBe(true);
}, 30000);

// MARK: - 没有对象时

test("没有可控制的实例 → mihomo_unreachable + 退出码 5 + 指引给出 a2 mihomo install", async () => {
  const box = (sandbox = await makeProxySandbox());
  await startProxyDaemon(box);

  const result = await proxy(box, ["mode", "get"]);

  expect(result.exitCode).toBe(5);
  const parsed = body(result);
  expect(parsed.error.code).toBe("mihomo_unreachable");
  const commands = parsed.error.guidance.steps.map((s: { command?: string }) => s.command);
  expect(commands).toContain("a2 mihomo install --json");
});

// MARK: - 用法面

test("proxy 用法错:缺动作 / 未知动作 / 未知旗标 / 缺值,一律退出码 1 + 列出本内核实际的写法", async () => {
  const box = await managedBox();

  const cases: string[][] = [
    [],
    ["nope"],
    ["groups", "--bogus", "x"],
    ["node", "--group"],
    ["node", "--group", "PROXY", "extra"],
  ];
  for (const args of cases) {
    const result = await proxy(box, args);
    expect(result.exitCode).toBe(1);
    const parsed = body(result);
    expect(parsed.error.code).toBe("usage");
    const commands = parsed.error.guidance.steps.map((s: { command?: string }) => s.command);
    expect(commands).toContain("a2 proxy --help");
  }
});

test("proxy --help --json:帮助进 result,写明两种写法等价、收编档边界与显式还原", async () => {
  const box = (sandbox = await makeProxySandbox());

  const result = await proxy(box, ["--help"]);

  expect(result.exitCode).toBe(0);
  const usage = body(result).result.usage as string;
  expect(usage).toContain("a2 capabilities call proxy.system.enable");
  expect(usage).toContain("mihomo_not_managed");
  expect(usage).toContain("system-proxy.json");
  // 帮助不需要 daemon(它是纯文本)—— 上面这条 case 压根没起 daemon。
});
