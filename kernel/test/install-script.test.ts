// `Scripts/install.sh` —— curl 安装脚本的行为断言(13 票)。
//
// ============================================================================
// 被测体是**真的那个脚本**,发布渠道是**本机回环上的假渠道**
// ============================================================================
// 仓库无 remote、无发布渠道(13 票如实记账),所以"下载"这件事用两种本地夹具验:
//   ① 127.0.0.1 上的 `Bun.serve`(走 curl 的真实代码路径,与旗舰 e2e 的假 mihomo 同一种姿势);
//   ② 一个本地目录当 base(离线/内网分发那条路)。
// 元数据由**产品代码自己**生成(`src/release/manifest.ts`)—— 于是"脚本解不解得开我们生成的
// 那份 JSON"是被真的验过的,而不是靠两边手写同一种格式然后互相祝福。
//
// ============================================================================
// 纪律
// ============================================================================
//   * 一律临时目录:安装落点、HOME、A2_HOME 全在 /tmp 下,用户的 `~/.local/bin` 一个字节不碰;
//   * 不出网:`no_proxy` 钉死,资产只从回环或本地目录取;
//   * 不 launchctl:卸载路径的"服务还挂着吗"判据是**文件在不在**,不调任何 supervisor。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { chmodSync, existsSync, readFileSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  RELEASE_METADATA_FILE,
  buildReleaseManifest,
  renderReleaseManifest,
} from "../src/release/manifest.ts";

const INSTALLER = path.resolve(import.meta.dir, "../../Scripts/install.sh");

let box: string;
/** 假发布包(渠道的内容)。 */
let release: string;
/** 安装落点。 */
let installDir: string;
/** 假 HOME(卸载路径要看 `~/Library/LaunchAgents` 之类)。 */
let fakeHome: string;
let server: ReturnType<typeof Bun.serve> | undefined;
/** 每个路径被取过几次 —— "幂等重跑不下载"这条断言靠它。 */
let hits: Record<string, number>;

beforeEach(async () => {
  box = await mkdtemp("/tmp/a2inst-");
  release = path.join(box, "release");
  installDir = path.join(box, "bin");
  fakeHome = path.join(box, "home");
  await mkdir(release, { recursive: true });
  await mkdir(fakeHome, { recursive: true });
  hits = {};
  server = undefined;
});

afterEach(async () => {
  server?.stop(true);
  await rm(box, { recursive: true, force: true });
});

// MARK: - 夹具

/** 一个"能自报版本"的假 a2(安装脚本会 chmod + 跑一次 `a2 version` 自检)。 */
function fakeBinSource(version: string, marker: string): string {
  return `#!/bin/sh
# 假 a2(${marker})—— 只实现安装脚本会用到的那一条:自报版本。
case "$1" in
  version) echo "${version}" ;;
  *) echo "假 a2:未实现 $*" >&2; exit 1 ;;
esac
`;
}

interface ReleaseOptions {
  /** 要放哪些平台的内核 bin(默认本机那个平台键 darwin-arm64 + linux-x64)。 */
  platforms?: string[];
  version?: string;
  marker?: string;
}

/** 摆一个假发布包:内核 bin(每平台一份)+ 声明文本 + GPL 全文 + 安装脚本 + 元数据。 */
async function writeRelease(options: ReleaseOptions = {}): Promise<void> {
  const version = options.version ?? "0.1.0";
  const marker = options.marker ?? "v1";
  for (const platform of options.platforms ?? ["darwin-arm64", "linux-x64"]) {
    await writeFile(
      path.join(release, `a2-${platform}`),
      fakeBinSource(version, `${marker}/${platform}`),
      "utf8",
    );
  }
  await writeFile(path.join(release, "NOTICE-external-programs.txt"), "外部程序声明(夹具)\n");
  await writeFile(path.join(release, "LICENSE-mihomo-GPL-3.0.txt"), "GPL-3.0 全文(夹具)\n");
  await writeFile(path.join(release, "install.sh"), readFileSync(INSTALLER, "utf8"));
  const manifest = await buildReleaseManifest({ dir: release, version });
  await writeFile(path.join(release, RELEASE_METADATA_FILE), renderReleaseManifest(manifest));
}

/** 回环上的假发布渠道。返回 base 地址。 */
function serveRelease(): string {
  server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      const name = new URL(request.url).pathname.replace(/^\//, "");
      hits[name] = (hits[name] ?? 0) + 1;
      const file = Bun.file(path.join(release, name));
      if (!(await file.exists())) return new Response("not found", { status: 404 });
      return new Response(file);
    },
  });
  return `http://127.0.0.1:${server.port}`;
}

interface RunOptions {
  base?: string;
  home?: string;
  a2Home?: string;
  /** 假 uname 的输出(平台探测的被测面)。 */
  uname?: { s: string; m: string };
  /** 追加到 PATH 前面的目录。 */
  path?: string;
  extraEnv?: Record<string, string>;
}

interface RunResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

/**
 * 跑一次安装脚本。
 *
 * 平台探测用**假 `uname`**(PATH 前置一个目录),而不是给脚本加一个"仅测试用"的环境变量 ——
 * 被测的就该是用户机器上跑的那条代码路径。这与 05 票用假 supervisor 是同一种安排。
 */
async function runInstaller(args: string[], options: RunOptions = {}): Promise<RunResult> {
  let pathPrefix = options.path ?? "";
  if (options.uname) {
    const dir = path.join(box, `uname-${crypto.randomUUID()}`);
    await mkdir(dir, { recursive: true });
    const fake = path.join(dir, "uname");
    await writeFile(
      fake,
      `#!/bin/sh\ncase "$1" in\n  -s) echo "${options.uname.s}" ;;\n  -m) echo "${options.uname.m}" ;;\n  *) echo "${options.uname.s}" ;;\nesac\n`,
      "utf8",
    );
    chmodSync(fake, 0o755);
    pathPrefix = pathPrefix.length > 0 ? `${dir}:${pathPrefix}` : dir;
  }
  const basePath = process.env.PATH ?? "/usr/bin:/bin";
  const proc = Bun.spawn({
    cmd: ["sh", INSTALLER, ...args],
    env: {
      PATH: pathPrefix.length > 0 ? `${pathPrefix}:${basePath}` : basePath,
      HOME: options.home ?? fakeHome,
      A2_INSTALL_DIR: installDir,
      ...(options.base === undefined ? {} : { A2_RELEASE_BASE: options.base }),
      ...(options.a2Home === undefined ? {} : { A2_HOME: options.a2Home }),
      // 回环不许走用户的代理(a2 自己就是个代理管理器,测试更不能借道它)。
      no_proxy: "*",
      NO_PROXY: "*",
      TMPDIR: box,
      ...options.extraEnv,
    },
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  await proc.exited;
  return { exitCode: proc.exitCode ?? -1, stdout, stderr };
}

const installedBin = () => path.join(installDir, "a2");

// MARK: - 主线:装上、可执行、指引给全

test("HTTP 渠道装一次:bin 落位、可执行、内容逐字节等于渠道上那一份", async () => {
  await writeRelease();
  const base = serveRelease();

  const result = await runInstaller([], { base, uname: { s: "Darwin", m: "arm64" } });

  expect(result.exitCode).toBe(0);
  expect(existsSync(installedBin())).toBe(true);
  expect(readFileSync(installedBin(), "utf8")).toBe(
    readFileSync(path.join(release, "a2-darwin-arm64"), "utf8"),
  );
  // 装完真能跑(脚本自己也做了这一步自检)。
  const proc = Bun.spawn({ cmd: [installedBin(), "version"], stdout: "pipe" });
  expect((await new Response(proc.stdout).text()).trim()).toBe("0.1.0");
});

test("**下一步指引**:结束时打出 a2 service install(以及 mihomo 与 about 两条)", async () => {
  await writeRelease();
  const base = serveRelease();

  const result = await runInstaller([], { base, uname: { s: "Darwin", m: "arm64" } });

  expect(result.stdout).toContain("a2 service install");
  expect(result.stdout).toContain("a2 mihomo install");
  expect(result.stdout).toContain("a2 about");
  // 05 票交接单点名要的那句:换了 bin 位置就重跑 service install。
  expect(result.stdout).toContain("换了 bin 的位置就重跑 a2 service install");
  // 无静默更新这条口径必须出现在用户眼前,不能只写在文档里。
  expect(result.stdout).toContain("升级永远显式");
  // 锁版版本从元数据里读出来转告(06 票安装档的版本源)。
  expect(result.stdout).toMatch(/锁定版 v\d+\.\d+\.\d+/);
});

test("本地目录当渠道:离线/内网分发那条路走得通(不经 HTTP)", async () => {
  await writeRelease();

  const result = await runInstaller([], { base: release, uname: { s: "Darwin", m: "arm64" } });

  expect(result.exitCode).toBe(0);
  expect(existsSync(installedBin())).toBe(true);
});

// MARK: - 校验:摘要对不上就一个字节也不落盘

test("**摘要对不上**:拒绝安装,目标目录一个字节都没多(fail-closed)", async () => {
  await writeRelease();
  const base = serveRelease();
  // 元数据生成之后**再**改资产 —— 与"下载被截断 / 渠道被中间人改过"同形。
  await writeFile(path.join(release, "a2-darwin-arm64"), fakeBinSource("0.1.0", "被篡改"), "utf8");

  const result = await runInstaller([], { base, uname: { s: "Darwin", m: "arm64" } });

  expect(result.exitCode).not.toBe(0);
  expect(result.stderr).toContain("SHA-256 对不上");
  expect(existsSync(installedBin())).toBe(false);
  expect(existsSync(installDir)).toBe(false);
});

test("元数据不是认得的格式:直接拒绝(不猜、不将就)", async () => {
  await writeRelease();
  await writeFile(path.join(release, RELEASE_METADATA_FILE), '{\n  "schema": "a2-release/99"\n}\n');
  const base = serveRelease();

  const result = await runInstaller([], { base, uname: { s: "Darwin", m: "arm64" } });

  expect(result.exitCode).not.toBe(0);
  expect(result.stderr).toContain("a2-release/1");
  expect(existsSync(installedBin())).toBe(false);
});

// MARK: - 幂等与升级

test("**幂等**:同一版重跑不下载、不改动、退出 0,指引照样打全", async () => {
  await writeRelease();
  const base = serveRelease();
  await runInstaller([], { base, uname: { s: "Darwin", m: "arm64" } });
  const firstHits = hits["a2-darwin-arm64"] ?? 0;
  const before = readFileSync(installedBin(), "utf8");

  const second = await runInstaller([], { base, uname: { s: "Darwin", m: "arm64" } });

  expect(second.exitCode).toBe(0);
  expect(second.stdout).toContain("已经是这一版");
  // 连下载都省了 —— 判据是渠道那边的请求数,不是"内容没变"(后者靠重下同一份也能满足)。
  expect(hits["a2-darwin-arm64"] ?? 0).toBe(firstHits);
  expect(readFileSync(installedBin(), "utf8")).toBe(before);
});

test("**升级 = 显式重跑**:渠道换了新版本,重跑就装上新的(没有任何自动过程)", async () => {
  await writeRelease({ version: "0.1.0", marker: "旧" });
  const base = serveRelease();
  await runInstaller([], { base, uname: { s: "Darwin", m: "arm64" } });
  expect(readFileSync(installedBin(), "utf8")).toContain("旧");

  await writeRelease({ version: "0.2.0", marker: "新" });
  const upgraded = await runInstaller([], { base, uname: { s: "Darwin", m: "arm64" } });

  expect(upgraded.exitCode).toBe(0);
  expect(upgraded.stdout).toContain("0.2.0");
  expect(readFileSync(installedBin(), "utf8")).toContain("新");
});

// MARK: - 平台探测

test("平台探测:Linux/x86_64 装的是 linux-x64 那份资产", async () => {
  await writeRelease();
  const base = serveRelease();

  const result = await runInstaller([], { base, uname: { s: "Linux", m: "x86_64" } });

  expect(result.exitCode).toBe(0);
  expect(result.stdout).toContain("linux-x64");
  expect(readFileSync(installedBin(), "utf8")).toBe(
    readFileSync(path.join(release, "a2-linux-x64"), "utf8"),
  );
});

test("平台探测:aarch64 与 arm64 是同一个平台键(两种 uname 写法都认)", async () => {
  await writeRelease({ platforms: ["linux-arm64"] });
  const base = serveRelease();

  const result = await runInstaller([], { base, uname: { s: "Linux", m: "aarch64" } });

  expect(result.exitCode).toBe(0);
  expect(result.stdout).toContain("linux-arm64");
});

test("不支持的平台:明确拒绝并指向 ADR 0009 的口径,不落盘", async () => {
  await writeRelease();
  const base = serveRelease();

  const windows = await runInstaller([], { base, uname: { s: "MINGW64_NT-10.0", m: "x86_64" } });
  const i386 = await runInstaller([], { base, uname: { s: "Linux", m: "i386" } });

  expect(windows.exitCode).not.toBe(0);
  expect(windows.stderr).toContain("不支持的操作系统");
  expect(i386.exitCode).not.toBe(0);
  expect(i386.stderr).toContain("不支持的 CPU 架构");
  expect(existsSync(installedBin())).toBe(false);
});

test("这个发布没有你的平台:说清楚是哪个平台缺,而不是下一个错文件", async () => {
  await writeRelease({ platforms: ["darwin-arm64"] });
  const base = serveRelease();

  const result = await runInstaller([], { base, uname: { s: "Linux", m: "x86_64" } });

  expect(result.exitCode).not.toBe(0);
  expect(result.stderr).toContain("linux-x64");
  expect(existsSync(installedBin())).toBe(false);
});

// MARK: - 渠道未定(13 票的真实状态)

test("**渠道未定**:不给 base 就当场失败并给两条明路,绝不去连那个占位地址", async () => {
  const result = await runInstaller([], { uname: { s: "Darwin", m: "arm64" } });

  expect(result.exitCode).not.toBe(0);
  expect(result.stderr).toContain("发布渠道尚未确定");
  expect(result.stderr).toContain("A2_RELEASE_BASE");
  expect(existsSync(installedBin())).toBe(false);
});

// MARK: - PATH 提示

test("落点不在 PATH 里:打印该加哪一行(**不替用户改 shell 配置**)", async () => {
  await writeRelease();
  const base = serveRelease();

  const outside = await runInstaller([], { base, uname: { s: "Darwin", m: "arm64" } });
  const inside = await runInstaller([], {
    base,
    uname: { s: "Darwin", m: "arm64" },
    path: installDir,
  });

  expect(outside.stdout).toContain(`export PATH="${installDir}:$PATH"`);
  expect(inside.stdout).not.toContain("不在你的 PATH 里");
  // 一个 shell 配置文件都没被写过。
  expect(existsSync(path.join(fakeHome, ".zshrc"))).toBe(false);
  expect(existsSync(path.join(fakeHome, ".bashrc"))).toBe(false);
  expect(existsSync(path.join(fakeHome, ".profile"))).toBe(false);
});

// MARK: - 卸载:先看后删

test("**卸载被服务挡下**:unit 文件还在时拒绝删 bin,并给出该先跑的三条命令", async () => {
  await writeRelease();
  const base = serveRelease();
  await runInstaller([], { base, uname: { s: "Darwin", m: "arm64" } });
  const agents = path.join(fakeHome, "Library", "LaunchAgents");
  await mkdir(agents, { recursive: true });
  await writeFile(path.join(agents, "com.a2.kernel.plist"), "<plist/>");

  const result = await runInstaller(["--uninstall"]);

  expect(result.exitCode).not.toBe(0);
  expect(result.stderr).toContain("a2 service uninstall");
  // 删了 bin 就没有工具能收拾 unit 了 —— 所以它必须还在。
  expect(existsSync(installedBin())).toBe(true);
});

test("**卸载被系统代理挡下**:接管快照还在时拒绝,并指向 a2 proxy off", async () => {
  await writeRelease();
  const base = serveRelease();
  await runInstaller([], { base, uname: { s: "Darwin", m: "arm64" } });
  const a2Home = path.join(box, "a2home");
  await mkdir(a2Home, { recursive: true });
  await writeFile(path.join(a2Home, "system-proxy.json"), "{}");

  const result = await runInstaller(["--uninstall"], { a2Home });

  expect(result.exitCode).not.toBe(0);
  expect(result.stderr).toContain("a2 proxy off");
  expect(existsSync(installedBin())).toBe(true);
});

test("卸载:没有挂在系统上的东西时删掉 bin,再跑一次是幂等的", async () => {
  await writeRelease();
  const base = serveRelease();
  await runInstaller([], { base, uname: { s: "Darwin", m: "arm64" } });

  const first = await runInstaller(["--uninstall"]);
  const second = await runInstaller(["--uninstall"]);

  expect(first.exitCode).toBe(0);
  expect(existsSync(installedBin())).toBe(false);
  expect(second.exitCode).toBe(0);
  expect(second.stdout).toContain("未作改动");
  // 数据不替用户删,但要说清楚在哪。
  expect(first.stdout).toContain("rm -rf");
});
