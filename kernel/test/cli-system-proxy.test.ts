// CLI 缝:系统代理的**显式接管与还原**(07 票)。
//
// **红线**:整份文件里没有一条断言会碰到真的系统代理 —— 内核发的每一条 `networksetup`
// 都打在 `support/fake-networksetup/` 上(经 `A2_NETWORKSETUP` 注入),状态落在沙盒里的一个 JSON 文件。
// 这不是"为了好测":用户此刻的网络很可能正靠他自己的代理活着,把系统代理留在坏状态 = 用户断网 = 事故。
//
// 这一组的灵魂是那份 fixture 里的**第三方代理**(Ethernet → 203.0.113.9:8080):
// 「还原 = 精确复原,不是一律关闭」这句话,只有在"原本就有别人的代理"时才证得出来。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";
import { SystemProxyStatusResultSchema } from "../src/contract/wire.ts";
import { stopDaemon } from "./support/harness.ts";
import {
  body,
  call,
  cleanupProxySandbox,
  INITIAL_NETWORK_STATE,
  makeProxySandbox,
  networkCalls,
  networkState,
  out,
  provisionManaged,
  proxy,
  startProxyDaemon,
  type ProxySandbox,
} from "./support/proxy-sandbox.ts";

const GROUPS = "PROXY=A1,A2;GLOBAL=,A1";

let sandbox: ProxySandbox | undefined;

beforeEach(() => {
  sandbox = undefined;
});

afterEach(async () => {
  if (sandbox) await cleanupProxySandbox(sandbox);
  sandbox = undefined;
});

async function managedBox(extraEnv: Record<string, string> = {}): Promise<ProxySandbox> {
  const box = (sandbox = await makeProxySandbox({ groups: GROUPS }));
  Object.assign(box.env, extraEnv);
  await provisionManaged(box);
  await startProxyDaemon(box);
  return box;
}

/** 接管后每个服务的三类代理都该长这样。 */
function takenOver(port: number) {
  return { enabled: true, host: "127.0.0.1", port };
}

// MARK: - 接管

test("proxy on:两个服务 × 三类代理全部指向内核的混合端口,原第三方被覆盖", async () => {
  const box = await managedBox();

  const result = await proxy(box, ["on"]);

  expect(result.exitCode).toBe(0);
  const changed = out(result);
  expect(changed.enabled).toBe(true);
  expect(changed.host).toBe("127.0.0.1");
  // 端口取的是**内核实况**报的 mixed-port,不是配置文件里读的那个。
  expect(changed.port).toBe(box.mixedPort);

  const state = await networkState(box);
  for (const service of state.services) {
    expect(service.http).toEqual(takenOver(box.mixedPort));
    expect(service.https).toEqual(takenOver(box.mixedPort));
    expect(service.socks).toEqual(takenOver(box.mixedPort));
  }
  // 接管快照落盘了,而且里面记的是**接管前**的样子(含那个第三方代理)。
  expect(existsSync(box.snapshotPath)).toBe(true);
  const snapshot = JSON.parse(await readFile(box.snapshotPath, "utf8"));
  expect(snapshot.services).toEqual(INITIAL_NETWORK_STATE.services);
  expect(snapshot.port).toBe(box.mixedPort);
});

test("proxy status / proxy system:接管之后两处都如实反映「a2 正接管着」", async () => {
  const box = await managedBox();
  await proxy(box, ["on"]);

  const status = out(await proxy(box, ["status"]));
  expect(status.systemProxy.supported).toBe(true);
  expect(status.systemProxy.takenOver).toBe(true);
  expect(status.systemProxy.port).toBe(box.mixedPort);

  const system = out(await proxy(box, ["system"]));
  expect(SystemProxyStatusResultSchema.safeParse(system).success).toBe(true);
  expect(system.takenOver).toBe(true);
  expect(system.snapshotPath).toBe(box.snapshotPath);
  expect(system.services.map((s: { service: string }) => s.service)).toEqual(["Wi-Fi", "Ethernet"]);
  expect(system.services[1].http).toEqual(takenOver(box.mixedPort));
});

// MARK: - 还原(「退出即还原」废除后的唯一入口)

test("proxy off:终态**逐字段等于接管前**——第三方代理精确复原,原本关的仍是关的", async () => {
  const box = await managedBox();
  await proxy(box, ["on"]);

  const result = await proxy(box, ["off"]);

  expect(result.exitCode).toBe(0);
  const restored = out(result);
  expect(restored.enabled).toBe(false);
  expect(restored.restored).toBe(true);
  // 判据是**整棵状态相等**(逐服务 × 逐类型 × 逐字段),不是 grep 子串。
  expect(await networkState(box)).toEqual(INITIAL_NETWORK_STATE);
  // 还原完就把快照清掉:接管关系到此为止。
  expect(existsSync(box.snapshotPath)).toBe(false);
  expect(out(await proxy(box, ["status"])).systemProxy.takenOver).toBe(false);
});

test("proxy off:没接管过就是干净的 no-op(restored=false,退出码 0,系统一个字节都没被改)", async () => {
  const box = await managedBox();
  const callsBefore = (await networkCalls(box)).length;

  const first = await proxy(box, ["off"]);

  expect(first.exitCode).toBe(0);
  expect(out(first).restored).toBe(false);
  expect(await networkState(box)).toEqual(INITIAL_NETWORK_STATE);
  // 只读了实况,没发过任何 set/state 命令。
  const added = (await networkCalls(box)).slice(callsBefore);
  expect(added.every((line) => line.includes("-get") || line.includes("-listall"))).toBe(true);
});

test("重复接管不覆盖首次快照:二次 on 之后 off,仍还原到**最初**的第三方代理而不是内核端口", async () => {
  const box = await managedBox();

  await proxy(box, ["on"]);
  // 第二次接管时,系统上已经是"被接管态"了。若把它当成新快照存下来,
  // 那 off 就会把系统还原成"指向内核端口"——内核一没,用户永久断网。
  await proxy(box, ["on"]);

  const snapshot = JSON.parse(await readFile(box.snapshotPath, "utf8"));
  expect(snapshot.services).toEqual(INITIAL_NETWORK_STATE.services);

  await proxy(box, ["off"]);
  expect(await networkState(box)).toEqual(INITIAL_NETWORK_STATE);
});

test("接管之后新出现的网络服务:也被接管,off 时回到**它自己**接管前的状态", async () => {
  const box = await managedBox();
  await proxy(box, ["on"]);

  // 用户中途插了根网线 / 连了 iPhone USB:出现一个首次快照里没有的服务,
  // 而且它原本就有自己的第三方代理。
  const state = await networkState(box);
  state.services.push({
    service: "iPhone USB",
    http: { enabled: true, host: "198.51.100.5", port: 1080 },
    https: { enabled: false, host: "", port: 0 },
    socks: { enabled: false, host: "", port: 0 },
  });
  await writeFile(box.netStatePath, `${JSON.stringify(state, null, 2)}\n`);

  await proxy(box, ["on"]);
  const after = await networkState(box);
  expect(after.services[2]?.http).toEqual(takenOver(box.mixedPort));

  await proxy(box, ["off"]);
  const restored = await networkState(box);
  // 老服务回到最初的样子,新服务回到**它自己**被接管前的样子(不是被一律关掉)。
  expect(restored.services.slice(0, 2)).toEqual(INITIAL_NETWORK_STATE.services);
  expect(restored.services[2]).toEqual({
    service: "iPhone USB",
    http: { enabled: true, host: "198.51.100.5", port: 1080 },
    https: { enabled: false, host: "", port: 0 },
    socks: { enabled: false, host: "", port: 0 },
  });
});

// MARK: - 事务性(先能还原,才谈得上接管)

test("接管写到一半失败 → 回滚到本次调用前,退出码 5,且不留一个「接管了但还原不回去」的半态", async () => {
  // 第 5 次写调用失败(此时已经写进去几条了)——故障是**一次性**的,好让回滚自己的写能成功。
  const box = await managedBox({ A2_FAKE_NETSETUP_FAIL_AT: "5" });

  const result = await proxy(box, ["on"]);

  expect(result.exitCode).toBe(5);
  const parsed = body(result);
  expect(parsed.error.code).toBe("system_proxy_failed");
  // 回滚到位:系统代理逐字段回到本次调用前。
  expect(await networkState(box)).toEqual(INITIAL_NETWORK_STATE);
  // 首次接管失败 → 快照标记也清掉(不留一个指向"半接管"的假依据)。
  expect(existsSync(box.snapshotPath)).toBe(false);
}, 30000);

test("还原写到一半失败 → **快照留着**,再敲一次 off 仍能把系统精确还原(还原依据不丢)", async () => {
  // 接管要写 2 服务 × 3 类 × 2 条命令 = 12 次;把故障放在第 15 次,
  // 于是接管全成、而**还原**走到一半时挂掉(故障是一次性的,重试那轮不会再被打中)。
  const box = await managedBox({ A2_FAKE_NETSETUP_FAIL_AT: "15" });
  await proxy(box, ["on"]);
  const takenOver = await networkState(box);

  const failed = await proxy(box, ["off"]);

  expect(failed.exitCode).toBe(5);
  expect(body(failed).error.code).toBe("system_proxy_failed");
  // 还原没走完(状态既不是接管态、也还没回到接管前)——这正是最危险的时刻。
  const halfway = await networkState(box);
  expect(halfway).not.toEqual(INITIAL_NETWORK_STATE);
  // **唯一的还原依据必须还在**:把它跟着一起删掉,用户就再也回不去了。
  expect(existsSync(box.snapshotPath)).toBe(true);
  expect(out(await proxy(box, ["system"])).takenOver).toBe(true);

  // 再敲一次:这回写得进去,系统精确回到接管前(含那个第三方代理)。
  const retried = await proxy(box, ["off"]);
  expect(retried.exitCode).toBe(0);
  expect(out(retried).restored).toBe(true);
  expect(await networkState(box)).toEqual(INITIAL_NETWORK_STATE);
  expect(existsSync(box.snapshotPath)).toBe(false);
  expect(takenOver).not.toEqual(INITIAL_NETWORK_STATE);
}, 30000);

test("二次接管写到一半失败 → 只撤销**本次调用**:既有接管仍启用,首次快照原样留着", async () => {
  // 首次接管用掉 12 次写;第 15 次(二次接管的第 3 次写)挂掉。
  const box = await managedBox({ A2_FAKE_NETSETUP_FAIL_AT: "15" });
  await proxy(box, ["on"]);
  const takenOver = await networkState(box);

  const second = await proxy(box, ["on"]);

  expect(second.exitCode).toBe(5);
  expect(body(second).error.code).toBe("system_proxy_failed");
  // ① 只撤销本次调用:回到**本次调用开始时**的状态 —— 也就是"仍然被接管着",
  //    而不是被一路退回到接管前(那会在用户不知情时把代理关了)。
  expect(await networkState(box)).toEqual(takenOver);
  // ② 首次快照原样留着(不是被这次的"已接管态"覆盖,也不是被删掉)。
  expect(existsSync(box.snapshotPath)).toBe(true);
  const snapshot = JSON.parse(await readFile(box.snapshotPath, "utf8"));
  expect(snapshot.services).toEqual(INITIAL_NETWORK_STATE.services);
  // ③ 因此 off 仍然能把系统精确还原到最初 —— 这才是"只撤销本次"的意义所在。
  expect((await proxy(box, ["off"])).exitCode).toBe(0);
  expect(await networkState(box)).toEqual(INITIAL_NETWORK_STATE);
}, 30000);

test("内核报不出混合端口 → 拒绝接管且**零写入**(把系统代理指到不存在的端口 = 立刻断网)", async () => {
  const box = (sandbox = await makeProxySandbox({ groups: GROUPS }));
  await startProxyDaemon(box);
  const callsBefore = (await networkCalls(box)).length;

  // 压根没有 mihomo:端点解析就过不去。
  const result = await proxy(box, ["on"]);

  expect(result.exitCode).toBe(5);
  expect(body(result).error.code).toBe("mihomo_unreachable");
  expect(await networkState(box)).toEqual(INITIAL_NETWORK_STATE);
  expect(existsSync(box.snapshotPath)).toBe(false);
  // 一条 networksetup 都没发过(连读都没有 —— 端点不成立就该在最前面停手)。
  expect((await networkCalls(box)).length).toBe(callsBefore);
});

// MARK: - 「退出即还原」确实废除了

test("内核 daemon 被杀:系统代理与快照纹丝不动;新 daemon 起来后照样能显式还原", async () => {
  const box = await managedBox();
  await proxy(box, ["on"]);
  const takenOverState = await networkState(box);

  // 杀掉内核(等价于崩溃):**不还原**——还原是显式命令,不挂任何进程的生命周期。
  await stopDaemon(box.daemon!);
  box.daemon = undefined;

  expect(await networkState(box)).toEqual(takenOverState);
  expect(existsSync(box.snapshotPath)).toBe(true);

  // 内核回来之后,那份落在磁盘上的快照仍然是有效的还原依据。
  await startProxyDaemon(box);
  expect((await proxy(box, ["off"])).exitCode).toBe(0);
  expect(await networkState(box)).toEqual(INITIAL_NETWORK_STATE);
}, 30000);

// MARK: - 两种写法 + 红线

test("域子命令 ≡ 能力调用:a2 proxy off 与 capabilities call proxy.system.disable 结果完全相同", async () => {
  const box = await managedBox();

  const viaDomain = body(await proxy(box, ["off"]));
  const viaCall = body(await call(box, "proxy.system.disable"));

  expect(viaDomain.result).toEqual(viaCall.result);
  expect(viaDomain.result.capability).toBe("proxy.system.disable");
});

test("红线:整场对 networksetup 说过的话,只有内核认得的那几条子命令、只针对沙盒里的服务", async () => {
  const box = await managedBox();
  await proxy(box, ["on"]);
  await proxy(box, ["system"]);
  await proxy(box, ["off"]);

  const calls = await networkCalls(box);
  expect(calls.length).toBeGreaterThan(0);
  const allowed = [
    "-listallnetworkservices",
    "-getwebproxy",
    "-getsecurewebproxy",
    "-getsocksfirewallproxy",
    "-setwebproxy",
    "-setsecurewebproxy",
    "-setsocksfirewallproxy",
    "-setwebproxystate",
    "-setsecurewebproxystate",
    "-setsocksfirewallproxystate",
  ];
  for (const line of calls) {
    const argv = line.split(" ");
    expect(argv[0] as string).toBe("networksetup");
    expect(allowed).toContain(argv[1] as string);
    // 除了 -listallnetworkservices 之外,每条都带一个服务名,且只可能是沙盒里那两个。
    if (argv[1] !== "-listallnetworkservices") {
      expect(["Wi-Fi", "Ethernet"]).toContain(argv[2] as string);
    }
  }
});
