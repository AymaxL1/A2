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
import { existsSync, lstatSync, readdirSync, statSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  ServiceChangeResultSchema,
  ServiceStatusResultSchema,
} from "../src/contract/wire.ts";
import { a2Command, parseJsonStdout, runCli, socketPathFor } from "./support/harness.ts";

const FAKE_DIR = path.resolve(import.meta.dir, "support/fake-supervisor");
const LABEL = "com.a2.kernel";
const CLI_ENTRY = path.resolve(import.meta.dir, "../src/cli/main.ts");

type SupervisorKind = "launchd" | "systemd";

interface Sandbox {
  /** A2_HOME。 */
  home: string;
  /** 沙盒根(同时充当假 HOME —— launchd 的 unit 落在它下面的 Library/LaunchAgents)。 */
  root: string;
  /** unit 文件**应该**落的位置(测试独立算出来的,不是问被测代码要的)。 */
  unitPath: string;
  /** `--copy-to-home` 的落点**应该**在哪(同样是测试自己拼的)。 */
  homeBinPath: string;
  /** 充当「可分发单文件」的替身(见 `writeSelfBin`);编译产物那一遍不用它。 */
  selfBinPath: string;
  logPath: string;
  stateDir: string;
  env: Record<string, string>;
}

let sandbox: Sandbox | undefined;

async function makeSandbox(kind: SupervisorKind): Promise<Sandbox> {
  const root = await mkdtemp("/tmp/a2svc-");
  // **必须是 `<假 HOME>/.a2`**(18 票):`--purge` 只对缺省 home 生效,而本沙盒把 `HOME` 指到 root ——
  // 于是这个临时目录**就是**这个被测进程眼里的缺省 home。写成别的名字,整批 purge 用例验的就是拒绝路径了。
  const home = path.join(root, ".a2");
  // XDG_CONFIG_HOME 有意指到一个**不等于** `$HOME/.config` 的地方:这样"systemd 单元按 XDG 落位"
  // 才是一条能证伪的断言,而不是两条路径碰巧相等。
  const xdgConfigHome = path.join(root, "xdg");
  const unitPath =
    kind === "launchd"
      ? path.join(root, "Library", "LaunchAgents", `${LABEL}.plist`)
      : path.join(xdgConfigHome, "systemd", "user", `${LABEL}.service`);
  const stateDir = path.join(root, "supervisor-state");
  const logPath = path.join(root, "supervisor-calls.log");
  await writeFile(logPath, "");

  return {
    home,
    root,
    unitPath,
    homeBinPath: path.join(home, "bin", "a2"),
    selfBinPath: path.join(root, "self-bin", "a2"),
    stateDir,
    logPath,
    env: {
      // 被测进程的 PATH 只有假件目录 —— 真 launchctl 在它眼里不存在(红线:本票之外不碰任何 unit)。
      PATH: FAKE_DIR,
      HOME: root,
      XDG_CONFIG_HOME: xdgConfigHome,
      A2_SERVICE_SUPERVISOR: kind,
      A2_FAKE_STATE_DIR: stateDir,
      A2_FAKE_LOG: logPath,
    },
  };
}

/**
 * 「可分发单文件」的替身:一个真能跑的 a2(壳脚本 exec 到源码入口)。
 *
 * 为什么需要它:`--copy-to-home` 拷的是 `bun build --compile` 出来的那份单文件,而日常这批测试跑的是
 * **源码入口**(`bun run src/cli/main.ts`)—— 那时根本没有"自身"可拷。用 `A2_SELF_BIN` 指一个等价的
 * 可执行,拷贝→落位→unit 指向拷贝→supervisor 真把它起起来这条链才能在源码态被**完整**驱动
 * (假件是照 unit 真 exec 的,所以拷过去的东西必须真能跑)。
 *
 * **编译产物那一遍(`A2_TEST_BIN`)有意不覆写**:那时被测体自己就是可分发单文件,拷的是它本人 ——
 * 于是同一批断言在两种被测体上验的是同一件事的两种真实形态。`version` 那条则专挑产物那一遍验。
 */
async function writeSelfBin(box: Sandbox, marker: string): Promise<void> {
  await mkdir(path.dirname(box.selfBinPath), { recursive: true });
  await writeFile(
    box.selfBinPath,
    `#!/bin/sh\n# ${marker}\nexec ${JSON.stringify(process.execPath)} run ${JSON.stringify(CLI_ENTRY)} "$@"\n`,
    { mode: 0o755 },
  );
}

/** 本次被测体的自拷贝来源:编译产物那一遍用它自己,源码那一遍用替身。 */
function selfBinEnv(box: Sandbox): Record<string, string> {
  return process.env.A2_TEST_BIN ? {} : { A2_SELF_BIN: box.selfBinPath };
}

/** 源码那一遍才有"开发态"可言(编译产物那一遍本来就有可分发的自身)。 */
const COMPILED = process.env.A2_TEST_BIN !== undefined;

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
  // 状态按 label 分开存,收尸也逐个来(06 票起同一个沙盒里可能有两个 unit)。
  const stateFiles = existsSync(sandbox.stateDir) ? readdirSync(sandbox.stateDir) : [];
  for (const name of stateFiles) {
    const raw = await readFile(path.join(sandbox.stateDir, name), "utf8").catch(() => "");
    const pid = Number.parseInt(raw.trim().split(" ").pop() ?? "", 10);
    if (Number.isFinite(pid) && pid > 0 && isAlive(pid)) {
      try {
        process.kill(pid, "SIGTERM");
      } catch {
        /* 已经没了就算了 */
      }
    }
  }
  // 兜底:假件起的是真进程,而测试中途失败时状态文件未必是最新的。
  // 沙盒根是本次独有的临时路径,按它精确回收 —— 不可能误伤任何别的进程(尤其是用户自己的 mihomo)。
  Bun.spawnSync({ cmd: ["/usr/bin/pkill", "-9", "-f", sandbox.root], stdout: "ignore", stderr: "ignore" });
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
  // unit 不在时 binPath 给的是**这次 install 会写的那个**(与 unitPath 同一口径)——
  // 不带旗标就是当前这个被测体自己。
  expect(body.result.binPath).toBe(a2Command()[0]);
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
  // 机读面的 binPath 与盘上那份 unit 逐字相等(它答的就是"托管的是哪个可执行")。
  expect(body.result.status.binPath).toBe(programArguments[0]);
  // 不带旗标时行为不变:unit 仍指向调用者自己,$A2_HOME 底下不会凭空多出一个 bin。
  expect(existsSync(path.join(box.home, "bin"))).toBe(false);

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

test("service install:unit 内容漂了就收敛回去(重写 + 先 bootout 再 bootstrap,进程也换掉)", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  const before = parseJsonStdout(await service(box, ["install"]));
  const oldPid = before.result.status.pid;
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
  // **收敛的是进程,不只是文件**:旧进程用的是旧内容,它必须被换掉。
  expect(body.result.status.state).toBe("running");
  expect(body.result.status.pid).not.toBe(oldPid);
  await waitFor("旧内核进程退出", () => !isAlive(oldPid));
});

test("service install(systemd):unit 漂了且服务在跑 → 重写 + daemon-reload + 重启(进程换成新内容)", async () => {
  const box = (sandbox = await makeSandbox("systemd"));
  const before = parseJsonStdout(await service(box, ["install"]));
  const oldPid = before.result.status.pid;
  const expected = await readFile(box.unitPath, "utf8");
  // systemd 的 daemon-reload 只让**磁盘上写的**变了;已经在跑的进程仍用旧 ExecStart/旧 A2_HOME。
  await writeFile(box.unitPath, `${expected}# 有人手改过\n`);
  const callsBefore = (await supervisorCalls(box)).length;

  const result = await service(box, ["install"]);

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.result.actions).toEqual(["unit_written", "supervisor_reloaded", "kernel_restarted"]);
  expect(await readFile(box.unitPath, "utf8")).toBe(expected);
  expect(body.result.status.state).toBe("running");
  expect(body.result.status.pid).not.toBe(oldPid);
  await waitFor("旧内核进程退出", () => !isAlive(oldPid));
  const added = (await supervisorCalls(box)).slice(callsBefore);
  expect(added).toContain("systemctl --user daemon-reload");
  expect(added).toContain(`systemctl --user restart ${LABEL}.service`);
  // 装完就是能用的:重启之后照样得能答话。
  const status = await runCli(["status", "--json"], { home: box.home, env: box.env });
  expect(status.exitCode).toBe(0);
  expect(parseJsonStdout(status).result.pid).toBe(body.result.status.pid);
});

test("service status / install:装了但没跑 → 三态之二,且 install 会把它显式拉起来", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  const installed = parseJsonStdout(await service(box, ["install"]));
  const deadPid = installed.result.status.pid;

  // 模拟"内核没了而 supervisor 没重拉"(KeepAlive.Crashed 归真 launchd,假件不模拟自愈)。
  process.kill(deadPid, "SIGKILL");
  await waitFor("内核进程退出", () => !isAlive(deadPid));

  const statusResult = await service(box, ["status"]);
  // 三态都是**查询成功**:"装了但没跑"同样是退出码 0(要非零判据请用 `a2 status`)。
  expect(statusResult.exitCode).toBe(0);
  const status = parseJsonStdout(statusResult);
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

// MARK: - 面板自足:--copy-to-home(15 票 / ADR 0012)

test("--copy-to-home 首装:bin 落 $A2_HOME/bin/a2(0755)、unit 指向拷贝、拷贝真能跑", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await writeSelfBin(box, "v1");

  const result = await runCli(["service", "install", "--copy-to-home", "--json"], {
    home: box.home,
    env: { ...box.env, ...selfBinEnv(box) },
  });

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(ServiceChangeResultSchema.safeParse(body.result).success).toBe(true);
  // 拷贝排在最前面 —— 先有可执行,再有指着它的 unit。
  expect(body.result.actions).toEqual(["bin_copied", "unit_written", "supervisor_loaded"]);
  expect(body.result.status.binPath).toBe(box.homeBinPath);
  expect(statSync(box.homeBinPath).mode & 0o777).toBe(0o755);
  expect(statSync(path.dirname(box.homeBinPath)).mode & 0o777).toBe(0o700);

  // unit 里写的**就是**那份拷贝(不是 .app 里、也不是调用者所在的那个位置)。
  const plist = await readFile(box.unitPath, "utf8");
  const argumentsBlock =
    /<key>ProgramArguments<\/key>\s*<array>([\s\S]*?)<\/array>/.exec(plist)?.[1] ?? "";
  const programArguments = [...argumentsBlock.matchAll(/<string>([^<]*)<\/string>/g)].map(
    (match) => match[1] as string,
  );
  expect(programArguments).toEqual([box.homeBinPath, "daemon", "run"]);

  // 拷过去的东西**真能跑**:自己报得出版本,且与被测体报的一模一样。
  const version = await runCli(["version"], { home: box.home, env: box.env });
  const copied = Bun.spawnSync({ cmd: [box.homeBinPath, "version"], env: { ...process.env } });
  expect(copied.exitCode).toBe(0);
  expect(copied.stdout.toString().trim()).toBe(version.stdout.trim());

  // 装完就是跑着的:supervisor 起的是那份拷贝,而它真的在 socket 上答话。
  expect(body.result.status.state).toBe("running");
  const status = await runCli(["status", "--json"], { home: box.home, env: box.env });
  expect(status.exitCode).toBe(0);
  expect(parseJsonStdout(status).result.pid).toBe(body.result.status.pid);
});

test("--copy-to-home 幂等:同一份 bin 复跑不报拷贝、不换 inode、不动进程", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await writeSelfBin(box, "v1");
  const env = { ...box.env, ...selfBinEnv(box) };
  const first = parseJsonStdout(
    await runCli(["service", "install", "--copy-to-home", "--json"], { home: box.home, env }),
  );
  const inode = statSync(box.homeBinPath).ino;
  const callsAfterFirst = (await supervisorCalls(box)).length;

  const second = await runCli(["service", "install", "--copy-to-home", "--json"], {
    home: box.home,
    env,
  });

  expect(second.exitCode).toBe(0);
  const body = parseJsonStdout(second);
  // 人类面的"本来就是这样"在机读面就是这个空数组。
  expect(body.result.actions).toEqual([]);
  expect(statSync(box.homeBinPath).ino).toBe(inode);
  expect(body.result.status.pid).toBe(first.result.status.pid);
  expect(body.result.status.binPath).toBe(box.homeBinPath);
  // 幂等不只是"结果一样":不该再发任何**改状态**的命令。
  const added = (await supervisorCalls(box)).slice(callsAfterFirst);
  expect(added.every((call) => call.startsWith("launchctl print "))).toBe(true);
});

test("--copy-to-home 升级:拷贝内容变了且服务在跑 → 重新拷 + 显式重启(unit 一个字没动)", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await writeSelfBin(box, "v1");
  // 这条恒用替身:要验的是"内容变了"这件事,而编译产物没法就地改出第二个版本。
  const env = { ...box.env, A2_SELF_BIN: box.selfBinPath };
  const before = parseJsonStdout(
    await runCli(["service", "install", "--copy-to-home", "--json"], { home: box.home, env }),
  );
  const oldPid = before.result.status.pid;
  const unitBefore = await readFile(box.unitPath, "utf8");

  await writeSelfBin(box, "v2");
  const result = await runCli(["service", "install", "--copy-to-home", "--json"], {
    home: box.home,
    env,
  });

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  // **换了文件不等于换了进程**:unit 内容一字未改,所以收敛逻辑什么都不会做 ——
  // 升级全靠这条显式重启,而它必须如实出现在 actions 里。
  expect(body.result.actions).toEqual(["bin_copied", "kernel_restarted"]);
  expect(await readFile(box.unitPath, "utf8")).toBe(unitBefore);
  expect(await readFile(box.homeBinPath, "utf8")).toContain("v2");
  expect(body.result.status.pid).not.toBe(oldPid);
  await waitFor("旧内核进程退出", () => !isAlive(oldPid));
  // launchd 上换进程走的是 kickstart -k(unit 没变,bootout/bootstrap 那条路根本不成立)。
  expect((await supervisorCalls(box)).some((call) => call.startsWith("launchctl kickstart -k "))).toBe(
    true,
  );
});

test("--copy-to-home 升级:收敛本身已经换过进程时不再多重启一次", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await writeSelfBin(box, "v1");
  const env = { ...box.env, A2_SELF_BIN: box.selfBinPath };
  const before = parseJsonStdout(
    await runCli(["service", "install", "--copy-to-home", "--json"], { home: box.home, env }),
  );

  // bin 与 unit **同时**变了:launchd 的 bootout + bootstrap 本来就把进程换成新拷贝了,
  // 这时再 kickstart -k 一次只是白杀一个刚起来的进程。
  await writeSelfBin(box, "v2");
  await writeFile(box.unitPath, `${await readFile(box.unitPath, "utf8")}\n<!-- 有人手改过 -->\n`);
  const body = parseJsonStdout(
    await runCli(["service", "install", "--copy-to-home", "--json"], { home: box.home, env }),
  );

  expect(body.result.actions).toEqual([
    "bin_copied",
    "unit_written",
    "supervisor_unloaded",
    "supervisor_loaded",
  ]);
  expect(body.result.status.state).toBe("running");
  expect(body.result.status.pid).not.toBe(before.result.status.pid);
});

test("--copy-to-home 升级:服务没跑就不重启(没有进程可换,只落新拷贝)", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await writeSelfBin(box, "v1");
  const env = { ...box.env, A2_SELF_BIN: box.selfBinPath };
  const before = parseJsonStdout(
    await runCli(["service", "install", "--copy-to-home", "--json"], { home: box.home, env }),
  );
  process.kill(before.result.status.pid, "SIGKILL");
  await waitFor("内核进程退出", () => !isAlive(before.result.status.pid));

  await writeSelfBin(box, "v2");
  const body = parseJsonStdout(
    await runCli(["service", "install", "--copy-to-home", "--json"], { home: box.home, env }),
  );

  // 拉起来的那次用的已经是新拷贝,再"重启"一次只是白杀一个刚起来的进程。
  expect(body.result.actions).toEqual(["bin_copied", "kernel_started"]);
  expect(body.result.status.state).toBe("running");
});

test("--copy-to-home(systemd):unit 的 ExecStart 指向拷贝,升级同样是显式重启", async () => {
  const box = (sandbox = await makeSandbox("systemd"));
  await writeSelfBin(box, "v1");
  const env = { ...box.env, A2_SELF_BIN: box.selfBinPath };
  const before = parseJsonStdout(
    await runCli(["service", "install", "--copy-to-home", "--json"], { home: box.home, env }),
  );
  expect(before.result.actions).toEqual([
    "bin_copied",
    "unit_written",
    "supervisor_reloaded",
    "supervisor_loaded",
    "kernel_started",
  ]);
  expect(await readFile(box.unitPath, "utf8")).toMatch(
    new RegExp(`^ExecStart=${box.homeBinPath} daemon run$`, "m"),
  );

  await writeSelfBin(box, "v2");
  const body = parseJsonStdout(
    await runCli(["service", "install", "--copy-to-home", "--json"], { home: box.home, env }),
  );

  expect(body.result.actions).toEqual(["bin_copied", "kernel_restarted"]);
  expect(body.result.status.binPath).toBe(box.homeBinPath);
  expect((await supervisorCalls(box))).toContain(`systemctl --user restart ${LABEL}.service`);
});

test("uninstall 只拆 unit:$A2_HOME/bin/a2 的拷贝留下,人类面明说这一口径", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await writeSelfBin(box, "v1");
  const env = { ...box.env, ...selfBinEnv(box) };
  await runCli(["service", "install", "--copy-to-home", "--json"], { home: box.home, env });

  const human = await runCli(["service", "uninstall"], { home: box.home, env: box.env });

  expect(human.exitCode).toBe(0);
  expect(existsSync(box.unitPath)).toBe(false);
  // 数据同侧的东西留给显式清理 —— 卸服务不顺手删它。
  expect(existsSync(box.homeBinPath)).toBe(true);
  expect(human.stdout).toContain("只拆 unit");
  expect(human.stdout).toContain("保留不删");
});

test("binPath 是**盘上那份 unit** 的事实,不是本次调用的计划", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await writeSelfBin(box, "v1");
  await runCli(["service", "install", "--copy-to-home", "--json"], {
    home: box.home,
    env: { ...box.env, ...selfBinEnv(box) },
  });

  // 这一次**不带旗标**:计划值是当前这个可执行,而盘上的 unit 指着拷贝 —— 必须答后者。
  // (面板从 .app 里跑一次 status 就是这个场景:答错了它会以为托管的是自己那份。)
  const status = parseJsonStdout(
    await runCli(["service", "status", "--json"], { home: box.home, env: box.env }),
  );
  expect(status.result.binPath).toBe(box.homeBinPath);
  expect(status.result.binPath).not.toBe(a2Command()[0]);
});

test.if(!COMPILED)("开发态用 --copy-to-home:结构化拒绝 + 退出码 6,什么都不落盘", async () => {
  const box = (sandbox = await makeSandbox("launchd"));

  // 不设 A2_SELF_BIN —— 源码态跑的 a2 的可执行是 bun 自己,没有可分发的"自身"可拷。
  const result = await runCli(["service", "install", "--copy-to-home", "--json"], {
    home: box.home,
    env: box.env,
  });

  expect(result.exitCode).toBe(6);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(false);
  expect(body.error.code).toBe("service_self_copy_unsupported");
  // 拒绝即指引:两条能走通的路各给一条精确命令。
  const commands = body.error.guidance.steps.map((step: { command?: string }) => step.command);
  expect(commands).toContain("bash kernel/scripts/build.sh");
  expect(commands).toContain("a2 service install --json");
  // `A2_SELF_BIN` 是**仅供测试与诊断**的覆写,不该出现在用户可见的指引里 ——
  // 写进去等于邀请人去用它。(它只在"它自己指错了"那条错误里露面,那时它才是原因。)
  expect(JSON.stringify(body.error)).not.toContain("A2_SELF_BIN");

  // **金标是这条错误的手写镜像**,两边必须对得上:静态文本逐字相等、context 的键集相等
  // (值不比 —— 金标里是 /Users/alice,这里是本次沙盒的真路径)。
  // 没有这一条的话,金标改了一个键也只是"仍然合 schema",双端谁都不会吵。
  const golden = await Bun.file(
    path.resolve(import.meta.dir, "../contract/golden/response-service-self-copy-unsupported.json"),
  ).json();
  expect(body.error.code).toBe(golden.error.code);
  expect(body.error.message).toBe(golden.error.message);
  expect(body.error.detail).toBe(golden.error.detail);
  expect(body.error.guidance.summary).toBe(golden.error.guidance.summary);
  expect(commands).toEqual(
    golden.error.guidance.steps.map((step: { command?: string }) => step.command),
  );
  expect(Object.keys(body.error.guidance.context).sort()).toEqual(
    Object.keys(golden.error.guidance.context).sort(),
  );

  // 路不通就一个字节都不该落:没有 unit、没有 bin、也没跟 supervisor 说过话。
  expect(existsSync(box.unitPath)).toBe(false);
  expect(existsSync(path.dirname(box.homeBinPath))).toBe(false);
  expect(await supervisorCalls(box)).toEqual([]);
});

test("要拷的那份自身不在:结构化拒绝 + 退出码 6,指引对着那条覆写说话,什么都不落盘", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  const missing = path.join(box.root, "self-bin", "查无此文件");

  const result = await runCli(["service", "install", "--copy-to-home", "--json"], {
    home: box.home,
    env: { ...box.env, A2_SELF_BIN: missing },
  });

  // 「路走通了、事没办成」(5)与「这条请求根本不成立」(6)是两档 —— 这件事属后者:
  // 不做前置判断的话它会一路走到写文件才炸,落进 withPlan 的兜底,报成 5 且指引让人去看内核日志。
  expect(result.exitCode).toBe(6);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(false);
  expect(body.error.code).toBe("service_self_copy_unsupported");
  expect(body.error.message).toContain("A2_SELF_BIN");
  expect(body.error.detail).toContain(missing);
  const commands = body.error.guidance.steps.map((step: { command?: string }) => step.command);
  expect(commands).toContain(`ls -l ${missing}`);
  expect(existsSync(box.unitPath)).toBe(false);
  expect(existsSync(path.dirname(box.homeBinPath))).toBe(false);
  expect(await supervisorCalls(box)).toEqual([]);
});

test("--copy-to-home 只对 install 有意义:用在 status/uninstall 上是用法错", async () => {
  const box = (sandbox = await makeSandbox("launchd"));

  for (const action of ["status", "uninstall"]) {
    const result = await runCli(["service", action, "--copy-to-home", "--json"], {
      home: box.home,
      env: box.env,
    });

    expect(result.exitCode).toBe(1);
    const body = parseJsonStdout(result);
    expect(body.ok).toBe(false);
    expect(body.error.code).toBe("usage");
    expect(body.error.message).toContain("--copy-to-home");
  }
  expect(await supervisorCalls(box)).toEqual([]);
});

test("三条命令的机读面:stdout 恒是**一条**包封,没有散文混进来", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await writeSelfBin(box, "v1");
  const env = { ...box.env, ...selfBinEnv(box) };

  const runs = [
    await runCli(["service", "status", "--json"], { home: box.home, env }),
    await runCli(["service", "install", "--copy-to-home", "--json"], { home: box.home, env }),
    await runCli(["service", "uninstall", "--json"], { home: box.home, env }),
  ];

  for (const result of runs) {
    expect(result.exitCode).toBe(0);
    expect(result.stdout.trimEnd().split("\n")).toHaveLength(1);
    const body = parseJsonStdout(result);
    expect(body.ok).toBe(true);
    expect(body.v).toBe(1);
    expect(typeof body.id).toBe("string");
  }
});

// MARK: - 卸载补全:--purge(17 票 / ADR 0012 第 6 条修订)
//
// 这一组把「零残留」那条路走完整:拆内核 unit → 拆 a2 自管的 mihomo → 删整个 $A2_HOME。
// 红线的证明方式是**造一个用户自己的 mihomo 在场**(`io.metacubex.mihomo`:真 unit 文件 + 经假
// supervisor 真登记的真进程 + 一份配置),然后断言它整场毫发无伤 —— 而不是只断言"我们没打算碰它"。

const MIHOMO_LABEL = "com.a2.mihomo";
/** 用户自己装的那份(红线对象)。内核在任何路径下都不许碰它,连问一句都不该。 */
const FOREIGN_LABEL = "io.metacubex.mihomo";

/** 该 label 的 unit 该落在哪(测试自己拼,不问被测代码要)。 */
function unitPathFor(box: Sandbox, kind: SupervisorKind, label: string): string {
  return kind === "launchd"
    ? path.join(box.root, "Library", "LaunchAgents", `${label}.plist`)
    : path.join(box.env.XDG_CONFIG_HOME as string, "systemd", "user", `${label}.service`);
}

/**
 * a2 自管 mihomo 的 unit 里那条命令 —— 与 `mihomo/paths.ts` 的落点**逐字同形**(测试自己拼一遍,
 * 不问被测代码要)。17 票 CR 尾款起这不只是"好看":purge 前的 home 交叉核对拿 argv[0] 当指纹,
 * 装置若写成别的路径,验的就不是真实形态了。
 */
function managedMihomoArguments(home: string): string[] {
  const dataDir = path.join(home, "mihomo");
  return [path.join(dataDir, "bin", "mihomo"), "-d", dataDir, "-f", path.join(dataDir, "config.yaml")];
}

/**
 * 在沙盒里造一个「这个 unit 正装着而且跑着」的现场:写 unit 文件 + **经假 supervisor 真登记**
 * (于是它真起一个进程)。用测试自己写状态文件是不行的 —— 那样"内核有没有真的把它拆掉"就没法验。
 *
 * argv 可指定(缺省是一条 `<root>/<label>.sh` 的替身常驻脚本);argv[0] 那个文件由本函数现造,
 * 内容是 `while true; do sleep 1; done` —— 命令行里带着沙盒根,afterEach 的 pkill 兜得住。
 */
async function installLiveUnit(
  box: Sandbox,
  kind: SupervisorKind,
  label: string,
  programArguments: string[] = [path.join(box.root, `${label}.sh`)],
): Promise<{ unitPath: string; pid: number }> {
  const script = programArguments[0] as string;
  await mkdir(path.dirname(script), { recursive: true });
  await writeFile(script, `#!/bin/sh\n# ${label} 的替身常驻进程\nwhile true; do sleep 1; done\n`, {
    mode: 0o755,
  });
  const unitPath = unitPathFor(box, kind, label);
  await mkdir(path.dirname(unitPath), { recursive: true });

  if (kind === "launchd") {
    await writeFile(
      unitPath,
      [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<plist version="1.0">',
        "<dict>",
        "\t<key>Label</key>",
        `\t<string>${label}</string>`,
        "\t<key>ProgramArguments</key>",
        "\t<array>",
        ...programArguments.map((argument) => `\t\t<string>${argument}</string>`),
        "\t</array>",
        "\t<key>RunAtLoad</key>",
        "\t<true/>",
        "</dict>",
        "</plist>",
        "",
      ].join("\n"),
      { mode: 0o644 },
    );
    const boot = Bun.spawnSync({
      cmd: [path.join(FAKE_DIR, "launchctl"), "bootstrap", `gui/${process.getuid?.()}`, unitPath],
      env: { ...process.env, ...box.env },
    });
    expect(boot.exitCode).toBe(0);
    const pid = Number.parseInt(
      (await readFile(path.join(box.stateDir, `${label}.pid`), "utf8")).trim(),
      10,
    );
    return { unitPath, pid };
  }

  await writeFile(
    unitPath,
    [
      "[Unit]",
      `Description=${label} 替身`,
      "",
      "[Service]",
      `ExecStart=${programArguments.join(" ")}`,
      "",
    ].join("\n"),
    { mode: 0o644 },
  );
  const unitName = `${label}.service`;
  const systemctl = path.join(FAKE_DIR, "systemctl");
  const env = { ...process.env, ...box.env };
  expect(Bun.spawnSync({ cmd: [systemctl, "--user", "enable", unitName], env }).exitCode).toBe(0);
  expect(Bun.spawnSync({ cmd: [systemctl, "--user", "start", unitName], env }).exitCode).toBe(0);
  const state = (await readFile(path.join(box.stateDir, `${unitName}.state`), "utf8")).trim();
  return { unitPath, pid: Number.parseInt(state.split(" ")[1] as string, 10) };
}

/** 用户自己那份 mihomo 的**数据**(内核连读都不该读)。 */
async function writeForeignData(box: Sandbox): Promise<string> {
  const file = path.join(box.root, "metacubex", "config.yaml");
  await mkdir(path.dirname(file), { recursive: true });
  await writeFile(file, "mixed-port: 33888\nexternal-controller: 127.0.0.1:9090\n");
  return file;
}

/** 一份合法的接管快照(`a2 proxy on` 落的那份)。它在 = 现在系统代理由 a2 接管着。 */
async function writeTakeoverSnapshot(box: Sandbox): Promise<string> {
  const file = path.join(box.home, "system-proxy.json");
  await mkdir(box.home, { recursive: true });
  await writeFile(
    file,
    `${JSON.stringify(
      {
        takenOverAt: "2026-08-10T02:14:07.221Z",
        host: "127.0.0.1",
        port: 7897,
        services: [
          {
            service: "Wi-Fi",
            http: { enabled: false, host: "", port: 0 },
            https: { enabled: false, host: "", port: 0 },
            socks: { enabled: false, host: "", port: 0 },
          },
        ],
      },
      null,
      2,
    )}\n`,
  );
  return file;
}

test("uninstall --purge(launchd):拆两个 com.a2.* unit + 删整个 $A2_HOME,机读面给出先看后删的账", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await writeSelfBin(box, "v1");
  const env = { ...box.env, ...selfBinEnv(box) };
  const installed = parseJsonStdout(
    await runCli(["service", "install", "--copy-to-home", "--json"], { home: box.home, env }),
  );
  const kernelPid = installed.result.status.pid;
  const mihomo = await installLiveUnit(box, "launchd", MIHOMO_LABEL, managedMihomoArguments(box.home));

  const result = await runCli(["service", "uninstall", "--purge", "--json"], {
    home: box.home,
    env: box.env,
  });

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(ServiceChangeResultSchema.safeParse(body.result).success).toBe(true);
  // 顺序即安全性:先拆内核、再拆托管的 mihomo、最后才删数据。
  expect(body.result.actions).toEqual([
    "supervisor_unloaded",
    "unit_removed",
    "mihomo_unit_removed",
    "home_purged",
  ]);
  // 「先看后删」的对账面:具体到 label 与绝对路径,不用从 actions 反推。
  expect(body.result.purge).toEqual({
    removedUnits: [LABEL, MIHOMO_LABEL],
    removedPaths: [box.home],
  });

  // 盘上的事实:两个 unit 文件都没了、$A2_HOME 整棵树没了(那份内核拷贝随它一起)。
  expect(existsSync(box.unitPath)).toBe(false);
  expect(existsSync(mihomo.unitPath)).toBe(false);
  expect(existsSync(box.home)).toBe(false);
  expect(existsSync(box.homeBinPath)).toBe(false);
  // 「干净移除」是关于进程的承诺:两条命都真的没了。
  await waitFor("内核进程退出", () => !isAlive(kernelPid));
  await waitFor("a2 自管的 mihomo 退出", () => !isAlive(mihomo.pid));
});

test("红线:purge 整场不碰用户自己的 mihomo —— unit、配置、进程三样毫发无伤", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  const foreign = await installLiveUnit(box, "launchd", FOREIGN_LABEL);
  const foreignUnitBytes = await readFile(foreign.unitPath, "utf8");
  const foreignData = await writeForeignData(box);
  const foreignDataBytes = await readFile(foreignData, "utf8");
  await service(box, ["install"]);
  await installLiveUnit(box, "launchd", MIHOMO_LABEL, managedMihomoArguments(box.home));
  // 分界线:此后日志里的每一条都是**被测命令自己发的**(上面那几条是测试搭现场发的)。
  const callsBefore = (await supervisorCalls(box)).length;

  const body = parseJsonStdout(
    await runCli(["service", "uninstall", "--purge", "--json"], { home: box.home, env: box.env }),
  );

  // ① 清单里只可能有 com.a2.*(契约层还有一条 pattern 钉着,见 invalid-service-change-purge-foreign-unit)。
  for (const label of body.result.purge.removedUnits) {
    expect(label.startsWith("com.a2.")).toBe(true);
  }
  expect(body.result.purge.removedUnits).not.toContain(FOREIGN_LABEL);
  // ② 删掉的路径只可能是 $A2_HOME 这一条。
  expect(body.result.purge.removedPaths).toEqual([box.home]);
  // ③ 整条报文里没有"别人"的影子(错把它写进指引/detail 也算越界)。
  expect(JSON.stringify(body)).not.toContain("metacubex");
  // ④ purge 发给 supervisor 的每一条命令,目标都只能是我们自己那两个 label ——
  //    这一条比"清单里没有它"更硬:它证明内核连**问**都没问过别人的 unit。
  const purgeCalls = (await supervisorCalls(box)).slice(callsBefore);
  expect(purgeCalls.length).toBeGreaterThan(0);
  for (const call of purgeCalls) {
    expect(call).not.toContain("metacubex");
    expect(call.includes(LABEL) || call.includes(MIHOMO_LABEL)).toBe(true);
  }
  // ⑤ 盘上与进程表上的事实:他的 unit、他的配置、他的进程,一样没动。
  expect(await readFile(foreign.unitPath, "utf8")).toBe(foreignUnitBytes);
  expect(await readFile(foreignData, "utf8")).toBe(foreignDataBytes);
  expect(isAlive(foreign.pid)).toBe(true);
});

test("purge:a2 自管的 mihomo 不在就跳过 —— 不报 mihomo_unit_removed,清单里也没有它", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await service(box, ["install"]);

  const body = parseJsonStdout(
    await runCli(["service", "uninstall", "--purge", "--json"], { home: box.home, env: box.env }),
  );

  expect(body.result.actions).toEqual(["supervisor_unloaded", "unit_removed", "home_purged"]);
  expect(body.result.purge.removedUnits).toEqual([LABEL]);
  expect(existsSync(box.home)).toBe(false);
});

test("purge 幂等:全都不在时 actions 为空、账是两个空数组,退出码仍是 0", async () => {
  const box = (sandbox = await makeSandbox("launchd"));

  const result = await runCli(["service", "uninstall", "--purge", "--json"], {
    home: box.home,
    env: box.env,
  });

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.result.actions).toEqual([]);
  expect(body.result.purge).toEqual({ removedUnits: [], removedPaths: [] });
  expect(body.result.status.state).toBe("not_installed");
});

test("系统代理仍处接管态:purge 结构化拒绝 + 退出码 1,**一个字节都不删**,指引给两条还原路", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await writeSelfBin(box, "v1");
  const env = { ...box.env, ...selfBinEnv(box) };
  const installed = parseJsonStdout(
    await runCli(["service", "install", "--copy-to-home", "--json"], { home: box.home, env }),
  );
  const mihomo = await installLiveUnit(box, "launchd", MIHOMO_LABEL, managedMihomoArguments(box.home));
  const snapshot = await writeTakeoverSnapshot(box);
  const callsBefore = (await supervisorCalls(box)).length;

  const result = await runCli(["service", "uninstall", "--purge", "--json"], {
    home: box.home,
    env: box.env,
  });

  // 「这会儿不该发」与用法错同一档(1):还原一次之后,同一条命令就成立了。
  expect(result.exitCode).toBe(1);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(false);
  expect(body.error.code).toBe("service_purge_blocked");
  expect(body.error.detail).toContain(snapshot);
  // 拒绝即指引:CLI 与面板两条路各给一条,再给"这次就只拆服务"的退路。
  const commands = body.error.guidance.steps.map((step: { command?: string }) => step.command);
  expect(commands).toContain("a2 proxy off");
  expect(commands).toContain("a2 service uninstall");
  expect(
    body.error.guidance.steps.some((step: { description: string }) =>
      step.description.includes("关闭系统代理(还原)"),
    ),
  ).toBe(true);

  // **拒绝时零删除**:服务照跑、两个 unit 都在、home 与快照原样、连一条改状态的 supervisor 命令都没发。
  expect(existsSync(box.unitPath)).toBe(true);
  expect(existsSync(mihomo.unitPath)).toBe(true);
  expect(existsSync(box.home)).toBe(true);
  expect(existsSync(snapshot)).toBe(true);
  expect(existsSync(box.homeBinPath)).toBe(true);
  expect(isAlive(installed.result.status.pid)).toBe(true);
  expect(isAlive(mihomo.pid)).toBe(true);
  expect((await supervisorCalls(box)).slice(callsBefore)).toEqual([]);

  // 金标是这条拒绝的手写镜像:静态文本逐字相等、指引步骤同序、context 键集相等
  // (detail 与两个 context 值都含本次沙盒的真路径,只比键)。
  const golden = await Bun.file(
    path.resolve(import.meta.dir, "../contract/golden/response-service-purge-blocked.json"),
  ).json();
  expect(body.error.code).toBe(golden.error.code);
  expect(body.error.message).toBe(golden.error.message);
  expect(body.error.guidance.summary).toBe(golden.error.guidance.summary);
  expect(commands).toEqual(
    golden.error.guidance.steps.map((step: { command?: string }) => step.command),
  );
  expect(body.error.guidance.steps.map((step: { description: string }) => step.description)).toEqual(
    golden.error.guidance.steps.map((step: { description: string }) => step.description),
  );
  expect(Object.keys(body.error.guidance.context).sort()).toEqual(
    Object.keys(golden.error.guidance.context).sort(),
  );
});

/**
 * 18 票(用户裁定):**`--purge` 只对缺省 `~/.a2` 生效**。
 *
 * 17 票的护栏是**地板**(挡 `/`、家目录、`/Users` 那几种"绝不可能"的形状),挡不住
 * `A2_HOME=/Applications`、`=~/Documents` 这类**普通目录** —— 而模板展开出错最常见的落点正是它们。
 * 这一刀把那一整类从根上封死。判据本身(含各种等价写法)在单元缝上验:`service-purge-guard.test.ts`。
 */
test("自定义 A2_HOME:--purge 结构化拒绝 + 退出码 6,零删除,并给出自助清理那条路", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  // 这个 home 既不是根、也不是家目录、更不是符号链接 —— 17 票那道地板对它完全无感。
  const custom = path.join(box.root, "work", "a2-sandbox");
  await mkdir(path.join(custom, "plugins"), { recursive: true });
  await writeFile(path.join(custom, "settings.json"), '{"mixedPort":7897}\n');
  await runCli(["service", "install", "--json"], { home: custom, env: box.env });
  const callsBefore = (await supervisorCalls(box)).length;

  const result = await runCli(["service", "uninstall", "--purge", "--json"], {
    home: custom,
    env: box.env,
  });

  // 「这条请求在这个 $A2_HOME 上永远不成立」—— 与平台/形态那两条同族(6),不是"等会儿再来"(1)。
  expect(result.exitCode).toBe(6);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(false);
  expect(body.error.code).toBe("service_purge_unsafe_home");
  expect(body.error.guidance.context.reason).toBe("non_default_home");
  expect(body.error.guidance.context.home).toBe(custom);
  expect(body.error.guidance.context.defaultHome).toBe(path.join(box.root, ".a2"));
  // 指引指明当前 home、并给出自助清理的那条真命令(数据的处置权在人手里)。
  const commands = body.error.guidance.steps.map((step: { command?: string }) => step.command);
  expect(commands).toContain(`rm -rf ${custom}`);
  expect(commands).toContain("a2 service uninstall");

  // 零删除:数据、unit、服务全在,连一条改状态的 supervisor 命令都没发。
  expect(await readFile(path.join(custom, "settings.json"), "utf8")).toBe('{"mixedPort":7897}\n');
  expect(existsSync(path.join(custom, "plugins"))).toBe(true);
  expect(existsSync(box.unitPath)).toBe(true);
  expect((await supervisorCalls(box)).slice(callsBefore)).toEqual([]);

  // 金标是这条拒绝的手写镜像:静态文本逐字相等、步骤同序、context **键集**相等
  // (值不比 —— 金标里是 /Users/alice/work/a2-sandbox,这里是本次沙盒的真路径)。
  const golden = await Bun.file(
    path.resolve(import.meta.dir, "../contract/golden/response-service-purge-non-default-home.json"),
  ).json();
  expect(body.error.code).toBe(golden.error.code);
  expect(body.error.message).toBe(golden.error.message);
  expect(body.error.guidance.summary).toBe(golden.error.guidance.summary);
  expect(body.error.guidance.steps.map((step: { description: string }) => step.description)).toEqual(
    golden.error.guidance.steps.map((step: { description: string }) => step.description),
  );
  expect(Object.keys(body.error.guidance.context).sort()).toEqual(
    Object.keys(golden.error.guidance.context).sort(),
  );
});

test("缺省 home 照常放行,等价写法(尾随斜杠 / `.` 段)也放行 —— 比的是路径不是字符串", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await service(box, ["install"]);
  await writeFile(path.join(box.home, "settings.json"), "{}\n");

  // `<root>/./.a2/` —— 归一化之后与缺省 home 是同一个地方。
  const equivalent = `${path.join(box.root, ".", ".a2")}/`;
  const result = await runCli(["service", "uninstall", "--purge", "--json"], {
    home: equivalent,
    env: box.env,
  });

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.result.actions).toContain("home_purged");
  expect(body.result.purge.removedPaths).toEqual([box.home]);
  expect(existsSync(box.home)).toBe(false);
});

/**
 * 17 票 CR 尾款:`$A2_HOME` 是符号链接时的**假账**。
 *
 * `rm(home, { recursive: true, force: true })` 对符号链接只删链不删树,而 a2 的一切都是穿链写的 ——
 * 于是不拦的话,一次 purge 会报 `home_purged` + 零残留,而数据分毫未动。这是本轮 CR 实测抓到的。
 * (地板护栏的另外几档 —— `/`、家目录本身、家目录的祖先 —— 在**单元缝**上验:
 *  见 `service-purge-guard.test.ts`。那几个值绝不能拿到 CLI 缝上真跑一遍。)
 */
test("symlink 的 $A2_HOME:结构化拒绝 + 退出码 6,链还在、链目标那棵树一个字节没少", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  const real = path.join(box.root, "real-home");
  await mkdir(real, { recursive: true });
  await writeFile(path.join(real, "settings.json"), '{"mixedPort":7897}\n');
  // **缺省 home 自己**就是那根链(用户就是这么用的:把 ~/.a2 指到别的卷)——
  // 18 票之后这才是可达形态:随便找个路径当链是走不到这一档的,⓪0 会先把它挡掉。
  const linked = box.home;
  await symlink(real, linked);
  const env = { ...box.env, ...selfBinEnv(box) };
  await writeSelfBin(box, "v1");
  await runCli(["service", "install", "--copy-to-home", "--json"], { home: linked, env });

  const result = await runCli(["service", "uninstall", "--purge", "--json"], {
    home: linked,
    env: box.env,
  });

  // 「这条请求在这个 $A2_HOME 上根本不成立」—— 与 service_unsupported_platform 同档。
  expect(result.exitCode).toBe(6);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("service_purge_unsafe_home");
  expect(body.error.guidance.context.reason).toBe("symlink");
  expect(body.error.guidance.context.linkTarget).toBe(real);
  // 拒绝即指引:告诉他真实目标在哪、以及"只拆服务"那条不删数据的退路。
  const commands = body.error.guidance.steps.map((step: { command?: string }) => step.command);
  expect(commands).toContain(`readlink ${linked}`);
  expect(commands).toContain("a2 service uninstall");

  // 零删除:链在、链目标那棵树完好、unit 也没动。
  // (判"链还在"必须用 lstat —— `existsSync` 是穿链的,它答的是"目标在不在"。)
  expect(lstatSync(linked).isSymbolicLink()).toBe(true);
  expect(await readFile(path.join(real, "settings.json"), "utf8")).toBe('{"mixedPort":7897}\n');
  expect(existsSync(path.join(real, "bin", "a2"))).toBe(true);
  expect(existsSync(box.unitPath)).toBe(true);
});

test("dangling symlink 的 $A2_HOME 同样拒绝(链在、目标没了 —— 删它证明不了任何事)", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  const linked = box.home;   // 缺省 home 本身是一根悬空的链
  await symlink(path.join(box.root, "查无此目录"), linked);

  const result = await runCli(["service", "uninstall", "--purge", "--json"], {
    home: linked,
    env: box.env,
  });

  expect(result.exitCode).toBe(6);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("service_purge_unsafe_home");
  expect(body.error.guidance.context.reason).toBe("dangling_symlink");
  // 悬空链上 `existsSync` 恒 false(它穿链看目标),所以这里只能 lstat:**那根链本身**还在。
  expect(lstatSync(linked).isSymbolicLink()).toBe(true);
});

/**
 * 17 票 CR 尾款:**label 是每用户一个,而 home 是每次调用一个**。
 *
 * 在 `A2_HOME=/tmp/x` 下 purge,拆掉的却是为真 home 装的那两个 unit,而接管快照判据看的是
 * `/tmp/x` 那份 —— 真 home 的还原依据根本不会被看见。这道门必须真的关上。
 */
test("home 错位:盘上 unit 记的是别的 A2_HOME → 拒绝 + 退出码 1,两个 home 都一个字节没少", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  // 服务装在一个**自定义** home 上(装是不挑 home 的),然后拿**缺省** home 来 purge ——
  // 18 票之后这才是"站错 home"的可达形态:反过来(拿自定义 home 来 purge)会先被 ⓪0 挡住。
  const other = path.join(box.root, "另一个-home");
  await mkdir(box.home, { recursive: true });
  await runCli(["service", "install", "--json"], { home: other, env: box.env });
  await writeFile(path.join(other, "无关文件.json"), "{}\n");
  await writeFile(path.join(box.home, "settings.json"), '{"mixedPort":7897}\n');
  const callsBefore = (await supervisorCalls(box)).length;

  const result = await runCli(["service", "uninstall", "--purge", "--json"], {
    home: box.home,
    env: box.env,
  });

  // 「命令没错,是站错了地方」—— 与 daemon_already_running / service_purge_blocked 同档。
  expect(result.exitCode).toBe(1);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("service_purge_home_mismatch");
  expect(body.error.detail).toContain(other);
  expect(body.error.guidance.context.installedHome).toBe(other);
  const commands = body.error.guidance.steps.map((step: { command?: string }) => step.command);
  expect(commands).toContain(`A2_HOME=${other} a2 service uninstall --purge --json`);

  // 零删除:两个 home、unit、服务进程全在,连一条改状态的 supervisor 命令都没发。
  expect(existsSync(path.join(other, "无关文件.json"))).toBe(true);
  expect(await readFile(path.join(box.home, "settings.json"), "utf8")).toBe('{"mixedPort":7897}\n');
  expect(existsSync(box.unitPath)).toBe(true);
  expect((await supervisorCalls(box)).slice(callsBefore)).toEqual([]);
});

test("home 错位(内核 unit 不在、mihomo unit 是别的 home 装的):照样拒绝 —— 数据面才是要紧的那一个", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  const other = path.join(box.root, "另一个-home");
  await mkdir(box.home, { recursive: true });
  // 只有 mihomo 那份 unit,而且它服务的是**另一个** home(argv[0] 就是它的指纹)。
  const mihomo = await installLiveUnit(box, "launchd", MIHOMO_LABEL, managedMihomoArguments(other));

  const result = await runCli(["service", "uninstall", "--purge", "--json"], {
    home: box.home,
    env: box.env,
  });

  expect(result.exitCode).toBe(1);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("service_purge_home_mismatch");
  expect(body.error.guidance.context.label).toBe(MIHOMO_LABEL);
  expect(body.error.guidance.context.installedHome).toBe(other);
  // 零删除:那份 unit 与它的进程都还在(它可能正驮着别的 home 的系统代理)。
  expect(existsSync(mihomo.unitPath)).toBe(true);
  expect(isAlive(mihomo.pid)).toBe(true);
  expect(existsSync(box.home)).toBe(true);
});

test("home 一致就照常放行(核对的是**事实**,不是「有没有 unit」这种粗判据)", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await service(box, ["install"]);

  const body = parseJsonStdout(
    await runCli(["service", "uninstall", "--purge", "--json"], { home: box.home, env: box.env }),
  );

  expect(body.ok).toBe(true);
  expect(body.result.actions).toContain("home_purged");
  expect(existsSync(box.home)).toBe(false);
});

test("盘上没有 unit:跳过核对照常清(没有 unit 就没有被托管的数据面)", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await mkdir(path.join(box.home, "plugins"), { recursive: true });
  await writeFile(path.join(box.home, "settings.json"), "{}\n");

  const result = await runCli(["service", "uninstall", "--purge", "--json"], {
    home: box.home,
    env: box.env,
  });

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.result.actions).toEqual(["home_purged"]);
  expect(body.result.purge).toEqual({ removedUnits: [], removedPaths: [box.home] });
  expect(existsSync(box.home)).toBe(false);
});

test("unit 在但读不出它记的 A2_HOME(被人改坏了):fail-closed 拒绝,不猜", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await service(box, ["install"]);
  // 把 EnvironmentVariables 整块抹掉 —— 本内核写的 unit 必然带 A2_HOME,读不出就是"这不是我写的"。
  const plist = await readFile(box.unitPath, "utf8");
  await writeFile(
    box.unitPath,
    plist.replace(/<key>EnvironmentVariables<\/key>\s*<dict>[\s\S]*?<\/dict>/, ""),
  );

  const result = await runCli(["service", "uninstall", "--purge", "--json"], {
    home: box.home,
    env: box.env,
  });

  expect(result.exitCode).toBe(1);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("service_purge_home_mismatch");
  expect(body.error.message).toContain("读不出");
  expect(existsSync(box.home)).toBe(true);
  expect(existsSync(box.unitPath)).toBe(true);
});

/**
 * 17 票 CR 尾款:mihomo 拆不净(supervisor 说卸下了,进程还在)。
 * 与内核那条 `stillRunningError` 同一种姿势:**进程还在就绝不往下删数据**。
 */
test("a2 自管的 mihomo 拆不净:停在那一步,$A2_HOME 未删,已拆的 kernel unit 如实没了", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await service(box, ["install"]);
  await writeFile(path.join(box.home, "settings.json"), "{}\n");
  const mihomo = await installLiveUnit(box, "launchd", MIHOMO_LABEL, managedMihomoArguments(box.home));

  const result = await runCli(["service", "uninstall", "--purge", "--json"], {
    home: box.home,
    // 故障注入:bootout 报成功,但那个进程赖着不走。
    env: { ...box.env, A2_FAKE_BOOTOUT_KEEPS_PROCESS: MIHOMO_LABEL },
  });

  // 「路走通了、事没办成」= 5。
  expect(result.exitCode).toBe(5);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("service_operation_failed");
  expect(body.error.message).toContain("$A2_HOME 未删");
  expect(body.error.guidance.context.label).toBe(MIHOMO_LABEL);
  expect(body.error.guidance.context.pid).toBe(String(mihomo.pid));
  // 指引里点名"别停不属于 a2 的那份"——红线不因为出错就松。
  expect(JSON.stringify(body.error.guidance)).toContain("别停不属于 a2 的那份");

  // 停在那一步:数据没删,而**已经做过的事如实是做过了**(kernel unit 真的没了)。
  expect(existsSync(box.home)).toBe(true);
  expect(existsSync(path.join(box.home, "settings.json"))).toBe(true);
  expect(existsSync(box.unitPath)).toBe(false);
  expect(isAlive(mihomo.pid)).toBe(true);
});

test("接管快照坏了照样拒绝:判据是**它在不在**,不是它解不解得开", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await service(box, ["install"]);
  await mkdir(box.home, { recursive: true });
  await writeFile(path.join(box.home, "system-proxy.json"), "{ 这不是 JSON");

  const result = await runCli(["service", "uninstall", "--purge", "--json"], {
    home: box.home,
    env: box.env,
  });

  expect(result.exitCode).toBe(1);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("service_purge_blocked");
  // 一个解不开的还原依据仍然是还原依据 —— 删掉它同样不可逆。
  expect(body.error.detail).toContain("解不开");
  expect(existsSync(box.home)).toBe(true);
  expect(existsSync(box.unitPath)).toBe(true);
});

test("不带 --purge 的卸载一字未变:$A2_HOME 与那份拷贝都在,机读面里没有 purge 这个键", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await writeSelfBin(box, "v1");
  const env = { ...box.env, ...selfBinEnv(box) };
  await runCli(["service", "install", "--copy-to-home", "--json"], { home: box.home, env });
  await installLiveUnit(box, "launchd", MIHOMO_LABEL, managedMihomoArguments(box.home));

  const body = parseJsonStdout(await service(box, ["uninstall"]));

  expect(body.result.actions).toEqual(["supervisor_unloaded", "unit_removed"]);
  expect(body.result.purge).toBeUndefined();
  expect(existsSync(box.home)).toBe(true);
  expect(existsSync(box.homeBinPath)).toBe(true);
  // a2 自管的 mihomo 也不在普通卸载的射程内(「数据面不随控制面起落」)。
  expect(existsSync(unitPathFor(box, "launchd", MIHOMO_LABEL))).toBe(true);
});

test("uninstall --purge(systemd):unit 从 XDG 位置删掉,daemon-reload 走到,home 照样清干净", async () => {
  const box = (sandbox = await makeSandbox("systemd"));
  await service(box, ["install"]);
  const mihomo = await installLiveUnit(box, "systemd", MIHOMO_LABEL, managedMihomoArguments(box.home));

  const body = parseJsonStdout(
    await runCli(["service", "uninstall", "--purge", "--json"], { home: box.home, env: box.env }),
  );

  expect(body.result.actions).toEqual([
    "supervisor_unloaded",
    "unit_removed",
    "supervisor_reloaded",
    "mihomo_unit_removed",
    "home_purged",
  ]);
  expect(body.result.purge).toEqual({
    removedUnits: [LABEL, MIHOMO_LABEL],
    removedPaths: [box.home],
  });
  expect(existsSync(mihomo.unitPath)).toBe(false);
  expect(existsSync(box.home)).toBe(false);
  expect(await supervisorCalls(box)).toContain(`systemctl --user stop ${MIHOMO_LABEL}.service`);
  await waitFor("a2 自管的 mihomo 退出", () => !isAlive(mihomo.pid));
});

test("--purge 只对 uninstall 有意义:用在 install/status 上是用法错,什么都不动", async () => {
  const box = (sandbox = await makeSandbox("launchd"));

  for (const action of ["install", "status"]) {
    const result = await runCli(["service", action, "--purge", "--json"], {
      home: box.home,
      env: box.env,
    });

    expect(result.exitCode).toBe(1);
    const body = parseJsonStdout(result);
    expect(body.ok).toBe(false);
    expect(body.error.code).toBe("usage");
    expect(body.error.message).toContain("--purge");
  }
  expect(await supervisorCalls(box)).toEqual([]);
  expect(existsSync(box.unitPath)).toBe(false);
});

test("人类面也给同一份账:移除的 label、删掉的路径、以及「你自己的 mihomo 不在内」", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await service(box, ["install"]);
  await installLiveUnit(box, "launchd", MIHOMO_LABEL, managedMihomoArguments(box.home));

  const human = await runCli(["service", "uninstall", "--purge"], { home: box.home, env: box.env });

  expect(human.exitCode).toBe(0);
  expect(human.stdout).toContain(`已移除的 unit:${LABEL}、${MIHOMO_LABEL}`);
  expect(human.stdout).toContain(`已删除的目录:${box.home}`);
  expect(human.stdout).toContain("你自己装的 mihomo");
  // 不带旗标那条的注解不该在这里冒出来(它说的是"拷贝保留不删",而这一次正好删了)。
  expect(human.stdout).not.toContain("保留不删");
});

/**
 * **自删合法性**(票面第 3 条):purge 会删掉 `$A2_HOME/bin/a2`,而这条命令可能正是**从那份拷贝**跑的。
 * 删除正在执行的可执行在 macOS/Linux 上是合法的(inode 活到进程退出),所以它必须跑完、退干净。
 *
 * 这条在两种被测体上都跑,但**真正的证明在编译产物那一遍**(`A2_TEST_BIN` / `kernel/scripts/build.sh`):
 * 那时 `$A2_HOME/bin/a2` 是一份真的单文件产物,进程正在执行的就是被删掉的那些字节;
 * 源码那一遍拷过去的是个 `exec bun …` 的壳脚本,`sh` 早就 exec 走了,证明力弱一档 —— 如实记在这里。
 */
test("自删:从 $A2_HOME/bin/a2 那份拷贝上跑 purge —— 删掉正在执行的自身,照样退出 0 且目录没了", async () => {
  const box = (sandbox = await makeSandbox("launchd"));
  await writeSelfBin(box, "v1");
  const env = { ...box.env, ...selfBinEnv(box) };
  await runCli(["service", "install", "--copy-to-home", "--json"], { home: box.home, env });
  expect(existsSync(box.homeBinPath)).toBe(true);

  // 注意:跑的是**那份拷贝**,不是被测体自己。
  const proc = Bun.spawnSync({
    cmd: [box.homeBinPath, "service", "uninstall", "--purge", "--json"],
    env: { ...process.env, ...box.env, A2_HOME: box.home },
  });

  expect(proc.exitCode).toBe(0);
  const body = JSON.parse(proc.stdout.toString());
  expect(body.ok).toBe(true);
  expect(body.result.actions).toContain("home_purged");
  expect(body.result.purge.removedPaths).toEqual([box.home]);
  // 自己把自己删了,而且删干净了。
  expect(existsSync(box.homeBinPath)).toBe(false);
  expect(existsSync(box.home)).toBe(false);
  expect(existsSync(box.unitPath)).toBe(false);
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
