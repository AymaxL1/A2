// 代理域测试的沙盒(07 票)。**每一处能碰到真机的地方都被注入成假件**:
//   * supervisor → `fake-supervisor/launchctl`(被测进程的 PATH 只有它);
//   * mihomo    → `fake-mihomo/`(真子进程 + 回环 REST 子集,但不是真内核);
//   * networksetup → `fake-networksetup/`(**门禁绝不碰真的系统代理**,那是本票最硬的纪律);
//   * 扫描面、发布渠道、控制端口、入站端口 → 全部指向本沙盒。
//
// 与 06 票那份沙盒的一处关键不同:代理域能力**跑在 daemon 进程里**,所以同一套环境要喂两遍 ——
// 一遍给跑 `a2 mihomo install` 的那个短命 CLI 进程,一遍给常驻的 daemon。

import { existsSync, readdirSync } from "node:fs";
import { chmod, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  cleanupHome,
  parseJsonStdout,
  runCli,
  startDaemon,
  stopDaemon,
  type CliResult,
  type DaemonHandle,
} from "./harness.ts";

const FAKE_SUPERVISOR_DIR = path.resolve(import.meta.dir, "fake-supervisor");
const FAKE_MIHOMO_SH = path.resolve(import.meta.dir, "fake-mihomo/mihomo");
const FAKE_MIHOMO_TS = path.resolve(import.meta.dir, "fake-mihomo/fake-mihomo.ts");
const FAKE_NETSETUP_SH = path.resolve(import.meta.dir, "fake-networksetup/networksetup");
const FAKE_NETSETUP_TS = path.resolve(import.meta.dir, "fake-networksetup/fake-networksetup.ts");

export const MIHOMO_LABEL = "com.a2.mihomo";

/**
 * 假 networksetup 的初始状态,**逐字沿用旧门禁那份 fixture**
 * (`Scripts/check/proxy-e2e.sh` 的 netfake-state.json):Wi-Fi 全关;
 * Ethernet **原本就有第三方代理** 203.0.113.9:8080,SOCKS 关。
 * 那个第三方代理是整组断言的灵魂 —— 「还原 = 精确复原,不是一律关闭」全靠它才证得出来。
 */
export const INITIAL_NETWORK_STATE = {
  services: [
    {
      service: "Wi-Fi",
      http: { enabled: false, host: "", port: 0 },
      https: { enabled: false, host: "", port: 0 },
      socks: { enabled: false, host: "", port: 0 },
    },
    {
      service: "Ethernet",
      http: { enabled: true, host: "203.0.113.9", port: 8080 },
      https: { enabled: true, host: "203.0.113.9", port: 8080 },
      socks: { enabled: false, host: "", port: 0 },
    },
  ],
};

export interface ProxySandbox {
  root: string;
  home: string;
  stateDir: string;
  supervisorLog: string;
  foreignBinDir: string;
  foreignBinary: string;
  foreignConfig: string;
  controllerPort: number;
  mixedPort: number;
  managedConfig: string;
  managedBinary: string;
  mihomoUnitPath: string;
  netStatePath: string;
  netLogPath: string;
  snapshotPath: string;
  supervisionLog: string;
  env: Record<string, string>;
  daemon?: DaemonHandle;
  foreignProc?: Bun.Subprocess;
}

export async function freePort(): Promise<number> {
  const server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Response("ok") });
  const port = server.port ?? 0;
  server.stop(true);
  if (port === 0) throw new Error("拿不到空闲端口");
  return port;
}

export async function makeProxySandbox(
  options: { groups?: string; delays?: string } = {},
): Promise<ProxySandbox> {
  const root = await mkdtemp("/tmp/a2px-");
  const home = path.join(root, "a2home");
  const foreignBinDir = path.join(root, "foreignbin");
  const foreignConfDir = path.join(root, "foreignconf");
  await mkdir(foreignBinDir, { recursive: true });
  await mkdir(foreignConfDir, { recursive: true });
  const stateDir = path.join(root, "supervisor-state");
  const supervisorLog = path.join(root, "supervisor-calls.log");
  await writeFile(supervisorLog, "");
  const netStatePath = path.join(root, "netfake-state.json");
  const netLogPath = path.join(root, "netfake-calls.log");
  await writeFile(netStatePath, `${JSON.stringify(INITIAL_NETWORK_STATE, null, 2)}\n`);
  await writeFile(netLogPath, "");

  const controllerPort = await freePort();
  const mixedPort = await freePort();

  return {
    root,
    home,
    stateDir,
    supervisorLog,
    foreignBinDir,
    foreignBinary: path.join(foreignBinDir, "mihomo"),
    foreignConfig: path.join(foreignConfDir, "config.yaml"),
    controllerPort,
    mixedPort,
    managedConfig: path.join(home, "mihomo", "config.yaml"),
    managedBinary: path.join(home, "mihomo", "bin", "mihomo"),
    mihomoUnitPath: path.join(root, "Library", "LaunchAgents", `${MIHOMO_LABEL}.plist`),
    netStatePath,
    netLogPath,
    snapshotPath: path.join(home, "system-proxy.json"),
    supervisionLog: path.join(home, "log", "proxy-supervision.log"),
    env: {
      // 被测进程的 PATH 只有假件目录 —— 真 launchctl / 真 networksetup 在它眼里不存在。
      PATH: `${FAKE_SUPERVISOR_DIR}:${path.dirname(FAKE_NETSETUP_SH)}`,
      HOME: root,
      XDG_CONFIG_HOME: path.join(root, "xdg"),
      A2_SERVICE_SUPERVISOR: "launchd",
      A2_FAKE_STATE_DIR: stateDir,
      A2_FAKE_LOG: supervisorLog,
      A2_FAKE_BUN: process.execPath,
      A2_FAKE_MIHOMO_TS: FAKE_MIHOMO_TS,
      A2_FAKE_MIHOMO_VERSION: "v1.19.28",
      A2_FAKE_NETSETUP_TS: FAKE_NETSETUP_TS,
      A2_FAKE_NETSETUP_STATE: netStatePath,
      A2_FAKE_NETSETUP_LOG: netLogPath,
      // **系统代理这一层整条注入**:内核发的每一条 networksetup 都落在这个假件上。
      A2_NETWORKSETUP: FAKE_NETSETUP_SH,
      // 扫描面全注入:默认两处都指向空的沙盒位置。
      A2_MIHOMO_BIN_DIRS: foreignBinDir,
      A2_MIHOMO_CONFIG_FILES: path.join(foreignConfDir, "config.yaml"),
      A2_MIHOMO_CONTROLLER_PORT: String(controllerPort),
      A2_MIHOMO_MIXED_PORT: String(mixedPort),
      ...(options.groups ? { A2_FAKE_MIHOMO_GROUPS: options.groups } : {}),
      ...(options.delays ? { A2_FAKE_MIHOMO_DELAYS: options.delays } : {}),
      // 观测循环在测试里要跑得够快才看得到状态变化。
      A2_PROXY_WATCH_INTERVAL_MS: "200",
    },
  };
}

export async function cleanupProxySandbox(box: ProxySandbox): Promise<void> {
  if (box.daemon) await stopDaemon(box.daemon);
  if (box.foreignProc && !box.foreignProc.killed) {
    box.foreignProc.kill("SIGKILL");
    await box.foreignProc.exited;
  }
  const stateFiles = existsSync(box.stateDir) ? readdirSync(box.stateDir) : [];
  for (const name of stateFiles) {
    const raw = await readFile(path.join(box.stateDir, name), "utf8").catch(() => "");
    const pid = Number.parseInt(raw.trim().split(" ").pop() ?? "", 10);
    if (Number.isFinite(pid) && pid > 0 && isAlive(pid)) {
      try {
        process.kill(pid, "SIGKILL");
      } catch {
        /* 已经没了就算了 */
      }
    }
  }
  // 兜底:沙盒根是本次独有的临时路径,按它精确回收 —— 不可能误伤别的进程(尤其是用户自己的 mihomo)。
  Bun.spawnSync({ cmd: ["/usr/bin/pkill", "-9", "-f", box.root], stdout: "ignore", stderr: "ignore" });
  await cleanupHome(box.home);
  await rm(box.root, { recursive: true, force: true });
}

export function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

export async function waitFor(
  what: string,
  check: () => boolean | Promise<boolean>,
  timeoutMs = 8000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await check()) return;
    await Bun.sleep(30);
  }
  throw new Error(`等「${what}」超时(${timeoutMs}ms)`);
}

/** 把假 mihomo 放进"别人的 bin 目录"(复用档的复用对象)。 */
export async function installForeignBinary(box: ProxySandbox): Promise<void> {
  await copyFile(FAKE_MIHOMO_SH, box.foreignBinary);
  await chmod(box.foreignBinary, 0o755);
}

/**
 * 让 a2 自管的 mihomo 就位(走复用档:落点是指向假件的符号链接),并起一个 daemon。
 * 返回之后,`a2 proxy …` 就有对象了。
 */
export async function provisionManaged(box: ProxySandbox): Promise<void> {
  await installForeignBinary(box);
  const result = await runCli(["mihomo", "install", "--json"], { home: box.home, env: box.env });
  if (result.exitCode !== 0) {
    throw new Error(`mihomo install 失败(exit=${result.exitCode}):${result.stdout}${result.stderr}`);
  }
}

/** 起一个"别人托管的"实例(收编档用):进程由测试自己拉起,不在任何 a2 的 unit 里。 */
export async function startForeignInstance(
  box: ProxySandbox,
  options: { groups?: string } = {},
): Promise<{ port: number; controller: string; secret: string }> {
  const port = await freePort();
  const controller = `127.0.0.1:${port}`;
  const secret = "s3cr3t-foreign";
  await writeFile(
    box.foreignConfig,
    [
      ...(options.groups ? [`# fake-groups: ${options.groups}`] : []),
      "mixed-port: 7890",
      "mode: rule",
      `external-controller: ${controller}`,
      `secret: ${secret}`,
      "",
    ].join("\n"),
  );
  await installForeignBinary(box);
  box.foreignProc = Bun.spawn({
    cmd: [box.foreignBinary, "-d", path.dirname(box.foreignConfig), "-f", box.foreignConfig],
    env: {
      ...process.env,
      A2_FAKE_BUN: process.execPath,
      A2_FAKE_MIHOMO_TS: FAKE_MIHOMO_TS,
      A2_FAKE_MIHOMO_VERSION: "v1.19.28",
    },
    stdout: "ignore",
    stderr: "ignore",
    stdin: "ignore",
  });
  await waitFor("别人的 mihomo 起来并应答", async () => {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/version`, {
        headers: { Authorization: `Bearer ${secret}` },
        signal: AbortSignal.timeout(500),
      });
      return response.ok;
    } catch {
      return false;
    }
  });
  return { port, controller, secret };
}

/** 起 daemon(代理域能力跑在它里面,所以整套沙盒环境都要喂给它)。 */
export async function startProxyDaemon(box: ProxySandbox): Promise<DaemonHandle> {
  box.daemon = await startDaemon(box.home, box.env);
  return box.daemon;
}

/** 跑一条 `a2 proxy …`(恒带 `--json`)。 */
export async function proxy(box: ProxySandbox, args: string[]): Promise<CliResult> {
  return await runCli(["proxy", ...args, "--json"], { home: box.home, env: box.env });
}

/** 跑一条 `a2 capabilities call <id> [--input …]`。 */
export async function call(
  box: ProxySandbox,
  id: string,
  input?: Record<string, unknown>,
): Promise<CliResult> {
  const args = ["capabilities", "call", id];
  if (input) args.push("--input", JSON.stringify(input));
  args.push("--json");
  return await runCli(args, { home: box.home, env: box.env });
}

export function body(result: CliResult): any {
  return parseJsonStdout(result);
}

/**
 * 能力调用的**业务载荷**。域子命令与 `capabilities call` 走同一条路,所以两者的 result 都是
 * `{capability, output}` —— 取值路径统一多一层 `result.output`(与 04 票「有意的契约变更 1」同源:
 * 机读面成功失败同一形状,代价就是这一层)。
 */
export function out(result: CliResult): any {
  return parseJsonStdout(result).result.output;
}

/** 假 networksetup 的当前状态(逐字段比较用)。 */
export async function networkState(box: ProxySandbox): Promise<typeof INITIAL_NETWORK_STATE> {
  return JSON.parse(await readFile(box.netStatePath, "utf8"));
}

/** 内核对 networksetup 说过的每一句话(红线核对用)。 */
export async function networkCalls(box: ProxySandbox): Promise<string[]> {
  const text = await readFile(box.netLogPath, "utf8");
  return text.split("\n").filter((line) => line.length > 0);
}
