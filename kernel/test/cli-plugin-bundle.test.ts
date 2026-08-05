// CLI 缝:插件依赖流(12 票)—— **装载期 install+bundle,运行期全员单文件**。
//
// 被测的是 ADR 0011 那半条还没兑现的裁决:带 npm 依赖的**目录插件**在 `a2 plugin add` 那一刻被
// 内核自己(`BUN_BE_BUN` 自举)装依赖 + 打成单文件工件登记,`node_modules` 即用即弃;
// 打不进的怪包得到**结构化拒绝 + 指引**。
//
// 断言全在外部可观察面上:stdout 的 JSON 包封、退出码、登记区里到底躺着什么、审计日志、
// 以及插件自己回报的进程事实。
//
// ============================================================================
// 两条本文件特有的纪律
// ============================================================================
//   ① **不出网**。依赖用测试自己现打的本地 npm tarball(`file:` 依赖),于是这批用例在飞机上
//      也能跑,而且"离线可调"这件事验的是真的离线,不是"碰巧缓存里有"。
//   ② **绝不写用户的 `~/.bun/install/cache`**。每个用例把 `BUN_INSTALL_CACHE_DIR` 钉在自己的
//      临时目录里(02 票 spike 同姿势)——门禁跑一万遍,用户那份缓存一个字节都不变。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, readdirSync, realpathSync } from "node:fs";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { toolchainEnv } from "../src/plugin/bundle.ts";
import {
  cleanupHome,
  makeHome,
  parseJsonStdout,
  runCli,
  startDaemon,
  stopDaemon,
  type DaemonHandle,
} from "./support/harness.ts";

let home: string;
let workspace: string;
let cache: string;
let daemon: DaemonHandle | undefined;

beforeEach(async () => {
  home = await makeHome();
  workspace = path.join(home, "..", path.basename(home).replace("a2t-", "a2w-"));
  cache = path.join(home, "..", path.basename(home).replace("a2t-", "a2c-"));
  await mkdir(workspace, { recursive: true });
  await mkdir(cache, { recursive: true });
  daemon = undefined;
});

afterEach(async () => {
  if (daemon) await stopDaemon(daemon);
  await cleanupHome(home);
  await cleanupHome(workspace);
  await cleanupHome(cache);
});

const registryDir = () => path.join(home, "plugins");

/** 起 daemon,并把包缓存钉死在本次的临时目录里(**用户那份缓存不许被碰**)。 */
async function startWithCache(extra: Record<string, string> = {}): Promise<DaemonHandle> {
  return await startDaemon(home, { BUN_INSTALL_CACHE_DIR: cache, ...extra });
}

// MARK: - 现场攒一个"带真实 npm 依赖的插件目录"
//
// 依赖是测试自己打的一个**真 npm tarball**(`package/` 根 + package.json,与 registry 上的包
// 一模一样的形状),经 `file:` 声明装进去 —— 走的是 `bun install` 的真实代码路径,只是不出网。

/** 依赖包自己也声明 lifecycle scripts:它们**不该**被执行(spike §8.1 那条安全发现的活体断言)。 */
async function packDependency(into: string): Promise<string> {
  const staging = path.join(workspace, `dep-${crypto.randomUUID()}`);
  const pkg = path.join(staging, "package");
  await mkdir(pkg, { recursive: true });
  await writeFile(
    path.join(pkg, "package.json"),
    JSON.stringify({
      name: "a2-fixture-dep",
      version: "1.0.0",
      main: "index.js",
      scripts: {
        preinstall: "echo ran > DEP_PREINSTALL_RAN",
        postinstall: "echo ran > DEP_POSTINSTALL_RAN",
      },
    }),
  );
  await writeFile(
    path.join(pkg, "index.js"),
    "module.exports = { stamp: () => 'a2-fixture-dep@1.0.0' };\n",
  );
  const tarball = path.join(into, "a2-fixture-dep-1.0.0.tgz");
  const tar = Bun.spawn({
    cmd: ["tar", "-czf", tarball, "-C", staging, "package"],
    stdout: "pipe",
    stderr: "pipe",
  });
  if ((await tar.exited) !== 0) throw new Error(`打 tarball 失败:${await new Response(tar.stderr).text()}`);
  return tarball;
}

interface DirectoryPluginOptions {
  /** 覆写入口源码。 */
  entry?: string;
  /** 覆写 package.json(给 undefined 表示**不写** package.json)。 */
  packageJson?: Record<string, unknown> | undefined;
  /** 额外文件(相对目录的路径 → 内容)。 */
  files?: Record<string, string>;
  /** 要不要打一个本地依赖 tarball 进去。 */
  withDependency?: boolean;
}

/** 现场攒一个目录插件,返回它的绝对路径。 */
async function writeDirectoryPlugin(
  name: string,
  options: DirectoryPluginOptions = {},
): Promise<string> {
  const directory = path.join(workspace, name);
  await mkdir(directory, { recursive: true });
  if (options.withDependency === true) await packDependency(directory);

  await writeFile(path.join(directory, "index.ts"), options.entry ?? DEPENDENT_ENTRY, "utf8");
  for (const [relative, content] of Object.entries(options.files ?? {})) {
    await mkdir(path.dirname(path.join(directory, relative)), { recursive: true });
    await writeFile(path.join(directory, relative), content, "utf8");
  }
  if (!("packageJson" in options) || options.packageJson !== undefined) {
    await writeFile(
      path.join(directory, "package.json"),
      JSON.stringify(
        options.packageJson ?? {
          name,
          version: "1.0.0",
          private: true,
          type: "module",
          // **根工程自己的 lifecycle scripts**:没有 `--ignore-scripts` 它们会在 add 那一刻
          // 以用户身份执行(02 票 spike 实测)。标记文件落地与否就是那条纪律的判据。
          scripts: {
            preinstall: "echo ran > ROOT_PREINSTALL_RAN",
            postinstall: "echo ran > ROOT_POSTINSTALL_RAN",
            prepare: "echo ran > ROOT_PREPARE_RAN",
          },
          dependencies: { "a2-fixture-dep": "file:./a2-fixture-dep-1.0.0.tgz" },
        },
        null,
        2,
      ),
      "utf8",
    );
  }
  return directory;
}

/** 主样例:一个真的 import 了 npm 依赖的插件(依赖的字符串必须出现在运行结果里)。 */
const DEPENDENT_ENTRY = `
import dep from "a2-fixture-dep";
const TOOLS = [
  { name: "stamp", summary: "回报打进工件的依赖版本", dangerous: false,
    parameters: [{ name: "note", type: "string", required: false, description: "随手记" }] },
];
const mode = process.argv[2];
if (mode === "describe") {
  console.log(JSON.stringify({ protocol: 1, name: "dep-plugin", tools: TOOLS }));
  process.exit(0);
}
if (mode === "call") {
  const req = JSON.parse(await Bun.stdin.text());
  console.log(JSON.stringify({ ok: true, output: {
    stamp: dep.stamp(),
    note: req.input.note ?? null,
    pid: process.pid,
    a2env: Object.keys(process.env).filter((k) => k.startsWith("A2_")),
    cwd: process.cwd(),
  } }));
  process.exit(0);
}
process.exit(2);
`;

/** 零依赖单文件插件,回报**同一批**进程事实 —— 用来证明两种形态的运行路径没有区别。 */
const PLAIN_SINGLE_FILE = `
const TOOLS = [
  { name: "stamp", summary: "回报进程事实", dangerous: false,
    parameters: [{ name: "note", type: "string", required: false, description: "随手记" }] },
];
const mode = process.argv[2];
if (mode === "describe") {
  console.log(JSON.stringify({ protocol: 1, tools: TOOLS }));
  process.exit(0);
}
if (mode === "call") {
  const req = JSON.parse(await Bun.stdin.text());
  console.log(JSON.stringify({ ok: true, output: {
    stamp: "no-dependency",
    note: req.input.note ?? null,
    pid: process.pid,
    a2env: Object.keys(process.env).filter((k) => k.startsWith("A2_")),
    cwd: process.cwd(),
  } }));
  process.exit(0);
}
process.exit(2);
`;

async function auditDetails(): Promise<string[]> {
  const raw = await readFile(path.join(home, "log", "arbitration.log"), "utf8");
  return raw
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line).detail as string);
}

/** 系统临时目录里属于本内核的构建工作区(用完必须一个不剩)。 */
function buildWorkdirs(): string[] {
  return readdirSync(os.tmpdir()).filter((name) => name.startsWith("a2-plugin-build-"));
}

// MARK: - 主线:目录插件 add → 单文件工件 → 运行期无差别

test("目录插件 add:内核自己 install + bundle 成单文件工件登记,node_modules 一个字节都不落登记区", async () => {
  daemon = await startWithCache();
  const before = buildWorkdirs();
  const directory = await writeDirectoryPlugin("depplug", { withDependency: true });

  const added = await runCli(["plugin", "add", directory, "--json"], { home });

  expect(added.exitCode).toBe(0);
  const body = parseJsonStdout(added);
  expect(body.result.action).toBe("added");
  // 工件是**打出来的单文件 .js**(源目录里的入口是 .ts,登记的不是它)。
  expect(body.result.plugin.artifact).toBe(path.join(registryDir(), "depplug.js"));
  expect(body.result.plugin.source).toBe(directory);
  expect(body.result.added.map((d: { id: string }) => d.id)).toEqual(["plugin.depplug.stamp"]);

  // 登记区里只有工件与清单:没有 node_modules、没有 lockfile、没有暂存件。
  expect(readdirSync(registryDir()).sort()).toEqual(["depplug.js", "plugins.json"]);

  // 临时工作区(装依赖的地方)用完即弃 —— 一个都不许留在 /tmp 里。
  expect(buildWorkdirs()).toEqual(before);

  // **源目录一个字节都没被写**:内核在自己的临时工作区里装,不动用户的目录。
  expect(readdirSync(directory).sort()).toEqual([
    "a2-fixture-dep-1.0.0.tgz",
    "index.ts",
    "package.json",
  ]);
});

test("依赖真的被内联进工件:调用结果里带着依赖的自报版本,而工件是单独一个文件", async () => {
  daemon = await startWithCache();
  const directory = await writeDirectoryPlugin("depplug", { withDependency: true });
  await runCli(["plugin", "add", directory, "--json"], { home });

  const called = parseJsonStdout(
    await runCli(
      ["capabilities", "call", "plugin.depplug.stamp", "--input", '{"note":"打进去了吗"}', "--json"],
      { home },
    ),
  );

  expect(called.result.output.stamp).toBe("a2-fixture-dep@1.0.0");
  expect(called.result.output.note).toBe("打进去了吗");
  const artifact = await readFile(path.join(registryDir(), "depplug.js"), "utf8");
  expect(artifact).toContain("a2-fixture-dep@1.0.0"); // 依赖的源码就在工件里,不是外部 require
});

test("**离线证明**:源目录连同 tarball 整个删掉,插件照常可调且输出逐字不变", async () => {
  daemon = await startWithCache();
  const directory = await writeDirectoryPlugin("depplug", { withDependency: true });
  await runCli(["plugin", "add", directory, "--json"], { home });
  const before = parseJsonStdout(
    await runCli(["capabilities", "call", "plugin.depplug.stamp", "--json"], { home }),
  );

  // 源目录没了 = 装依赖的一切线索都没了。运行期只该依赖登记区里那一个文件。
  await rm(directory, { recursive: true, force: true });
  expect(existsSync(directory)).toBe(false);

  const after = parseJsonStdout(
    await runCli(["capabilities", "call", "plugin.depplug.stamp", "--json"], { home }),
  );
  expect(after.result.output.stamp).toBe(before.result.output.stamp);
  expect(after.result.output.cwd).toBe(before.result.output.cwd);
  // 重启 daemon 之后依然如此(还原的是清单 + 工件,与源目录无关)。
  await stopDaemon(daemon);
  daemon = await startWithCache();
  const restarted = parseJsonStdout(
    await runCli(["capabilities", "call", "plugin.depplug.stamp", "--json"], { home }),
  );
  expect(restarted.result.output.stamp).toBe("a2-fixture-dep@1.0.0");
});

test("运行期无差别:bundle 出来的插件与零依赖单文件插件,进程事实逐项相同", async () => {
  daemon = await startWithCache();
  const directory = await writeDirectoryPlugin("depplug", { withDependency: true });
  const single = path.join(workspace, "plainplug.ts");
  await writeFile(single, PLAIN_SINGLE_FILE, "utf8");
  await runCli(["plugin", "add", directory, "--json"], { home });
  await runCli(["plugin", "add", single, "--json"], { home });

  const status = parseJsonStdout(await runCli(["status", "--json"], { home }));
  const bundled = parseJsonStdout(
    await runCli(["capabilities", "call", "plugin.depplug.stamp", "--json"], { home }),
  ).result.output;
  const plain = parseJsonStdout(
    await runCli(["capabilities", "call", "plugin.plainplug.stamp", "--json"], { home }),
  ).result.output;

  // 同一条运行路径 = 同一批可观察事实:都在进程外、都拿不到 A2_*、cwd 都钉在登记区。
  expect(bundled.pid).not.toBe(status.result.pid);
  expect(plain.pid).not.toBe(status.result.pid);
  expect(bundled.a2env).toEqual([]);
  expect(plain.a2env).toEqual([]);
  expect(bundled.cwd).toBe(realpathSync(registryDir()));
  expect(plain.cwd).toBe(bundled.cwd);
  // 连清单里都看不出"这条是打出来的":两条记录的形状完全一样,只有 artifact 扩展名不同。
  const listed = parseJsonStdout(await runCli(["plugin", "list", "--json"], { home })).result.plugins;
  expect(Object.keys(listed[0]).sort()).toEqual(Object.keys(listed[1]).sort());
});

// MARK: - 供应链:--ignore-scripts 与审计

test("install 必带 --ignore-scripts:插件目录**自己**的 preinstall/postinstall 一次都没跑", async () => {
  daemon = await startWithCache();
  const directory = await writeDirectoryPlugin("depplug", { withDependency: true });

  expect((await runCli(["plugin", "add", directory, "--json"], { home })).exitCode).toBe(0);

  // 02 票 spike 的安全发现:没有这个 flag,这三个标记文件会在 add 那一刻落地
  // (= 未经审查的目录在装载时执行了任意命令)。它们在源目录与登记区都不该存在。
  for (const marker of ["ROOT_PREINSTALL_RAN", "ROOT_POSTINSTALL_RAN", "ROOT_PREPARE_RAN"]) {
    expect(existsSync(path.join(directory, marker))).toBe(false);
    expect(existsSync(path.join(registryDir(), marker))).toBe(false);
  }
  expect(readdirSync(directory).filter((name) => name.endsWith("_RAN"))).toEqual([]);
});

test("审计事件里记着依赖清单与「lifecycle scripts 被跳过」——装载零闸下唯一的可审计物", async () => {
  daemon = await startWithCache();
  const directory = await writeDirectoryPlugin("depplug", { withDependency: true });

  await runCli(["plugin", "add", directory, "--json"], { home });

  const detail = (await auditDetails()).find((line) => line.includes("depplug"));
  expect(detail).toBeDefined();
  expect(detail!).toContain("a2-fixture-dep");      // 依赖清单
  expect(detail!).toContain("--ignore-scripts");     // 跳过脚本这件事本身
  expect(detail!).toContain("preinstall");           // 它**声明过**什么(而我们没跑)
  expect(detail!).toContain("入口 index.ts");
  // 同一条也经 CLI 查得到(壳缺席时的唯一查询面)。
  const arbitration = parseJsonStdout(await runCli(["arbitration", "status", "--json"], { home }));
  const events = arbitration.result.output.events as { action: string; detail?: string }[];
  expect(events.find((e) => e.action === "plugin_added")!.detail).toContain("a2-fixture-dep");
});

test("工具链环境是白名单:A2_* 一个不递,但缓存目录与代理变量照给(理由在 bundle.ts 头注)", () => {
  const env = toolchainEnv({
    PATH: "/usr/bin",
    HOME: "/Users/someone",
    BUN_INSTALL_CACHE_DIR: "/tmp/cache",
    HTTPS_PROXY: "http://127.0.0.1:1",
    A2_HOME: "/should/not/leak",
    A2_PLUGIN_TIMEOUT_MS: "1",
  });

  expect(Object.keys(env).sort()).toEqual([
    "BUN_BE_BUN",
    "BUN_INSTALL_CACHE_DIR",
    "HOME",
    "HTTPS_PROXY",
    "PATH",
  ]);
  expect(JSON.stringify(env)).not.toContain("should/not/leak");
  // 编译产物要靠它切换成"我是 bun"(整条流水线不要求用户装系统级 bun)。
  expect(env["BUN_BE_BUN"]).toBe("1");
});

// MARK: - add 期能检出的拒绝面

test("native addon(.node):产物不止一个文件即拒绝 —— 判据是文件数,不是退出码", async () => {
  daemon = await startWithCache();
  const directory = await writeDirectoryPlugin("nativeplug", {
    packageJson: { name: "nativeplug", version: "1.0.0", private: true, type: "module" },
    entry: `
      const addon = require("./fake.node");
      console.log(JSON.stringify({ protocol: 1, tools: [
        { name: "x", summary: "x", dangerous: false, parameters: [] },
      ], addon: typeof addon }));
    `,
    files: { "fake.node": "NOT-A-REAL-NATIVE-ADDON —— 只为触发 bundler 对 .node 的处理路径。\n" },
  });

  const result = await runCli(["plugin", "add", directory, "--json"], { home });

  // 02 票 spike §8.4:`--outdir` 下 build **成功**(exit=0)并多吐一个 .node ——
  // 所以这条拒绝只能靠"产物文件数 > 1",指望退出码就会把 native addon 静默登记进去。
  expect(result.exitCode).toBe(5);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("plugin_load_failed");
  expect(body.error.message).toContain("不是单文件插件");
  expect(body.error.detail).toContain(".node");
  // 指引要说清楚"不支持什么"与"能怎么替代",而不是只报一句失败。
  const steps = JSON.stringify(body.error.guidance.steps);
  expect(steps).toContain("native addon");
  expect(steps).toContain("替代");
  // 一个字节都没登记。
  expect(existsSync(path.join(registryDir(), "nativeplug.js"))).toBe(false);
  expect(parseJsonStdout(await runCli(["plugin", "list", "--json"], { home })).result.plugins).toEqual([]);
});

test("打包失败(依赖没声明就 import):结构化拒绝,打包器的原文进 detail", async () => {
  daemon = await startWithCache();
  const directory = await writeDirectoryPlugin("brokenplug", {
    packageJson: { name: "brokenplug", version: "1.0.0", private: true, type: "module" },
    entry: `
      import missing from "a2-definitely-not-a-real-package";
      console.log(JSON.stringify({ protocol: 1, tools: [], missing }));
    `,
  });

  const result = await runCli(["plugin", "add", directory, "--json"], { home });

  expect(result.exitCode).toBe(5);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("plugin_load_failed");
  expect(body.error.message).toContain("打包失败");
  // 打包器自己的话最有用:它带着"哪个 import 解析不了"。
  expect(body.error.detail).toContain("a2-definitely-not-a-real-package");
  expect(body.error.detail).not.toContain("\u001b["); // 颜色转义不该进机读报文(那是给终端看的)
  expect(readdirSync(registryDir()).filter((name) => name.startsWith(".staging"))).toEqual([]);
});

test("目录里找不到入口:结构化拒绝,报文写清楚找过哪些名字", async () => {
  daemon = await startWithCache();
  const directory = path.join(workspace, "emptyplug");
  await mkdir(directory, { recursive: true });
  await writeFile(path.join(directory, "readme.md"), "什么都没有\n", "utf8");

  const result = await runCli(["plugin", "add", directory, "--json"], { home });

  expect(result.exitCode).toBe(5);
  const body = parseJsonStdout(result);
  expect(body.error.code).toBe("plugin_load_failed");
  expect(body.error.message).toContain("找不到入口文件");
  expect(body.error.detail).toContain("index.ts");
  expect(JSON.stringify(body.error.guidance)).toContain("package.json");
});

test("package.json 坏了:结构化拒绝(而不是把一个读不懂的工程硬装一遍)", async () => {
  daemon = await startWithCache();
  const directory = await writeDirectoryPlugin("badjson", { withDependency: false });
  await writeFile(path.join(directory, "package.json"), "{ 这不是 JSON", "utf8");

  const result = await runCli(["plugin", "add", directory, "--json"], { home });

  expect(result.exitCode).toBe(5);
  expect(parseJsonStdout(result).error.message).toContain("package.json");
});

// MARK: - add 期检不出的那一类:动态 require 走运行期兜底

test("动态 require:add 期照过(打包器看不见它),调用时硬失败 + 指引告诉 agent 改哪儿", async () => {
  daemon = await startWithCache();
  const directory = await writeDirectoryPlugin("dynplug", {
    packageJson: { name: "dynplug", version: "1.0.0", private: true, type: "module" },
    entry: `
      const TOOLS = [{ name: "load", summary: "运行期才决定 require 谁", dangerous: false, parameters: [] }];
      const mode = process.argv[2];
      if (mode === "describe") {
        console.log(JSON.stringify({ protocol: 1, tools: TOOLS }));
        process.exit(0);
      }
      if (mode === "call") {
        // 非静态可分析:打包期解析不了,只能等到运行期(02 票 spike §8.4 实测 exit=0、零告警)。
        const name = process.env.A2_FIXTURE_MODULE ?? "a2-definitely-not-a-real-package";
        const mod = require(name);
        console.log(JSON.stringify({ ok: true, output: { keys: Object.keys(mod).length } }));
        process.exit(0);
      }
      process.exit(2);
    `,
  });

  // ① add 期:打包器一句话都不说,插件照常登记 —— 这正是"add 期检不出"的活体证据。
  const added = await runCli(["plugin", "add", directory, "--json"], { home });
  expect(added.exitCode).toBe(0);

  // ② 调用期:`--no-install` 把 Bun 的运行期 auto-install 关成 fail-closed,于是它硬失败,
  //    而**不是**在调用的那一刻静默联网把包装上(供应链面不许从装载期漏到调用期)。
  const called = await runCli(["capabilities", "call", "plugin.dynplug.load", "--json"], { home });
  expect(called.exitCode).toBe(5);
  const body = parseJsonStdout(called);
  expect(body.error.code).toBe("plugin_failed");
  expect(body.error.detail).toContain("Cannot find package");
  // 指引必须点破这件事:依赖没打进工件、原因多半是动态 require、改成静态 import 再 add。
  const guidance = JSON.stringify(body.error.guidance);
  expect(guidance).toContain("动态 require");
  expect(guidance).toContain("--no-install");
  expect(body.error.guidance.context.missingPackage).toBe("a2-definitely-not-a-real-package");
});

// MARK: - 超时:装载期工具链有自己的旋钮

test("install/build 超时是**独立的** env:它卡死装载期,却不动 describe/call 的窗口", async () => {
  // 1ms —— 任何一次真实的 install/build 都超它,而 describe/call 的窗口仍是默认的 15 秒。
  daemon = await startWithCache({ A2_PLUGIN_BUILD_TIMEOUT_MS: "1" });
  const directory = await writeDirectoryPlugin("slowplug", { withDependency: true });
  const single = path.join(workspace, "plainplug.ts");
  await writeFile(single, PLAIN_SINGLE_FILE, "utf8");

  const bundled = await runCli(["plugin", "add", directory, "--json"], { home });
  expect(bundled.exitCode).toBe(5);
  const body = parseJsonStdout(bundled);
  expect(body.error.code).toBe("plugin_load_failed");
  expect(body.error.message).toContain("(1ms)");
  expect(JSON.stringify(body.error.guidance)).toContain("A2_PLUGIN_BUILD_TIMEOUT_MS");

  // 同一个 daemon 上,零依赖单文件插件照装照调 —— 两个旋钮互不相干。
  const plain = await runCli(["plugin", "add", single, "--json"], { home });
  expect(plain.exitCode).toBe(0);
  expect(
    (await runCli(["capabilities", "call", "plugin.plainplug.stamp", "--json"], { home })).exitCode,
  ).toBe(0);
});
