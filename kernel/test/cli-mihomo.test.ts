// CLI 缝(最高缝):`a2 mihomo status|enable|disable|restart` 的行为契约(14 票 / ADR 0014)。
//
// **这份文件的第一职责是守住施工红线**:本机可能跑着用户自己的 mihomo,而这里的每一个「mihomo」都是
// `support/fake-mihomo/` 里那个行为假件 —— 二进制搜索目录、配置搜索路径、发布渠道、自管控制端口、
// 子进程节流全部由环境变量注入到沙盒里,没有一条断言会去扫真系统面、连真端口、动真 unit。
//
// 假件不是打桩:daemon **真的把它 spawn 成子进程**并**真的在回环上暴露 external-controller**,
// 所以链条是端到端的(enable → daemon 拉起真进程 → GET /version 真答话 → status 报 running)。
//
// 14 票的三条硬语义在这里逐条有断言:
//   * mihomo 随 a2 生死(杀 daemon 子进程同死;daemon 回来按落盘模式重建);
//   * 保活归内核亲管(崩溃节流重拉、连续秒退转故障态停手、restart 清零复活);
//   * 配置正文归用户与 agent(a2 只钉七个头部键,其余字节原样保留)。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, readdirSync, statSync } from "node:fs";
import { chmod, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { MihomoChangeResultSchema, MihomoStatusResultSchema } from "../src/contract/wire.ts";
import {
  defaultBinaryDirs,
  defaultConfigFiles,
  loopbackTarget,
  readControllerFromConfig,
} from "../src/mihomo/paths.ts";
import { MIHOMO_ASSET_DIGESTS, MIHOMO_LOCKED_VERSION } from "../src/mihomo/pin.ts";
import { parseJsonStdout, runCli, startDaemon, stopDaemon, type DaemonHandle } from "./support/harness.ts";

const FAKE_SUPERVISOR_DIR = path.resolve(import.meta.dir, "support/fake-supervisor");
const FAKE_MIHOMO_SH = path.resolve(import.meta.dir, "support/fake-mihomo/mihomo");
const FAKE_MIHOMO_TS = path.resolve(import.meta.dir, "support/fake-mihomo/fake-mihomo.ts");
const MIHOMO_LABEL = "com.a2.mihomo";

interface Sandbox {
  root: string;
  home: string;
  stateDir: string;
  logPath: string;
  foreignBinDir: string;
  foreignBinary: string;
  foreignConfig: string;
  controllerPort: number;
  /** 旧版 `com.a2.mihomo` 的 plist **会**落的位置(迁移测试往这里预置遗产)。 */
  mihomoUnitPath: string;
  managedBinary: string;
  managedConfig: string;
  childRecord: string;
  env: Record<string, string>;
  daemon?: DaemonHandle;
  foreignProc?: Bun.Subprocess;
}

let sandbox: Sandbox | undefined;

async function freePort(): Promise<number> {
  const server = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Response("ok") });
  const port = server.port ?? 0;
  server.stop(true);
  if (port === 0) throw new Error("拿不到空闲端口");
  return port;
}

async function makeSandbox(): Promise<Sandbox> {
  const root = await mkdtemp("/tmp/a2mh-");
  const home = path.join(root, "a2home");
  const foreignBinDir = path.join(root, "foreignbin");
  const foreignConfDir = path.join(root, "foreignconf");
  await mkdir(foreignBinDir, { recursive: true });
  await mkdir(foreignConfDir, { recursive: true });
  const stateDir = path.join(root, "supervisor-state");
  const logPath = path.join(root, "supervisor-calls.log");
  await writeFile(logPath, "");
  const controllerPort = await freePort();

  return {
    root,
    home,
    stateDir,
    logPath,
    foreignBinDir,
    foreignBinary: path.join(foreignBinDir, "mihomo"),
    foreignConfig: path.join(foreignConfDir, "config.yaml"),
    controllerPort,
    mihomoUnitPath: path.join(root, "Library", "LaunchAgents", `${MIHOMO_LABEL}.plist`),
    managedBinary: path.join(home, "mihomo", "bin", "mihomo"),
    managedConfig: path.join(home, "mihomo", "config.yaml"),
    childRecord: path.join(home, "mihomo", "child.json"),
    env: {
      // 被测进程的 PATH 只有假 supervisor 目录 —— 真 launchctl 在它眼里不存在。
      PATH: FAKE_SUPERVISOR_DIR,
      HOME: root,
      XDG_CONFIG_HOME: path.join(root, "xdg"),
      A2_SERVICE_SUPERVISOR: "launchd",
      A2_FAKE_STATE_DIR: stateDir,
      A2_FAKE_LOG: logPath,
      A2_FAKE_BUN: process.execPath,
      A2_FAKE_MIHOMO_TS: FAKE_MIHOMO_TS,
      A2_FAKE_MIHOMO_VERSION: "v1.19.28",
      // **扫描面全注入**:默认两处都指向空的沙盒位置,所以默认现状 = 全无。
      A2_MIHOMO_BIN_DIRS: foreignBinDir,
      A2_MIHOMO_CONFIG_FILES: path.join(foreignConfDir, "config.yaml"),
      A2_MIHOMO_CONTROLLER_PORT: String(controllerPort),
      // 子进程节流/健康阈值调快:等真 10 秒的重拉是浪费门禁的命。
      A2_MIHOMO_CHILD_THROTTLE_MS: "300",
      A2_MIHOMO_CHILD_HEALTHY_MS: "200",
    },
  };
}

async function mihomo(box: Sandbox, args: string[], extraEnv: Record<string, string> = {}) {
  return await runCli(["mihomo", ...args, "--json"], {
    home: box.home,
    env: { ...box.env, ...extraEnv },
  });
}

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

async function waitFor(what: string, check: () => boolean | Promise<boolean>, timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await check()) return;
    await Bun.sleep(30);
  }
  throw new Error(`等「${what}」超时(${timeoutMs}ms)`);
}

/** 把假 mihomo 放到 a2 自管落点(版本=锁定版 → enable 不会走下载)。 */
async function placeManagedBinary(box: Sandbox): Promise<void> {
  await mkdir(path.dirname(box.managedBinary), { recursive: true });
  await copyFile(FAKE_MIHOMO_SH, box.managedBinary);
  await chmod(box.managedBinary, 0o755);
}

/** 起一个"别人的实例":进程由测试自己拉起,不归 a2。 */
async function startForeignInstance(box: Sandbox): Promise<{ port: number; controller: string }> {
  const port = await freePort();
  const controller = `127.0.0.1:${port}`;
  await writeFile(
    box.foreignConfig,
    ["mixed-port: 7890", "mode: rule", `external-controller: ${controller}`, "secret: s3cr3t", ""].join("\n"),
  );
  await copyFile(FAKE_MIHOMO_SH, box.foreignBinary);
  await chmod(box.foreignBinary, 0o755);
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
        headers: { Authorization: "Bearer s3cr3t" },
        signal: AbortSignal.timeout(500),
      });
      return response.ok;
    } catch {
      return false;
    }
  });
  return { port, controller };
}

/** 起一个本地"发布渠道":按官方资产命名给出一份 gzip 资产,返回根地址与它的 SHA-256。 */
function serveRelease(payload: string): { base: string; sha256: string; stop: () => void } {
  const bytes = new TextEncoder().encode(payload);
  const gz = Bun.gzipSync(bytes);
  const sha256 = new Bun.CryptoHasher("sha256").update(bytes).digest("hex");
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request) {
      return new URL(request.url).pathname.endsWith(".gz")
        ? new Response(gz)
        : new Response("not found", { status: 404 });
    },
  });
  return { base: `http://127.0.0.1:${server.port ?? 0}`, sha256, stop: () => server.stop(true) };
}

/** 下载档的"资产"就是假 mihomo 那个 sh 壳本身 —— 落位之后子进程才真起得来。 */
async function releasePayload(suffix = ""): Promise<string> {
  return `${await Bun.file(FAKE_MIHOMO_SH).text()}${suffix}`;
}

async function statusOf(box: Sandbox): Promise<any> {
  const result = await mihomo(box, ["status"]);
  expect(result.exitCode).toBe(0);
  return parseJsonStdout(result).result;
}

async function waitRunning(box: Sandbox): Promise<any> {
  let status: any;
  await waitFor("内嵌子进程拉起并应答", async () => {
    status = await statusOf(box);
    return status.embedded.state === "running" && status.embedded.controllerReachable === true;
  });
  return status;
}

beforeEach(() => {
  sandbox = undefined;
});

afterEach(async () => {
  if (!sandbox) return;
  if (sandbox.daemon) await stopDaemon(sandbox.daemon).catch(() => {});
  if (sandbox.foreignProc && !sandbox.foreignProc.killed) {
    sandbox.foreignProc.kill("SIGKILL");
    await sandbox.foreignProc.exited;
  }
  const stateFiles = existsSync(sandbox.stateDir) ? readdirSync(sandbox.stateDir) : [];
  for (const name of stateFiles) {
    const raw = await readFile(path.join(sandbox.stateDir, name), "utf8").catch(() => "");
    const pid = Number.parseInt(raw.trim().split(" ").pop() ?? "", 10);
    if (Number.isFinite(pid) && pid > 0 && isAlive(pid)) {
      try {
        process.kill(pid, "SIGKILL");
      } catch {
        /* 已经没了就算了 */
      }
    }
  }
  // 兜底:沙盒根是本次独有的临时路径,按它精确回收 —— 不可能误伤任何别的进程(尤其是用户自己的 mihomo)。
  Bun.spawnSync({ cmd: ["/usr/bin/pkill", "-9", "-f", sandbox.root], stdout: "ignore", stderr: "ignore" });
  await rm(sandbox.root, { recursive: true, force: true });
  sandbox = undefined;
});

// MARK: - status(只读 + guidance)

test("mihomo status 出厂态:mode=off、内嵌 stopped、退出码 0 且只读;guidance 态 A 推荐 embedded", async () => {
  const box = (sandbox = await makeSandbox());

  const status = await statusOf(box);
  expect(MihomoStatusResultSchema.safeParse(status).success).toBe(true);
  expect(status.mode).toBe("off");
  expect(status.embedded.state).toBe("stopped");
  expect(status.embedded.lockedVersion).toBe(MIHOMO_LOCKED_VERSION);
  // 未启用时路径照样给出(那是启用会写的位置,agent 不必猜)。
  expect(status.embedded.binaryPath).toBe(box.managedBinary);
  expect(status.foreign).toBeUndefined();
  // guidance 态 A:推荐 embedded,下载授权明写版本;第一读者是 agent(「与用户确认后」)。
  expect(status.guidance.summary).toContain("推荐 embedded");
  const commands = status.guidance.steps.map((s: { command?: string }) => s.command);
  expect(commands).toContain("a2 mihomo enable --mode=embedded --json");
  expect(status.guidance.steps[0].description).toContain("与用户确认后");

  // **只读**:status 不该在盘上留下任何东西。
  expect(existsSync(box.home)).toBe(false);
});

test("mihomo status 检测到外来实例:foreign 全是只读事实;guidance 态 B 把双模式讲给用户、由用户选", async () => {
  const box = (sandbox = await makeSandbox());
  const foreign = await startForeignInstance(box);

  const status = await statusOf(box);
  expect(status.mode).toBe("off");
  expect(status.foreign.instance.controller).toBe(foreign.controller);
  expect(status.foreign.instance.reachable).toBe(true);
  expect(status.foreign.instance.secretConfigured).toBe(true);
  expect(status.foreign.instance.capabilities).toContain("rest_api");
  // 态 B:两条命令各对应一个用户选择;**agent 不代选**是写进 summary 的行为指令。
  expect(status.guidance.summary).toContain("由用户选择");
  const commands = status.guidance.steps.map((s: { command?: string }) => s.command);
  expect(commands).toContain("a2 mihomo enable --mode=observe --json");
  expect(commands).toContain("a2 mihomo enable --mode=embedded --json");

  // 别人的进程一根汗毛都没少。
  expect(box.foreignProc && !box.foreignProc.killed).toBe(true);
});

test("mihomo status:配置里的 external-controller 不是回环 → 有意不探,如实报 skippedController", async () => {
  const box = (sandbox = await makeSandbox());
  await writeFile(box.foreignConfig, ["external-controller: 192.168.1.10:9090", ""].join("\n"));

  const status = await statusOf(box);
  expect(status.foreign.skippedController).toBe("192.168.1.10:9090");
  expect(status.foreign.instance).toBeUndefined();
});

// MARK: - enable / disable(模式落盘 + 就位)

test("enable --mode=embedded 下载档全流程:下载→SHA-256→落位→钉头部;第二次幂等 actions 空", async () => {
  const box = (sandbox = await makeSandbox());
  const release = serveRelease(await releasePayload());
  try {
    const result = await mihomo(box, ["enable", "--mode=embedded"], {
      A2_MIHOMO_RELEASE_BASE: release.base,
      A2_MIHOMO_EXPECT_SHA256: release.sha256,
    });
    expect(result.exitCode).toBe(0);
    const change = parseJsonStdout(result).result;
    expect(MihomoChangeResultSchema.safeParse(change).success).toBe(true);
    expect(change.actions).toEqual(["data_dir_created", "mode_set", "config_written", "binary_downloaded"]);
    expect(change.status.mode).toBe("embedded");

    // 二进制真落位且可执行;配置头部由 a2 钉住(controller + secret)。
    expect(statSync(box.managedBinary).mode & 0o111).not.toBe(0);
    const config = await readFile(box.managedConfig, "utf8");
    expect(config).toContain(`external-controller: 127.0.0.1:${box.controllerPort}`);
    expect(config).toMatch(/^secret: /m);
    // 模式落盘(一次性裁定,daemon 每次启动照它办事)。
    const settings = JSON.parse(await readFile(path.join(box.home, "mihomo", "settings.json"), "utf8"));
    expect(settings.managedMode).toBe("embedded");

    // 幂等:什么都不改,actions 为空(下载档就位后**绝不**重复下载)。
    const again = await mihomo(box, ["enable", "--mode=embedded"], {
      A2_MIHOMO_RELEASE_BASE: release.base,
      A2_MIHOMO_EXPECT_SHA256: release.sha256,
    });
    expect(parseJsonStdout(again).result.actions).toEqual([]);
  } finally {
    release.stop();
  }
});

test("enable 下载 fail-closed:摘要不符 → 退出码 5,落点上一个字节都没写", async () => {
  const box = (sandbox = await makeSandbox());
  // 有意**不**给 A2_MIHOMO_EXPECT_SHA256:走 pin.ts 里那张真摘要表 —— 假资产必然对不上。
  const release = serveRelease(await releasePayload("x"));
  try {
    const result = await mihomo(box, ["enable", "--mode=embedded"], {
      A2_MIHOMO_RELEASE_BASE: release.base,
    });
    expect(result.exitCode).toBe(5);
    expect(parseJsonStdout(result).error.code).toBe("mihomo_operation_failed");
    expect(existsSync(box.managedBinary)).toBe(false);
    expect(existsSync(`${box.managedBinary}.download`)).toBe(false);
  } finally {
    release.stop();
  }
});

test("enable:本平台没登记摘要 → 拒绝下载(连一次 GET 都不发),指引给出 observe 那条退路", async () => {
  const box = (sandbox = await makeSandbox());
  let hits = 0;
  const channel = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch() {
      hits += 1;
      return new Response("should never be called", { status: 500 });
    },
  });
  try {
    const result = await mihomo(box, ["enable", "--mode=embedded"], {
      A2_MIHOMO_RELEASE_BASE: `http://127.0.0.1:${channel.port}`,
      A2_MIHOMO_ASSET_KEY: "linux-amd64",
    });
    expect(result.exitCode).toBe(5);
    const error = parseJsonStdout(result).error;
    expect(error.guidance.summary).toContain("fail-closed");
    const commands = error.guidance.steps.map((s: { command?: string }) => s.command);
    expect(commands).toContain("a2 mihomo enable --mode=observe --json");
    expect(hits).toBe(0);
  } finally {
    channel.stop(true);
  }
});

test("enable --mode=observe / disable:只落盘模式,不建不下载;disable 幂等", async () => {
  const box = (sandbox = await makeSandbox());

  const enable = await mihomo(box, ["enable", "--mode=observe"]);
  expect(enable.exitCode).toBe(0);
  expect(parseJsonStdout(enable).result.actions).toEqual(["mode_set"]);
  expect(existsSync(box.managedBinary)).toBe(false);

  const disable = await mihomo(box, ["disable"]);
  expect(parseJsonStdout(disable).result.actions).toEqual(["mode_set"]);
  const again = await mihomo(box, ["disable"]);
  expect(parseJsonStdout(again).result.actions).toEqual([]);
});

test("配置正文归 agent:手写的 proxies/规则原样保留,a2 只把自己的头部键钉回去", async () => {
  const box = (sandbox = await makeSandbox());
  await placeManagedBinary(box);
  await mihomo(box, ["enable", "--mode=embedded"]);

  // agent 直接改 YAML:加节点正文 + 试图篡改 a2 拥有的 mixed-port。
  const before = await readFile(box.managedConfig, "utf8");
  const tampered = `${before.replace(/^mixed-port: .*$/m, "mixed-port: 1080")}\nproxies:\n  - {name: n1, type: socks5, server: 1.2.3.4, port: 1080}\n# agent 的注释\n`;
  await writeFile(box.managedConfig, tampered);

  const result = await mihomo(box, ["enable", "--mode=embedded"]);
  expect(parseJsonStdout(result).result.actions).toEqual(["config_written"]);
  const after = await readFile(box.managedConfig, "utf8");
  // 头部键被钉回(settings 里的默认端口),正文与注释一个字节没丢。
  expect(after).not.toContain("mixed-port: 1080");
  expect(after).toContain("name: n1");
  expect(after).toContain("# agent 的注释");
});

test("升级随 a2 走:盘上版本 ≠ 锁定版 → enable 自动换成锁定版(binary_upgraded),没有独立 upgrade 命令", async () => {
  const box = (sandbox = await makeSandbox());
  await placeManagedBinary(box);
  const release = serveRelease(await releasePayload("# upgraded")); // 内容带标记,换没换看得见
  try {
    const result = await mihomo(box, ["enable", "--mode=embedded"], {
      A2_FAKE_MIHOMO_VERSION: "v1.18.0", // 盘上那份自报旧版本
      A2_MIHOMO_RELEASE_BASE: release.base,
      A2_MIHOMO_EXPECT_SHA256: release.sha256,
    });
    expect(result.exitCode).toBe(0);
    expect(parseJsonStdout(result).result.actions).toContain("binary_upgraded");
    expect(await readFile(box.managedBinary, "utf8")).toContain("# upgraded");

    // 旧命令面整族退场:upgrade/install/uninstall 都是用法错。
    for (const legacy of ["upgrade", "install", "uninstall"]) {
      const gone = await mihomo(box, [legacy]);
      expect(gone.exitCode).toBe(1);
      expect(parseJsonStdout(gone).error.code).toBe("usage");
    }
  } finally {
    release.stop();
  }
});

test("旧版 com.a2.mihomo 迁移:检出 → status 报 legacyUnit;enable 自动 bootout+删 plist(自己的遗产自己收)", async () => {
  const box = (sandbox = await makeSandbox());
  await mkdir(path.dirname(box.mihomoUnitPath), { recursive: true });
  await writeFile(box.mihomoUnitPath, "<?xml version=\"1.0\"?><plist><dict/></plist>\n");
  await placeManagedBinary(box);

  const status = await statusOf(box);
  expect(status.legacyUnit).toBe(true);
  // 告知文案随 guidance 带出(启用时会自动移除,无需手工处理)。
  const texts = status.guidance.steps.map((s: { description: string }) => s.description).join("");
  expect(texts).toContain("自动移除");

  const result = await mihomo(box, ["enable", "--mode=embedded"]);
  expect(result.exitCode).toBe(0);
  expect(parseJsonStdout(result).result.actions).toContain("legacy_unit_removed");
  expect(existsSync(box.mihomoUnitPath)).toBe(false);

  // **红线**:supervisor 收到的每一条命令都只针对旧 label,别人的 unit 在任何分支下都进不来。
  const calls = await supervisorCalls(box);
  expect(calls.length).toBeGreaterThan(0);
  expect(calls.every((line) => line.includes(MIHOMO_LABEL))).toBe(true);
});

// MARK: - 子进程生死(经真 daemon)

test("随 a2 生死:daemon 起来拉起子进程(认尸文件为证);daemon 停,子进程同死", async () => {
  const box = (sandbox = await makeSandbox());
  await placeManagedBinary(box);
  await mihomo(box, ["enable", "--mode=embedded"]);

  box.daemon = await startDaemon(box.home, box.env);
  const status = await waitRunning(box);
  const pid = status.embedded.pid as number;
  expect(isAlive(pid)).toBe(true);
  const record = JSON.parse(await readFile(box.childRecord, "utf8"));
  expect(record.pid).toBe(pid);
  expect(record.binaryPath).toBe(box.managedBinary);

  await stopDaemon(box.daemon);
  box.daemon = undefined;
  await waitFor("子进程随 daemon 停下", () => !isAlive(pid));
  expect((await statusOf(box)).embedded.state).toBe("stopped");

  // 全程零 supervisor 调用:子进程与 launchd 无关(全机只剩 com.a2.kernel 一个 unit)。
  expect(await supervisorCalls(box)).toEqual([]);
});

test("保活:子进程被杀 → 节流后 a2 自己把它重拉回来(新 pid)", async () => {
  const box = (sandbox = await makeSandbox());
  await placeManagedBinary(box);
  await mihomo(box, ["enable", "--mode=embedded"]);
  box.daemon = await startDaemon(box.home, box.env);
  const first = (await waitRunning(box)).embedded.pid as number;

  process.kill(first, "SIGKILL");
  await waitFor("子进程真的没了", () => !isAlive(first));
  await waitFor("节流后重拉出新进程", async () => {
    const status = await statusOf(box);
    return status.embedded.state === "running" && status.embedded.pid !== first;
  });
});

test("故障态:连续秒退 ×3 → failed + lastError 原文 + guidance 态 C;restart 清零复活", async () => {
  const box = (sandbox = await makeSandbox());
  await placeManagedBinary(box);
  await mihomo(box, ["enable", "--mode=embedded"]);
  box.daemon = await startDaemon(box.home, box.env);
  await waitRunning(box);

  // 把二进制换成秒退件(模拟"配置坏了起不来"):restart 触发,三连败转故障态。
  await writeFile(box.managedBinary, "#!/bin/sh\necho 'FATA boom: broken config' >&2\nexit 1\n");
  await chmod(box.managedBinary, 0o755);
  const restart = await mihomo(box, ["restart"]);
  expect(restart.exitCode).toBe(0);
  await waitFor("三连败转故障态", async () => (await statusOf(box)).embedded.state === "failed", 15000);

  const failed = await statusOf(box);
  expect(failed.embedded.restartCount).toBeGreaterThanOrEqual(3);
  expect(failed.embedded.lastError).toContain("boom");
  expect(failed.guidance.summary).toContain("已暂停重拉");
  const commands = failed.guidance.steps.map((s: { command?: string }) => s.command);
  expect(commands).toContain("a2 mihomo restart --json");

  // 修好(换回好件)+ restart:计数清零,复活。
  await copyFile(FAKE_MIHOMO_SH, box.managedBinary);
  await chmod(box.managedBinary, 0o755);
  const revive = await mihomo(box, ["restart"]);
  expect(revive.exitCode).toBe(0);
  const back = await waitRunning(box);
  expect(back.embedded.restartCount).toBe(0);
}, 30000);

test("升级随行的另一半(CR):daemon 启动的 apply 也对表 —— 盘上旧版,拉起前自动换锁定版", async () => {
  const box = (sandbox = await makeSandbox());
  await placeManagedBinary(box);
  await mihomo(box, ["enable", "--mode=embedded"]);

  // 盘上那份此后"变旧"(自报 v1.18.0),渠道上摆着锁定版 —— daemon 起来的 apply 必须换掉它,
  // 不等人重跑 enable(ADR 0014 D6:升级随 a2 走)。
  const release = serveRelease(await releasePayload("# apply-upgraded"));
  try {
    box.daemon = await startDaemon(box.home, {
      ...box.env,
      A2_FAKE_MIHOMO_VERSION: "v1.18.0",
      A2_MIHOMO_RELEASE_BASE: release.base,
      A2_MIHOMO_EXPECT_SHA256: release.sha256,
    });
    await waitFor("apply 换上了锁定版", async () =>
      (await readFile(box.managedBinary, "utf8")).includes("# apply-upgraded"));
  } finally {
    release.stop();
  }
}, 30000);

test("restart 的两道闸:daemon 不在 → 退出码 4;模式不是 embedded → mihomo_not_enabled", async () => {
  const box = (sandbox = await makeSandbox());

  const noDaemon = await mihomo(box, ["restart"]);
  expect(noDaemon.exitCode).toBe(4);
  expect(parseJsonStdout(noDaemon).error.code).toBe("daemon_unreachable");

  box.daemon = await startDaemon(box.home, box.env);
  const notEnabled = await mihomo(box, ["restart"]);
  expect(notEnabled.exitCode).toBe(5);
  const error = parseJsonStdout(notEnabled).error;
  expect(error.code).toBe("mihomo_not_enabled");
  const commands = error.guidance.steps.map((s: { command?: string }) => s.command);
  expect(commands).toContain("a2 mihomo enable --mode=embedded --json");
});

test("guidance 态 F/E:没节点先教配置(agent 直接改 YAML,无专用命令);有节点才提并跑", async () => {
  const box = (sandbox = await makeSandbox());
  await placeManagedBinary(box);
  await mihomo(box, ["enable", "--mode=embedded"]);
  box.daemon = await startDaemon(box.home, box.env);
  await waitRunning(box);

  // 态 F:默认骨架没有节点 → 教 agent 配置;第 2 步是纯 description(节点合并 CLI 已废案)。
  const empty = await waitRunning(box);
  expect(empty.guidance.summary).toContain("没有任何代理节点");
  const stepTexts = empty.guidance.steps.map((s: { description: string }) => s.description);
  expect(stepTexts.some((t: string) => t.includes("直接读改 YAML"))).toBe(true);
  const commands = empty.guidance.steps.map((s: { command?: string }) => s.command);
  expect(commands).toContain("a2 mihomo restart --json");

  // agent 把节点写进配置 + 外来实例也在跑 → 态 E:并跑提醒,「未经用户同意不要执行」。
  const config = await readFile(box.managedConfig, "utf8");
  // 替换骨架里的空 proxies(追加会造出重复键,而 hasProxies 只认第一个)。
  await writeFile(
    box.managedConfig,
    config.replace("proxies: []", "proxies:\n  - {name: n1, type: socks5, server: 1.2.3.4, port: 1080}"),
  );
  await startForeignInstance(box);
  await waitFor("并跑提醒出现", async () => {
    const status = await statusOf(box);
    return status.guidance?.summary?.includes("非 A2 管理") === true;
  });
  const coexist = await statusOf(box);
  expect(coexist.guidance.summary).toContain("同一时间只能指向一家");
  expect(coexist.guidance.steps[0].description).toContain("未经用户同意不要执行");
}, 30000);

// MARK: - 用法与元数据

test("mihomo 用法错:缺动作 / 未知动作 / 多余参数 / --mode 用错地方或取值非法,一律退出码 1", async () => {
  const box = (sandbox = await makeSandbox());
  for (const args of [[], ["nonsense"], ["status", "extra"], ["status", "--mode=off"], ["enable"], ["enable", "--mode=bogus"]]) {
    const result = await mihomo(box, args as string[]);
    expect(result.exitCode).toBe(1);
    expect(parseJsonStdout(result).error.code).toBe("usage");
  }
});

test("mihomo --help --json:写明托管模式三值、正文归 agent、升级随 a2 走、别人的只读不碰", async () => {
  const box = (sandbox = await makeSandbox());
  const result = await mihomo(box, ["--help"]);
  expect(result.exitCode).toBe(0);
  const usage = parseJsonStdout(result).result.usage as string;
  for (const needle of ["--mode=embedded", "--mode=observe", "disable", "restart", "正文归你与你的 agent", "升级随 a2 走", "只读不碰"]) {
    expect(usage).toContain(needle);
  }
});

test("扫描面默认值:配置只看 mihomo 自己的标准位置,二进制只看 PATH + 两个包管理器前缀", () => {
  const env = { PATH: "/usr/bin:/opt/x/bin", HOME: "/Users/alice", XDG_CONFIG_HOME: "" };
  expect(defaultBinaryDirs(env)).toEqual(["/usr/bin", "/opt/x/bin", "/usr/local/bin", "/opt/homebrew/bin"]);
  expect(defaultConfigFiles(env)).toEqual(["/Users/alice/.config/mihomo/config.yaml"]);
  expect(loopbackTarget("0.0.0.0:9090")).toBe("127.0.0.1:9090");
  expect(loopbackTarget("192.168.1.2:9090")).toBeUndefined();
  expect(readControllerFromConfig("external-controller: :7777\nsecret: 's'\n")).toEqual({
    controller: ":7777",
    secret: "s",
  });
});

test("锁版元数据与那份实测记录同源(换版本必须两处一起改)", async () => {
  const recorded = await readFile(path.resolve(import.meta.dir, "../contract/MIHOMO-VERSION.txt"), "utf8");
  const version = /v\d+\.\d+\.\d+/.exec(recorded)?.[0] ?? "(没解析出版本)";
  expect(MIHOMO_LOCKED_VERSION).toBe(version);
  expect(Object.keys(MIHOMO_ASSET_DIGESTS).length).toBeGreaterThan(0);
});
