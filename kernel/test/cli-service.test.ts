// CLI 缝(最高缝):`a2 service install|uninstall|status` 的行为契约。
//
// **怎么在不碰真 launchctl 的前提下测完整编排**:把一份假 supervisor 放进 PATH,
// 而被测进程的 PATH **只有**那一个目录 —— 真 launchctl/systemctl 在它眼里根本不存在(见
// `support/fake-supervisor/`)。假件不是打桩:它照 unit 文件**真的把内核起起来**,所以这里跑的是
// 端到端的链条(install → 真 daemon → `a2 status` 连得上),断言的全是外部可观察面:
// 文件系统上的 unit 内容、发给 supervisor 的命令原文、stdout 的 JSON、退出码、进程与 socket 的死活。
//
// 假件**有意不模拟**的两件事:KeepAlive/Restart 自愈与节流 —— 那是真 supervisor 的语义,
// 归 `scripts/service-live-smoke.sh` 的活体冒烟(真 launchctl,票面「macOS 路径本机实测」)。
//
// Linux 那半边同样在这条缝上跑(`A2_SERVICE_SUPERVISOR=systemd` + 假 systemctl):unit 内容、路径、
// 命令编排与幂等全有断言;**实机验收顺延**(spec「Linux 口径」)。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  ServiceChangeResultSchema,
  ServiceStatusResultSchema,
} from "../src/contract/wire.ts";
import { parseJsonStdout, runCli, socketPathFor } from "./support/harness.ts";

const FAKE_DIR = path.resolve(import.meta.dir, "support/fake-supervisor");
const LABEL = "com.a2.kernel";

type SupervisorKind = "launchd" | "systemd";

interface Sandbox {
  /** A2_HOME。 */
  home: string;
  /** 沙盒根(同时充当假 HOME —— launchd 的 unit 落在它下面的 Library/LaunchAgents)。 */
  root: string;
  /** unit 文件**应该**落的位置(测试独立算出来的,不是问被测代码要的)。 */
  unitPath: string;
  logPath: string;
  statePath: string;
  env: Record<string, string>;
}

let sandbox: Sandbox | undefined;

async function makeSandbox(kind: SupervisorKind): Promise<Sandbox> {
  const root = await mkdtemp("/tmp/a2svc-");
  const home = path.join(root, "a2home");
  // XDG_CONFIG_HOME 有意指到一个**不等于** `$HOME/.config` 的地方:这样"systemd 单元按 XDG 落位"
  // 才是一条能证伪的断言,而不是两条路径碰巧相等。
  const xdgConfigHome = path.join(root, "xdg");
  const unitPath =
    kind === "launchd"
      ? path.join(root, "Library", "LaunchAgents", `${LABEL}.plist`)
      : path.join(xdgConfigHome, "systemd", "user", `${LABEL}.service`);
  const statePath = path.join(root, "supervisor-state");
  const logPath = path.join(root, "supervisor-calls.log");
  await writeFile(logPath, "");

  return {
    home,
    root,
    unitPath,
    statePath,
    logPath,
    env: {
      // 被测进程的 PATH 只有假件目录 —— 真 launchctl 在它眼里不存在(红线:本票之外不碰任何 unit)。
      PATH: FAKE_DIR,
      HOME: root,
      XDG_CONFIG_HOME: xdgConfigHome,
      A2_SERVICE_SUPERVISOR: kind,
      A2_FAKE_STATE: statePath,
      A2_FAKE_LOG: logPath,
      A2_FAKE_UNIT: unitPath,
    },
  };
}

async function service(box: Sandbox, args: string[]) {
  return await runCli(["service", ...args, "--json"], { home: box.home, env: box.env });
}

/** 假 supervisor 收到过的命令原文(一行一条)。 */
async function supervisorCalls(box: Sandbox): Promise<string[]> {
  const text = await readFile(box.logPath, "utf8");
  return text.split("\n").filter((line) => line.length > 0);
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitFor(what: string, check: () => boolean, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (check()) return;
    await Bun.sleep(25);
  }
  throw new Error(`等「${what}」超时(${timeoutMs}ms)`);
}

beforeEach(() => {
  sandbox = undefined;
});

// 假件起的是**真进程**,所以收尸纪律照 harness 那套:先杀干净,再删沙盒,绝不留孤儿。
afterEach(async () => {
  if (!sandbox) return;
  const raw = await readFile(sandbox.statePath, "utf8").catch(() => "");
  const pid = Number.parseInt(raw.trim().split(" ").pop() ?? "", 10);
  if (Number.isFinite(pid) && pid > 0 && isAlive(pid)) {
    try {
      process.kill(pid, "SIGTERM");
    } catch {
      /* 已经没了就算了 */
    }
  }
  await rm(sandbox.root, { recursive: true, force: true });
  sandbox = undefined;
});

// MARK: - macOS / launchd

test("service status:未安装时是三态之一、退出码 0,并给出 install 会写的 unit 路径", async () => {
  const box = (sandbox = await makeSandbox("launchd"));

  const result = await service(box, ["status"]);

  // 三态都是"查询成功"——「没装」是一个合法答案,不是查询失败。
  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(true);
  expect(ServiceStatusResultSchema.safeParse(body.result).success).toBe(true);
  expect(body.result.state).toBe("not_installed");
  expect(body.result.supervisor).toBe("launchd");
  expect(body.result.label).toBe(LABEL);
  expect(body.result.unitPath).toBe(box.unitPath);
  expect(body.result.unitInstalled).toBe(false);
  expect(body.result.registered).toBe(false);
  expect(body.result.pid).toBeUndefined();
  expect(body.result.home).toBe(box.home);
  expect(body.result.socketPath).toBe(socketPathFor(box.home));
  // 只读:查一次不会凭空造出 unit 文件。
  expect(existsSync(box.unitPath)).toBe(false);
});

test("service install(launchd):plist 落位、自愈自启键齐全、A2_HOME 注入,收敛到 running", async () => {
  const box = (sandbox = await makeSandbox("launchd"));

  const result = await service(box, ["install"]);

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(true);
  expect(ServiceChangeResultSchema.safeParse(body.result).success).toBe(true);
  expect(body.result.actions).toEqual(["unit_written", "supervisor_loaded"]);
  expect(body.result.status.state).toBe("running");
  expect(body.result.status.unitInstalled).toBe(true);
  expect(body.result.status.registered).toBe(true);
  // 报的是真进程,不是一个好看的数字。
  expect(isAlive(body.result.status.pid)).toBe(true);

  const plist = await readFile(box.unitPath, "utf8");
  expect(plist).toContain("<key>Label</key>");
  expect(plist).toContain(`<string>${LABEL}</string>`);
  // 自愈与自启:崩溃由 launchd 重拉(KeepAlive.Crashed),装载即起(RunAtLoad)。应用层不造看门狗。
  expect(plist).toContain("<key>KeepAlive</key>");
  expect(plist).toMatch(/<key>KeepAlive<\/key>\s*<dict>\s*<key>Crashed<\/key>\s*<true\/>/);
  expect(plist).toMatch(/<key>RunAtLoad<\/key>\s*<true\/>/);
  // supervisor 不读 shell 配置:A2_HOME 必须写进 unit,否则托管实例会去管 ~/.a2。
  expect(plist).toMatch(
    new RegExp(`<key>A2_HOME</key>\\s*<string>${box.home}</string>`),
  );
  expect(plist).toContain(`<string>${path.join(box.home, "log", "kernel.out.log")}</string>`);
  expect(plist).toContain(`<string>${path.join(box.home, "log", "kernel.err.log")}</string>`);
  // 日志目录必须先于 job 存在(launchd 不会替你建,建不出来 job 就起不来)。
  expect(existsSync(path.join(box.home, "log"))).toBe(true);

  // ProgramArguments 跑的就是"这个被测 a2 的 daemon run",可执行体是磁盘上真存在的文件
  // (源码跑时是 bun + 入口脚本,编译产物跑时就是产物本身 —— 两种被测体都成立)。
  const argumentsBlock =
    /<key>ProgramArguments<\/key>\s*<array>([\s\S]*?)<\/array>/.exec(plist)?.[1] ?? "";
  const programArguments = [...argumentsBlock.matchAll(/<string>([^<]*)<\/string>/g)].map(
    (match) => match[1] as string,
  );
  expect(programArguments.slice(-2)).toEqual(["daemon", "run"]);
  expect(existsSync(programArguments[0] as string)).toBe(true);

  // plist 得是**真的合法** plist —— 用 Apple 自己的解析器判,不用我的正则自证。
  if (existsSync("/usr/bin/plutil")) {
    const lint = Bun.spawnSync({ cmd: ["/usr/bin/plutil", "-lint", box.unitPath] });
    expect(lint.exitCode).toBe(0);
  }

  // 发给 supervisor 的是 bootstrap,域是 gui/<uid>,plist 是我们刚写的那个。
  const calls = await supervisorCalls(box);
  expect(calls.some((call) => call === `launchctl bootstrap gui/${process.getuid?.()} ${box.unitPath}`)).toBe(true);

  // **装完就是能用的**:紧接着的一条 status 必须走通,且答话的就是 supervisor 报的那个进程。
  // (这条曾经真的红过 —— 活体冒烟抓到:supervisor 一 exec 就报 pid,而 socket 还要几百毫秒才 bind,
  //  install 必须替调用方等完这一段,见 manager.ts 的 DAEMON_READY_TIMEOUT_MS。)
  const status = await runCli(["status", "--json"], { home: box.home, env: box.env });
  expect(status.exitCode).toBe(0);
  expect(parseJsonStdout(status).result.pid).toBe(body.result.status.pid);
  expect(existsSync(socketPathFor(box.home))).toBe(true);
});

test("service install 幂等:已收敛时第二次什么都不改(actions 为空),状态仍是 running", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await service(box, ["install"]);
  const callsAfterFirst = (await supervisorCalls(box)).length;

  const second = await service(box, ["install"]);

  expect(second.exitCode).toBe(0);
  const body = parseJsonStdout(second);
  expect(body.result.actions).toEqual([]);
  expect(body.result.status.state).toBe("running");
  // 幂等不只是"结果一样":不该再发任何**改状态**的命令(只多了只读的 print)。
  const added = (await supervisorCalls(box)).slice(callsAfterFirst);
  expect(added.every((call) => call.startsWith("launchctl print "))).toBe(true);
});

test("service install:unit 内容漂了就收敛回去(重写 + 先 bootout 再 bootstrap)", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await service(box, ["install"]);
  const expected = await readFile(box.unitPath, "utf8");
  await writeFile(box.unitPath, `${expected}\n<!-- 有人手改过 -->\n`);
  const callsBefore = (await supervisorCalls(box)).length;

  const result = await service(box, ["install"]);

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  // 已装载的 job 不会自己发现 plist 变了,必须卸下再装回来。
  expect(body.result.actions).toEqual(["unit_written", "supervisor_unloaded", "supervisor_loaded"]);
  expect(await readFile(box.unitPath, "utf8")).toBe(expected);
  const added = (await supervisorCalls(box)).slice(callsBefore);
  expect(added.some((call) => call.startsWith("launchctl bootout "))).toBe(true);
  expect(added.some((call) => call.startsWith("launchctl bootstrap "))).toBe(true);
});

test("service status / install:装了但没跑 → 三态之二,且 install 会把它显式拉起来", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  const installed = parseJsonStdout(await service(box, ["install"]));
  const deadPid = installed.result.status.pid;

  // 模拟"内核没了而 supervisor 没重拉"(KeepAlive.Crashed 归真 launchd,假件不模拟自愈)。
  process.kill(deadPid, "SIGKILL");
  await waitFor("内核进程退出", () => !isAlive(deadPid));

  const status = parseJsonStdout(await service(box, ["status"]));
  expect(status.result.state).toBe("installed_not_running");
  expect(status.result.registered).toBe(true);
  expect(status.result.unitInstalled).toBe(true);
  expect(status.result.pid).toBeUndefined();

  const reinstall = await service(box, ["install"]);
  expect(reinstall.exitCode).toBe(0);
  const body = parseJsonStdout(reinstall);
  // unit 没变、也已登记 —— 唯一该做的就是拉起来。
  expect(body.result.actions).toEqual(["kernel_started"]);
  expect(body.result.status.state).toBe("running");
  expect(body.result.status.pid).not.toBe(deadPid);
  expect((await supervisorCalls(box)).some((call) => call.startsWith("launchctl kickstart "))).toBe(true);
  // 上一个实例是被 SIGKILL 掉的,socket 文件还躺在那儿 —— 新实例得能识别并清掉这具残骸。
  const revived = await runCli(["status", "--json"], { home: box.home, env: box.env });
  expect(revived.exitCode).toBe(0);
});

test("service uninstall(launchd):bootout + 删 plist,状态回到未安装;再跑一次幂等", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  const installed = parseJsonStdout(await service(box, ["install"]));
  const pid = installed.result.status.pid;

  const first = await service(box, ["uninstall"]);

  expect(first.exitCode).toBe(0);
  const body = parseJsonStdout(first);
  expect(ServiceChangeResultSchema.safeParse(body.result).success).toBe(true);
  expect(body.result.actions).toEqual(["supervisor_unloaded", "unit_removed"]);
  expect(body.result.status.state).toBe("not_installed");
  expect(body.result.status.registered).toBe(false);
  expect(body.result.status.unitInstalled).toBe(false);
  expect(existsSync(box.unitPath)).toBe(false);
  // 「干净移除」不只是删文件:进程真的没了,socket 也被内核自己收摊掉了。
  await waitFor("内核进程退出", () => !isAlive(pid));
  expect(existsSync(socketPathFor(box.home))).toBe(false);

  const second = await service(box, ["uninstall"]);
  expect(second.exitCode).toBe(0);
  const again = parseJsonStdout(second);
  expect(again.result.actions).toEqual([]);
  expect(again.result.status.state).toBe("not_installed");
});

test("红线:整场只对 com.a2.kernel / gui/<uid> 说过话,没碰过任何别的 unit", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await service(box, ["status"]);
  await service(box, ["install"]);
  await service(box, ["install"]);
  await service(box, ["uninstall"]);

  const calls = await supervisorCalls(box);
  expect(calls.length).toBeGreaterThan(0);
  const domain = `gui/${process.getuid?.()}`;
  for (const call of calls) {
    expect(call.startsWith("launchctl ")).toBe(true);
    // 每一条命令的目标要么是 gui/<uid>/com.a2.kernel,要么是 bootstrap 的 (域 + 我们自己的 plist)。
    const targetsOurService = call.includes(`${domain}/${LABEL}`);
    const targetsOurBootstrap = call === `launchctl bootstrap ${domain} ${box.unitPath}`;
    expect(targetsOurService || targetsOurBootstrap).toBe(true);
  }
});

// MARK: - Linux / systemd(代码路径 + 编排 + 幂等有断言;实机验收顺延)

test("service install(systemd):unit 落 XDG 位置、Restart=on-failure,daemon-reload → enable → start", async () => {
  const box = (sandbox = await makeSandbox("systemd"));

  const result = await service(box, ["install"]);

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.result.status.supervisor).toBe("systemd");
  expect(body.result.status.unitPath).toBe(box.unitPath);
  expect(body.result.status.state).toBe("running");
  expect(isAlive(body.result.status.pid)).toBe(true);
  // systemd 的 enable 不含拉起,所以四步齐全(launchd 只要两步)。
  expect(body.result.actions).toEqual([
    "unit_written",
    "supervisor_reloaded",
    "supervisor_loaded",
    "kernel_started",
  ]);

  const unit = await readFile(box.unitPath, "utf8");
  expect(unit).toContain("[Unit]");
  expect(unit).toContain("Type=simple");
  // 自愈的对位物:非零退出/信号致死重拉,干净退出不重拉。
  expect(unit).toContain("Restart=on-failure");
  expect(unit).toContain("RestartSec=10");
  // 自启:用户登录后由 default.target 拉起。
  expect(unit).toContain("WantedBy=default.target");
  expect(unit).toContain(`Environment=A2_HOME=${box.home}`);
  expect(unit).toMatch(/^ExecStart=.+ daemon run$/m);

  const calls = await supervisorCalls(box);
  expect(calls).toContain("systemctl --user daemon-reload");
  expect(calls).toContain(`systemctl --user enable ${LABEL}.service`);
  expect(calls).toContain(`systemctl --user start ${LABEL}.service`);
  for (const call of calls) {
    expect(call.startsWith("systemctl --user ")).toBe(true);
    // 除了无参的 daemon-reload,每条命令的目标都必须是我们自己那个 unit。
    expect(call === "systemctl --user daemon-reload" || call.includes(`${LABEL}.service`)).toBe(true);
  }
});

test("service install/uninstall(systemd):幂等复跑不改动,卸载后回到未安装", async () => {
  const box = (sandbox = await makeSandbox("systemd"));
  await service(box, ["install"]);

  const second = parseJsonStdout(await service(box, ["install"]));
  expect(second.result.actions).toEqual([]);
  expect(second.result.status.state).toBe("running");

  const removed = parseJsonStdout(await service(box, ["uninstall"]));
  expect(removed.result.actions).toEqual([
    "supervisor_unloaded",
    "unit_removed",
    "supervisor_reloaded",
  ]);
  expect(removed.result.status.state).toBe("not_installed");
  expect(existsSync(box.unitPath)).toBe(false);

  const again = parseJsonStdout(await service(box, ["uninstall"]));
  expect(again.result.actions).toEqual([]);
  expect(again.result.status.state).toBe("not_installed");
});

// MARK: - 用法面与不支持的平台

test("service 用法错:缺动作 / 未知动作 / 多余参数一律退出码 1 + 指向服务面自己的帮助", async () => {
  const box = (sandbox = await makeSandbox("launchd"));

  for (const args of [[] as string[], ["restart"], ["status", "com.other.service"]]) {
    const result = await runCli(["service", ...args, "--json"], { home: box.home, env: box.env });

    expect(result.exitCode).toBe(1);
    const body = parseJsonStdout(result);
    expect(body.ok).toBe(false);
    expect(body.error.code).toBe("usage");
    const commands = body.error.guidance.steps.map((step: { command?: string }) => step.command);
    expect(commands).toContain("a2 service --help");
  }
  // 用法错不该碰 supervisor 一下。
  expect(await supervisorCalls(box)).toEqual([]);
});

test("service --help --json:帮助进 result,且写明三态与「内核只碰 com.a2.kernel」", async () => {
  const box = (sandbox = await makeSandbox("launchd"));

  const result = await service(box, ["--help"]);

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(true);
  expect(body.result.usage).toContain("a2 [--json] service install");
  expect(body.result.usage).toContain("not_installed");
  expect(body.result.usage).toContain(LABEL);
});

test("本平台没有已支持的 supervisor:结构化拒绝 + 退出码 6,指引给出前台常驻的精确命令", async () => {
  const box = (sandbox = await makeSandbox("launchd"));

  const result = await runCli(["service", "install", "--json"], {
    home: box.home,
    env: { ...box.env, A2_SERVICE_SUPERVISOR: "runit" },
  });

  expect(result.exitCode).toBe(6);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(false);
  expect(body.error.code).toBe("service_unsupported_platform");
  const commands = body.error.guidance.steps.map((step: { command?: string }) => step.command);
  expect(commands).toContain("a2 daemon run");
  // 路都走不通,当然不该留下任何 unit 文件。
  expect(existsSync(box.unitPath)).toBe(false);
});

test("supervisor 命令失败:退出码 5 + 报文里带着那条能原样重跑的命令", async () => {
  const box = (sandbox = await makeSandbox("launchd"));

  // 注入 bootstrap 失败(macOS Sonoma 起已知的偶发 I/O 错,见研究文档 §1.6)。
  const result = await runCli(["service", "install", "--json"], {
    home: box.home,
    env: { ...box.env, A2_FAKE_FAIL: "bootstrap" },
  });

  expect(result.exitCode).toBe(5);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(false);
  expect(body.error.code).toBe("service_operation_failed");
  // 拒绝即指引:失败的那条命令原样进指引,人类可以自己敲一遍看完整输出。
  const commands = body.error.guidance.steps.map((step: { command?: string }) => step.command);
  expect(commands).toContain(`launchctl bootstrap gui/${process.getuid?.()} ${box.unitPath}`);
  expect(commands).toContain("a2 service install");
  expect(body.error.detail).toContain("Input/output error");
  // 失败留下的是"可重来的半成品":unit 文件已经写好了,重跑 install 会从那儿继续收敛(幂等)。
  expect(existsSync(box.unitPath)).toBe(true);
});
