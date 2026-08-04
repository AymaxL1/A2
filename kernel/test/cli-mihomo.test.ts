// CLI 缝(最高缝):`a2 mihomo status|install|uninstall|upgrade` 的行为契约。
//
// **这份文件的第一职责是守住施工红线**:本机跑着用户自己的 mihomo,而这里的每一个「mihomo」都是
// `support/fake-mihomo/` 里那个行为假件 —— 二进制搜索目录、配置搜索路径、发布渠道、自管控制端口
// 全部由环境变量注入到沙盒里,没有一条断言会去扫真系统面、连真端口、动真 unit。
// 假 supervisor 同样进 PATH 且被测进程的 PATH 只有它(真 launchctl/systemctl 在它眼里不存在)。
//
// 假件不是打桩:它按 unit 文件**真的把 mihomo 起起来**并**真的在回环上暴露 external-controller**,
// 所以链条是端到端的(install → 真进程 → GET /version 真答话 → status 报 running)。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, readdirSync } from "node:fs";
import { chmod, copyFile, lstat, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { MihomoChangeResultSchema, MihomoStatusResultSchema } from "../src/contract/wire.ts";
import {
  defaultBinaryDirs,
  defaultConfigFiles,
  loopbackTarget,
  readControllerFromConfig,
} from "../src/mihomo/paths.ts";
import { MIHOMO_ASSET_DIGESTS, MIHOMO_LOCKED_VERSION } from "../src/mihomo/pin.ts";
import { parseJsonStdout, runCli } from "./support/harness.ts";

const FAKE_SUPERVISOR_DIR = path.resolve(import.meta.dir, "support/fake-supervisor");
const FAKE_MIHOMO_SH = path.resolve(import.meta.dir, "support/fake-mihomo/mihomo");
const FAKE_MIHOMO_TS = path.resolve(import.meta.dir, "support/fake-mihomo/fake-mihomo.ts");
const KERNEL_LABEL = "com.a2.kernel";
const MIHOMO_LABEL = "com.a2.mihomo";

interface Sandbox {
  root: string;
  /** A2_HOME。 */
  home: string;
  stateDir: string;
  logPath: string;
  /** 注入的"别人的二进制"所在目录(默认是空的)。 */
  foreignBinDir: string;
  foreignBinary: string;
  /** 注入的"别人的配置"路径(默认不存在)。 */
  foreignConfig: string;
  /** a2 自管实例的控制端口(每个沙盒一个空闲端口)。 */
  controllerPort: number;
  /** `com.a2.mihomo` 的 plist **应该**落的位置(测试独立算出来的)。 */
  mihomoUnitPath: string;
  kernelUnitPath: string;
  managedBinary: string;
  managedConfig: string;
  env: Record<string, string>;
  /** 测试自己拉起的"别人的实例"(收编档用),afterEach 负责收尸。 */
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
    kernelUnitPath: path.join(root, "Library", "LaunchAgents", `${KERNEL_LABEL}.plist`),
    managedBinary: path.join(home, "mihomo", "bin", "mihomo"),
    managedConfig: path.join(home, "mihomo", "config.yaml"),
    env: {
      // 被测进程的 PATH 只有假 supervisor 目录 —— 真 launchctl 在它眼里不存在。
      PATH: FAKE_SUPERVISOR_DIR,
      HOME: root,
      XDG_CONFIG_HOME: path.join(root, "xdg"),
      A2_SERVICE_SUPERVISOR: "launchd",
      A2_FAKE_STATE_DIR: stateDir,
      A2_FAKE_LOG: logPath,
      // 假 mihomo 的两个必备旋钮(经 a2 → 假 supervisor → mihomo 进程逐层继承)。
      A2_FAKE_BUN: process.execPath,
      A2_FAKE_MIHOMO_TS: FAKE_MIHOMO_TS,
      // **扫描面全注入**:默认两处都指向空的沙盒位置,所以默认现状 = 全无。
      A2_MIHOMO_BIN_DIRS: foreignBinDir,
      A2_MIHOMO_CONFIG_FILES: path.join(foreignConfDir, "config.yaml"),
      A2_MIHOMO_CONTROLLER_PORT: String(controllerPort),
    },
  };
}

async function mihomo(box: Sandbox, args: string[], extraEnv: Record<string, string> = {}) {
  return await runCli(["mihomo", ...args, "--json"], {
    home: box.home,
    env: { ...box.env, ...extraEnv },
  });
}

async function service(box: Sandbox, args: string[]) {
  return await runCli(["service", ...args, "--json"], { home: box.home, env: box.env });
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

/** 把假 mihomo 放进"别人的 bin 目录"(真文件,不是链接 —— 复用档的复用对象)。 */
async function installForeignBinary(box: Sandbox): Promise<void> {
  await copyFile(FAKE_MIHOMO_SH, box.foreignBinary);
  await chmod(box.foreignBinary, 0o755);
}

/**
 * 起一个「别人托管的」mihomo 实例:配置由测试写,进程由**测试自己**拉起 ——
 * 它不在任何 a2 的 unit 里,正是收编档要面对的那种实例。
 */
async function startForeignInstance(
  box: Sandbox,
  options: { version?: string; secret?: string; controller?: string } = {},
): Promise<{ port: number; controller: string }> {
  const port = await freePort();
  const controller = options.controller ?? `127.0.0.1:${port}`;
  const secret = options.secret ?? "s3cr3t-foreign";
  await writeFile(
    box.foreignConfig,
    ["mixed-port: 7890", "mode: rule", `external-controller: ${controller}`, `secret: ${secret}`, ""].join("\n"),
  );
  await installForeignBinary(box);
  const proc = Bun.spawn({
    cmd: [box.foreignBinary, "-d", path.dirname(box.foreignConfig), "-f", box.foreignConfig],
    env: {
      ...process.env,
      A2_FAKE_BUN: process.execPath,
      A2_FAKE_MIHOMO_TS: FAKE_MIHOMO_TS,
      ...(options.version ? { A2_FAKE_MIHOMO_VERSION: options.version } : {}),
    },
    stdout: "ignore",
    stderr: "ignore",
    stdin: "ignore",
  });
  box.foreignProc = proc;
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
  return {
    base: `http://127.0.0.1:${server.port ?? 0}`,
    sha256,
    stop: () => server.stop(true),
  };
}

/** 下载档的"资产"就是假 mihomo 那个 sh 壳本身 —— 落位之后 unit 才真起得来。 */
async function releasePayload(suffix = ""): Promise<string> {
  return `${await Bun.file(FAKE_MIHOMO_SH).text()}${suffix}`;
}

beforeEach(() => {
  sandbox = undefined;
});

afterEach(async () => {
  if (!sandbox) return;
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
  // 兜底:假件起的是真进程,而测试中途失败时状态文件未必是最新的。
  // 沙盒根是本次独有的临时路径,按它精确回收 —— 不可能误伤任何别的进程(尤其是用户自己的 mihomo)。
  Bun.spawnSync({ cmd: ["/usr/bin/pkill", "-9", "-f", sandbox.root], stdout: "ignore", stderr: "ignore" });
  await rm(sandbox.root, { recursive: true, force: true });
  sandbox = undefined;
});

// MARK: - 检测(机读报告)

test("mihomo status:本机全无 → presence=absent、档位=脚本安装,退出码 0 且只读(什么都不建)", async () => {
  const box = (sandbox = await makeSandbox());

  const result = await mihomo(box, ["status"]);

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(true);
  expect(MihomoStatusResultSchema.safeParse(body.result).success).toBe(true);
  expect(body.result.presence).toBe("absent");
  expect(body.result.rung).toBe("managed_install");
  expect(body.result.provisioned).toBe(false);
  expect(body.result.instance).toBeUndefined();
  expect(body.result.foreignBinary).toBeUndefined();
  // 未就位时也要给出"就位会写到哪儿"——agent 不必猜。
  expect(body.result.managed.label).toBe(MIHOMO_LABEL);
  expect(body.result.managed.unitPath).toBe(box.mihomoUnitPath);
  expect(body.result.managed.unitInstalled).toBe(false);
  expect(body.result.managed.state).toBe("not_installed");
  expect(body.result.managed.binaryKind).toBe("absent");
  expect(body.result.managed.binaryPath).toBe(box.managedBinary);
  expect(body.result.managed.controller).toBe(`127.0.0.1:${box.controllerPort}`);
  expect(body.result.lockedVersion).toBe(MIHOMO_LOCKED_VERSION);
  // 只读:查一次不会凭空造出任何东西。
  expect(existsSync(box.mihomoUnitPath)).toBe(false);
  expect(existsSync(path.join(box.home, "mihomo"))).toBe(false);
});

test("mihomo status:只有二进制 → presence=binary_only、档位=只读复用,并报出它的版本", async () => {
  const box = (sandbox = await makeSandbox());
  await installForeignBinary(box);

  const body = parseJsonStdout(await mihomo(box, ["status"], { A2_FAKE_MIHOMO_VERSION: "v1.19.28" }));

  expect(body.result.presence).toBe("binary_only");
  expect(body.result.rung).toBe("reuse_binary");
  expect(body.result.foreignBinary.path).toBe(box.foreignBinary);
  expect(body.result.foreignBinary.version).toBe("v1.19.28");
  expect(body.result.compatibility.meets).toBe(true);
  expect(body.result.compatibility.floor).toBe("1.19.0");
});

test("mihomo status:跑着别人的实例 → presence=running_instance、档位=收编,能力位三条都是探出来的", async () => {
  const box = (sandbox = await makeSandbox());
  const foreign = await startForeignInstance(box, { version: "v1.19.28" });

  const body = parseJsonStdout(await mihomo(box, ["status"]));

  expect(body.result.presence).toBe("running_instance");
  expect(body.result.rung).toBe("adopt_instance");
  expect(body.result.instance.owner).toBe("foreign");
  expect(body.result.instance.controller).toBe(`127.0.0.1:${foreign.port}`);
  expect(body.result.instance.secretConfigured).toBe(true);
  expect(body.result.instance.version).toBe("v1.19.28");
  expect(body.result.instance.capabilities.sort()).toEqual([
    "configs_read",
    "meta_core",
    "rest_api",
  ]);
  expect(body.result.instance.configFile).toBe(box.foreignConfig);
  expect(body.result.compatibility.meets).toBe(true);
});

test("mihomo status:配置里的 external-controller 不是回环 → 有意不探,如实报告并降回二进制档", async () => {
  const box = (sandbox = await makeSandbox());
  await installForeignBinary(box);
  await writeFile(
    box.foreignConfig,
    ["external-controller: 192.168.1.10:9090", "secret: nope", ""].join("\n"),
  );

  const body = parseJsonStdout(await mihomo(box, ["status"]));

  // 内核对非本机端点一个字节都不发 —— 所以它不构成"跑着的实例"。
  expect(body.result.skippedController).toBe("192.168.1.10:9090");
  expect(body.result.presence).toBe("binary_only");
  expect(body.result.rung).toBe("reuse_binary");
  expect(body.result.instance).toBeUndefined();
});

// MARK: - ① 收编档(生命周期归原托管方)

test("mihomo install:收编档只记一笔收编、什么都不装,那个实例的 pid 全程没被碰过", async () => {
  const box = (sandbox = await makeSandbox());
  const foreign = await startForeignInstance(box, { version: "v1.19.28" });
  const foreignPid = box.foreignProc!.pid;

  const result = await mihomo(box, ["install"]);

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(MihomoChangeResultSchema.safeParse(body.result).success).toBe(true);
  // 收编档唯一的动作是"记下我收编的是谁"——落的是 a2 自己 home 里的一个小记录。
  expect(body.result.actions).toEqual(["adoption_recorded"]);
  expect(body.result.status.rung).toBe("adopt_instance");
  expect(body.result.status.provisioned).toBe(true);
  expect(body.result.status.instance.owner).toBe("foreign");
  expect(body.result.status.instance.controller).toBe(`127.0.0.1:${foreign.port}`);
  // **绝不越权**:没有 unit、没有自管二进制,别人的进程活得好好的。
  expect(existsSync(box.mihomoUnitPath)).toBe(false);
  expect(existsSync(box.managedBinary)).toBe(false);
  expect(isAlive(foreignPid)).toBe(true);
  // supervisor 那边只发生过只读的 print(没有任何一条改状态的命令)。
  const calls = await supervisorCalls(box);
  expect(calls.every((call) => call.startsWith("launchctl print "))).toBe(true);
  // 幂等:第二次什么都不改。
  expect(parseJsonStdout(await mihomo(box, ["install"])).result.actions).toEqual([]);
  expect(isAlive(foreignPid)).toBe(true);
}, 20000);

test("mihomo install:收编对象不达兼容地板 → 结构化拒绝 + 退出码 5,不擅自升级、不擅自并存", async () => {
  const box = (sandbox = await makeSandbox());
  await startForeignInstance(box, { version: "v1.10.0" });
  const foreignPid = box.foreignProc!.pid;

  const result = await mihomo(box, ["install"]);

  expect(result.exitCode).toBe(5);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(false);
  expect(body.error.code).toBe("mihomo_below_floor");
  expect(body.error.detail).toContain("version_below_floor");
  // 拒绝即指引:两条明路,一条是人类自己升级,一条是显式隔离安装。
  const commands = body.error.guidance.steps.map((step: { command?: string }) => step.command);
  expect(commands).toContain("a2 mihomo install --isolated");
  expect(commands).toContain("a2 mihomo status --json");
  // 不擅自升级 = 那个实例原样活着;不擅自并存 = 没偷偷装 a2 自己那份。
  expect(isAlive(foreignPid)).toBe(true);
  expect(existsSync(box.mihomoUnitPath)).toBe(false);
  expect(existsSync(box.managedBinary)).toBe(false);
});

test("mihomo install:被收编的实例死了 → 报警 + 指引(含人类可执行的重启命令),内核绝不重拉", async () => {
  const box = (sandbox = await makeSandbox());
  await startForeignInstance(box, { version: "v1.19.28" });
  // 先真的收编一次 —— 有了这笔记录,"我收编的那个实例死了"才是一句有主语的话
  // (否则内核无从区分它与"这台机器上本来就没有跑着的 mihomo")。
  expect(parseJsonStdout(await mihomo(box, ["install"])).result.actions).toEqual([
    "adoption_recorded",
  ]);
  const foreignPid = box.foreignProc!.pid;
  box.foreignProc!.kill("SIGKILL");
  await box.foreignProc!.exited;
  await waitFor("别人的实例真的没了", () => !isAlive(foreignPid));

  const result = await mihomo(box, ["install"]);

  expect(result.exitCode).toBe(5);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("mihomo_unreachable");
  expect(body.error.guidance.summary).toContain("原托管方");
  const commands: string[] = body.error.guidance.steps.map((s: { command?: string }) => s.command);
  // 「人类可执行的重启命令」是从检测到的事实拼出来的,原样可敲。
  expect(commands).toContain(
    `${box.foreignBinary} -d ${path.dirname(box.foreignConfig)} -f ${box.foreignConfig}`,
  );
  expect(commands).toContain("a2 mihomo install --isolated");
  // 内核没有替它重拉:没装任何 unit,也没对 supervisor 发过任何改状态的命令。
  expect(existsSync(box.mihomoUnitPath)).toBe(false);
  const calls = await supervisorCalls(box);
  expect(calls.every((call) => call.startsWith("launchctl print "))).toBe(true);
  // status 也如实降级:档位仍是收编(我盯着的还是那个端点),但能力位一条都探不到。
  const statusResult = await mihomo(box, ["status"]);
  expect(statusResult.exitCode).toBe(0);
  const status = parseJsonStdout(statusResult);
  expect(status.result.rung).toBe("adopt_instance");
  expect(status.result.instance.capabilities).toEqual([]);
  expect(status.result.compatibility.shortfalls).toContain("rest_api_unreachable");
}, 20000);

// MARK: - ② 只读复用档

test("mihomo install:复用档 —— 落点是指向真身的符号链接、配置/数据自建、unit 起得来且控制面通", async () => {
  const box = (sandbox = await makeSandbox());
  await installForeignBinary(box);
  const before = await readFile(box.foreignBinary, "utf8");

  const result = await mihomo(box, ["install"], { A2_FAKE_MIHOMO_VERSION: "v1.19.28" });

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.result.actions).toEqual([
    "data_dir_created",
    "config_written",
    "binary_linked",
    "unit_written",
    "supervisor_loaded",
  ]);
  expect(body.result.status.rung).toBe("reuse_binary");
  expect(body.result.status.provisioned).toBe(true);
  expect(body.result.status.managed.binaryKind).toBe("reused");
  expect(body.result.status.managed.binaryTarget).toBe(box.foreignBinary);
  expect(body.result.status.managed.state).toBe("running");
  expect(isAlive(body.result.status.managed.pid)).toBe(true);
  // 「只读复用」的字面意思:落点是符号链接,真身一个字节都没变。
  expect((await lstat(box.managedBinary)).isSymbolicLink()).toBe(true);
  expect(await readFile(box.foreignBinary, "utf8")).toBe(before);
  // 配置与数据目录是 a2 自建的,且 secret 真的写进去了。
  const config = await readFile(box.managedConfig, "utf8");
  expect(readControllerFromConfig(config)?.controller).toBe(`127.0.0.1:${box.controllerPort}`);
  expect(readControllerFromConfig(config)?.secret).toBeTruthy();
  // unit 是 com.a2.mihomo 那一个,自愈自启键齐全(杀了由系统重拉这条承诺就落在这儿)。
  const plist = await readFile(box.mihomoUnitPath, "utf8");
  expect(plist).toContain(`<string>${MIHOMO_LABEL}</string>`);
  expect(plist).toMatch(/<key>KeepAlive<\/key>\s*<dict>\s*<key>Crashed<\/key>\s*<true\/>/);
  expect(plist).toMatch(/<key>RunAtLoad<\/key>\s*<true\/>/);
  expect(plist).toContain(`<string>${box.managedBinary}</string>`);
  // **就位 = 控制面真的通**:紧接着一条 status 必须报 running_instance 且 owner=a2。
  const status = parseJsonStdout(await mihomo(box, ["status"]));
  expect(status.result.presence).toBe("running_instance");
  expect(status.result.instance.owner).toBe("a2");
  expect(status.result.instance.capabilities).toContain("rest_api");
}, 20000);

test("mihomo install 幂等:第二次什么都不改(actions 空),且不再对 supervisor 发改状态的命令", async () => {
  const box = (sandbox = await makeSandbox());
  await installForeignBinary(box);
  await mihomo(box, ["install"], { A2_FAKE_MIHOMO_VERSION: "v1.19.28" });
  const callsAfterFirst = (await supervisorCalls(box)).length;

  const second = parseJsonStdout(await mihomo(box, ["install"], { A2_FAKE_MIHOMO_VERSION: "v1.19.28" }));

  expect(second.result.actions).toEqual([]);
  expect(second.result.status.managed.state).toBe("running");
  const added = (await supervisorCalls(box)).slice(callsAfterFirst);
  expect(added.every((call) => call.startsWith("launchctl print "))).toBe(true);
});

test("mihomo install:复用对象不达地板 → 回退隔离安装并在报文里说明原因", async () => {
  const box = (sandbox = await makeSandbox());
  await installForeignBinary(box);

  const body = parseJsonStdout(
    await mihomo(box, ["status"], { A2_FAKE_MIHOMO_VERSION: "v1.10.0" }),
  );

  expect(body.result.rung).toBe("managed_install");
  expect(body.result.fallback.from).toBe("reuse_binary");
  expect(body.result.fallback.shortfalls).toEqual(["version_below_floor"]);
  expect(body.result.fallback.reason).toContain("不达兼容地板");
  // 回退之后判的是锁定版,当然达标 —— 但"为什么回退"必须留在报文里。
  expect(body.result.compatibility.meets).toBe(true);
  expect(body.result.compatibility.version).toBe(MIHOMO_LOCKED_VERSION);
});

// MARK: - ③ 脚本安装档(锁定版 + 摘要校验)

test("mihomo install:脚本安装档 —— 按锁定版下载、校验 SHA-256、落位可执行,再挂 unit 起起来", async () => {
  const box = (sandbox = await makeSandbox());
  const release = serveRelease(await releasePayload());
  try {
    const result = await mihomo(box, ["install"], {
      A2_MIHOMO_RELEASE_BASE: release.base,
      A2_MIHOMO_EXPECT_SHA256: release.sha256,
      A2_FAKE_MIHOMO_VERSION: MIHOMO_LOCKED_VERSION,
    });

    expect(result.exitCode).toBe(0);
    const body = parseJsonStdout(result);
    expect(body.result.actions).toEqual([
      "data_dir_created",
      "config_written",
      "binary_downloaded",
      "unit_written",
      "supervisor_loaded",
    ]);
    expect(body.result.status.managed.binaryKind).toBe("downloaded");
    expect(body.result.status.managed.state).toBe("running");
    expect(body.result.status.managed.version).toBe(MIHOMO_LOCKED_VERSION);
    // 落位的是真文件(不是链接)、可执行,且内容正是渠道给的那份。
    const placed = await lstat(box.managedBinary);
    expect(placed.isSymbolicLink()).toBe(false);
    expect(placed.mode & 0o111).not.toBe(0);
    expect(await readFile(box.managedBinary, "utf8")).toBe(await releasePayload());
    // 中间态不留:临时下载文件不该还躺在那儿。
    expect(existsSync(`${box.managedBinary}.download`)).toBe(false);
  } finally {
    release.stop();
  }
});

test("mihomo install:摘要对不上就 fail-closed —— 退出码 5,且落点上一个字节都没写", async () => {
  const box = (sandbox = await makeSandbox());
  // 有意**不**给 A2_MIHOMO_EXPECT_SHA256:走 pin.ts 里那张真摘要表,与假资产必然不符
  // (本平台没登记摘要时同样 fail-closed —— 两条分支都是"没有可信摘要就不装")。
  const release = serveRelease(await releasePayload("\n# 冒牌货\n"));
  try {
    const result = await mihomo(box, ["install"], { A2_MIHOMO_RELEASE_BASE: release.base });

    expect(result.exitCode).toBe(5);
    const body = parseJsonStdout(result);
    expect(body.ok).toBe(false);
    expect(body.error.code).toBe("mihomo_operation_failed");
    expect(body.error.guidance.steps.length).toBeGreaterThan(0);
    // **不落半成品**:校验在写盘之前,失败时落点与暂存文件都不存在。
    expect(existsSync(box.managedBinary)).toBe(false);
    expect(existsSync(`${box.managedBinary}.download`)).toBe(false);
    expect(existsSync(box.mihomoUnitPath)).toBe(false);
  } finally {
    release.stop();
  }
});

// MARK: - 升级永远显式

test("升级永远显式:install 绝不换版本,只有 upgrade 会换(换完还要把进程重启到新二进制上)", async () => {
  const box = (sandbox = await makeSandbox());
  const first = serveRelease(await releasePayload());
  let installedPid = 0;
  try {
    const installed = parseJsonStdout(
      await mihomo(box, ["install"], {
        A2_MIHOMO_RELEASE_BASE: first.base,
        A2_MIHOMO_EXPECT_SHA256: first.sha256,
        // 装成一个**低于锁定版**的版本,好让"升级到锁定版"这件事有实际内容。
        A2_FAKE_MIHOMO_VERSION: "v1.19.20",
      }),
    );
    expect(installed.result.status.managed.version).toBe("v1.19.20");
    installedPid = installed.result.status.managed.pid;
  } finally {
    first.stop();
  }
  const originalBytes = await readFile(box.managedBinary, "utf8");

  // 渠道上已经躺着一份**不同的**资产了 —— 再跑一次 install 必须视而不见。
  const second = serveRelease(await releasePayload("\n# 新版本\n"));
  try {
    const again = parseJsonStdout(
      await mihomo(box, ["install"], {
        A2_MIHOMO_RELEASE_BASE: second.base,
        A2_MIHOMO_EXPECT_SHA256: second.sha256,
        A2_FAKE_MIHOMO_VERSION: "v1.19.20",
      }),
    );
    expect(again.result.actions).toEqual([]);
    expect(await readFile(box.managedBinary, "utf8")).toBe(originalBytes);
    expect(again.result.status.managed.pid).toBe(installedPid);

    // 显式命令才换,而且换完必须把进程也换到新二进制上(否则跑的还是旧 inode)。
    const upgraded = parseJsonStdout(
      await mihomo(box, ["upgrade"], {
        A2_MIHOMO_RELEASE_BASE: second.base,
        A2_MIHOMO_EXPECT_SHA256: second.sha256,
        A2_FAKE_MIHOMO_VERSION: "v1.19.20",
      }),
    );
    expect(upgraded.result.actions).toEqual(["binary_upgraded", "mihomo_restarted"]);
    expect(await readFile(box.managedBinary, "utf8")).toBe(await releasePayload("\n# 新版本\n"));
    expect(upgraded.result.status.managed.pid).not.toBe(installedPid);
    await waitFor("旧 mihomo 进程退出", () => !isAlive(installedPid));
  } finally {
    second.stop();
  }
}, 30000);

test("mihomo upgrade:收编档没有可升级的对象 → mihomo_not_managed(内核不替别人升级)", async () => {
  const box = (sandbox = await makeSandbox());
  await startForeignInstance(box, { version: "v1.19.28" });
  await mihomo(box, ["install"]);

  const result = await mihomo(box, ["upgrade"]);

  expect(result.exitCode).toBe(5);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("mihomo_not_managed");
  const commands = body.error.guidance.steps.map((step: { command?: string }) => step.command);
  expect(commands).toContain("a2 mihomo install --isolated");
  expect(isAlive(box.foreignProc!.pid)).toBe(true);
}, 20000);

test("mihomo upgrade:只读复用档同样拒绝 —— 那份二进制不是内核装的,一个字节都不改", async () => {
  const box = (sandbox = await makeSandbox());
  await installForeignBinary(box);
  const before = await readFile(box.foreignBinary, "utf8");
  await mihomo(box, ["install"], { A2_FAKE_MIHOMO_VERSION: "v1.19.28" });

  const result = await mihomo(box, ["upgrade"], { A2_FAKE_MIHOMO_VERSION: "v1.19.28" });

  expect(result.exitCode).toBe(5);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("mihomo_not_managed");
  expect(body.error.detail).toContain(box.foreignBinary);
  expect(await readFile(box.foreignBinary, "utf8")).toBe(before);
  expect((await lstat(box.managedBinary)).isSymbolicLink()).toBe(true);
}, 20000);

// MARK: - 数据面不随控制面起落

test("数据面不随控制面起落:卸掉内核不动 mihomo(unit 还在、pid 没变);卸 mihomo 也不动内核", async () => {
  const box = (sandbox = await makeSandbox());
  await installForeignBinary(box);
  await service(box, ["install"]);
  const installed = parseJsonStdout(await mihomo(box, ["install"], { A2_FAKE_MIHOMO_VERSION: "v1.19.28" }));
  const mihomoPid = installed.result.status.managed.pid;
  expect(isAlive(mihomoPid)).toBe(true);

  // 控制面整个卸掉。
  const uninstalled = await service(box, ["uninstall"]);
  expect(uninstalled.exitCode).toBe(0);
  expect(existsSync(box.kernelUnitPath)).toBe(false);

  // 数据面纹丝不动:unit 还在、进程还是同一个 pid、控制端点照样答话。
  expect(existsSync(box.mihomoUnitPath)).toBe(true);
  expect(isAlive(mihomoPid)).toBe(true);
  const after = parseJsonStdout(await mihomo(box, ["status"], { A2_FAKE_MIHOMO_VERSION: "v1.19.28" }));
  expect(after.result.managed.state).toBe("running");
  expect(after.result.managed.pid).toBe(mihomoPid);
  expect(after.result.instance.owner).toBe("a2");

  // 反过来也一样:卸 mihomo 只卸它自己,内核那份该在还在(此刻内核已卸,断言的是 mihomo 侧干净移除)。
  const removed = parseJsonStdout(await mihomo(box, ["uninstall"]));
  expect(removed.result.actions).toEqual(["supervisor_unloaded", "unit_removed"]);
  expect(existsSync(box.mihomoUnitPath)).toBe(false);
  await waitFor("mihomo 进程退出", () => !isAlive(mihomoPid));
  // **有意保留**数据面资产:配置与数据目录还在(删不删由人类决定)。
  expect(existsSync(box.managedConfig)).toBe(true);
  // 幂等:再卸一次什么都不做。
  expect(parseJsonStdout(await mihomo(box, ["uninstall"])).result.actions).toEqual([]);
}, 30000);

test("红线:整场对 supervisor 说过的话,目标只有 com.a2.kernel 与 com.a2.mihomo 两个 label", async () => {
  const box = (sandbox = await makeSandbox());
  await startForeignInstance(box, { version: "v1.19.28" });
  await mihomo(box, ["status"]);
  await mihomo(box, ["install"]);
  await service(box, ["install"]);
  await mihomo(box, ["install", "--isolated"], {
    A2_MIHOMO_RELEASE_BASE: "http://127.0.0.1:1/never",
  });
  await mihomo(box, ["uninstall"]);
  await service(box, ["uninstall"]);

  const calls = await supervisorCalls(box);
  expect(calls.length).toBeGreaterThan(0);
  const domain = `gui/${process.getuid?.()}`;
  for (const call of calls) {
    expect(call.startsWith("launchctl ")).toBe(true);
    const ours =
      call.includes(`${domain}/${KERNEL_LABEL}`) ||
      call.includes(`${domain}/${MIHOMO_LABEL}`) ||
      call === `launchctl bootstrap ${domain} ${box.kernelUnitPath}` ||
      call === `launchctl bootstrap ${domain} ${box.mihomoUnitPath}`;
    expect(ours).toBe(true);
  }
  // 别人的实例活到最后一刻(全程没有任何一条命令能碰到它 —— 它压根不在任何 unit 里)。
  expect(isAlive(box.foreignProc!.pid)).toBe(true);
}, 40000);

// MARK: - 用法面

test("mihomo 用法错:缺动作 / 未知动作 / 多余参数 / --isolated 用错地方,一律退出码 1 + 本面指引", async () => {
  const box = (sandbox = await makeSandbox());

  for (const args of [[] as string[], ["restart"], ["status", "extra"], ["status", "--isolated"]]) {
    const result = await runCli(["mihomo", ...args, "--json"], { home: box.home, env: box.env });
    expect(result.exitCode).toBe(1);
    const body = parseJsonStdout(result);
    expect(body.error.code).toBe("usage");
    const commands = body.error.guidance.steps.map((step: { command?: string }) => step.command);
    expect(commands).toContain("a2 mihomo --help");
  }
  // 用法错不该碰 supervisor 一下。
  expect(await supervisorCalls(box)).toEqual([]);
});

test("mihomo --help --json:帮助进 result,写明三档阶梯、两个 unit 独立、升级永远显式", async () => {
  const box = (sandbox = await makeSandbox());

  const result = await mihomo(box, ["--help"]);

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.result.usage).toContain("adopt_instance");
  expect(body.result.usage).toContain("reuse_binary");
  expect(body.result.usage).toContain("managed_install");
  expect(body.result.usage).toContain(MIHOMO_LABEL);
  expect(body.result.usage).toContain("a2 mihomo upgrade");
});

// MARK: - 扫描面的默认值(纯计算,不碰文件系统)

test("扫描面默认值:配置只看 mihomo 自己的标准位置,二进制只看 PATH + 两个包管理器前缀", () => {
  // 默认列表是纯函数算出来的,所以能在不触碰本机任何路径的前提下断言它的内容。
  expect(defaultConfigFiles({ HOME: "/home/alice" })).toEqual([
    "/home/alice/.config/mihomo/config.yaml",
  ]);
  expect(defaultConfigFiles({ HOME: "/home/alice", XDG_CONFIG_HOME: "/cfg" })).toEqual([
    "/cfg/mihomo/config.yaml",
  ]);
  expect(defaultBinaryDirs({ PATH: "/a:/b" })).toEqual([
    "/a",
    "/b",
    "/usr/local/bin",
    "/opt/homebrew/bin",
  ]);
  // 只连回环:非回环一律返回 undefined(内核据此跳过探测)。
  expect(loopbackTarget("127.0.0.1:9090")).toBe("127.0.0.1:9090");
  expect(loopbackTarget("0.0.0.0:9090")).toBe("127.0.0.1:9090");
  expect(loopbackTarget(":9090")).toBe("127.0.0.1:9090");
  expect(loopbackTarget("192.168.1.10:9090")).toBeUndefined();
  expect(loopbackTarget("example.com:9090")).toBeUndefined();
});

test("锁版元数据与旧仓那份实测记录同源(换版本必须两处一起改)", async () => {
  // 唯一有实测背书的版本与摘要来自旧仓随包分发过的那份内核。两处对不上就说明有人单方面改了锁版。
  const recorded = await Bun.file(
    path.resolve(import.meta.dir, "../../Sources/PluginProxy/Resources/MIHOMO-VERSION.txt"),
  ).text();
  expect(recorded).toContain(MIHOMO_LOCKED_VERSION);
  expect(recorded).toContain(MIHOMO_ASSET_DIGESTS["darwin-arm64"] as string);
});
