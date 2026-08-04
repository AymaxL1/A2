// K1 spike —— 模拟「a2 内核」的编译产物。
// 全程只用 process.execPath（= 自己这个单文件 bin）+ env.BUN_BE_BUN=1 驱动 bun CLI，
// 不依赖任何系统级 bun 安装。用法：<bin> selftest <workdir>
import { existsSync, mkdirSync, rmSync, cpSync, statSync, readdirSync } from "node:fs";
import { join } from "node:path";

type Step = {
  step: string;
  argv: string[];
  cwd?: string;
  exitCode: number | null;
  signalCode: string | null;
  ms: number;
  stdout: string;
  stderr: string;
};

const steps: Step[] = [];
/** 硬断言：会判成败、能被证伪。数字口径只数这一栏。 */
const checks: { name: string; pass: boolean; detail: string }[] = [];
/** 纯记录：只留观察到的原文，不参与成败判定、不计入断言数。 */
const records: { name: string; detail: string }[] = [];

const clip = (s: string, n = 1600) =>
  s.length > n ? s.slice(0, n) + `\n…(truncated, total ${s.length} bytes)` : s;

/** 拉起「自己」当 bun CLI 用。这就是 spike 要验证的核心动作。 */
async function runSelf(
  step: string,
  argv: string[],
  opts: { cwd?: string; stdin?: string; env?: Record<string, string> } = {},
): Promise<Step> {
  const t0 = performance.now();
  const proc = Bun.spawn({
    cmd: [process.execPath, ...argv],
    cwd: opts.cwd,
    env: { ...process.env, ...(opts.env ?? {}), BUN_BE_BUN: "1" },
    stdin: opts.stdin === undefined ? "ignore" : new TextEncoder().encode(opts.stdin),
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const exitCode = await proc.exited;
  const r: Step = {
    step,
    argv,
    cwd: opts.cwd,
    exitCode,
    signalCode: proc.signalCode ?? null,
    ms: Math.round(performance.now() - t0),
    stdout: clip(stdout),
    stderr: clip(stderr),
  };
  steps.push(r);
  return r;
}

const check = (name: string, pass: boolean, detail = "") => {
  checks.push({ name, pass, detail });
  return pass;
};

/** 只记不判。用于「行为原文留档」这类没有对错的观察，避免拿恒真项充断言数。 */
const record = (name: string, detail: string) => {
  records.push({ name, detail });
};

const markers = (dir: string) =>
  existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith("_RAN")).sort() : ["<dir missing>"];

const parseJSON = (s: string): unknown => {
  try {
    return JSON.parse(s.trim());
  } catch {
    return null;
  }
};

async function selftest(work: string) {
  const pluginDir = join(work, "plugin-src");
  const pluginDirIgnore = join(work, "plugin-src-ignore-scripts");
  const registry = join(work, "registry"); // 模拟 ~/.a2 的插件登记区
  const neutral = join(work, "neutral"); // 运行工件时的中立 cwd（无 node_modules）
  const artifact = join(registry, "k1-dep-plugin.js");
  mkdirSync(registry, { recursive: true });
  mkdirSync(neutral, { recursive: true });

  // ── Q1：BUN_BE_BUN 下能否 bun install，lifecycle scripts 是否被跳过 ──────────
  // 所有 install 都把 BUN_INSTALL_CACHE_DIR 指到 workdir 下的私有缓存：既不写用户的
  // ~/.bun/install/cache，也让「冷/热」两个数字有确定含义——第一次 install 走空缓存
  // （= 冷缓存，真下载），之后的 install 复用同一份缓存（= 热缓存）。
  const cache = join(work, "bun-cache");
  const cacheEnv = { BUN_INSTALL_CACHE_DIR: cache };

  const installCold = await runSelf("install(冷缓存·首次真下载)", ["install"], {
    cwd: join(work, "plugin-src-cold"),
    env: cacheEnv,
  });

  const install = await runSelf("install(默认·热缓存)", ["install"], {
    cwd: pluginDir,
    env: cacheEnv,
  });
  check("Q1.install 退出码 0", install.exitCode === 0, `exit=${install.exitCode}`);
  check(
    "Q1.冷缓存 install(workdir 私有 BUN_INSTALL_CACHE_DIR)也成功",
    installCold.exitCode === 0 && existsSync(join(cache, "picocolors")),
    `exit=${installCold.exitCode} 冷缓存耗时=${installCold.ms}ms vs 热缓存=${install.ms}ms`,
  );
  check(
    "Q1.node_modules 装出依赖",
    existsSync(join(pluginDir, "node_modules", "picocolors")) &&
      existsSync(join(pluginDir, "node_modules", "a2-lifecycle-probe")),
    readdirSync(join(pluginDir, "node_modules")).filter((f) => !f.startsWith(".")).join(","),
  );
  const depMarkers = markers(join(pluginDir, "node_modules", "a2-lifecycle-probe"));
  check("Q1.依赖 lifecycle scripts 未执行", depMarkers.length === 0, `dep markers=[${depMarkers}]`);
  const rootMarkers = markers(pluginDir);
  check(
    "Q1.根 package.json lifecycle scripts 默认执行(!)",
    rootMarkers.length > 0,
    `root markers=[${rootMarkers}]`,
  );

  record(
    "install 的 stdout 原文(依赖脚本被拦的官方措辞)",
    install.stdout.replace(/\x1b\[[0-9;]*m/g, "").trim(),
  );

  const untrusted = await runSelf("pm untrusted", ["pm", "untrusted"], {
    cwd: pluginDir,
    env: cacheEnv,
  });
  check(
    "Q1.bun pm untrusted 可列出被拦的脚本(审计素材)",
    untrusted.exitCode === 0 && untrusted.stdout.includes("a2-lifecycle-probe"),
    `exit=${untrusted.exitCode}`,
  );

  // --ignore-scripts 对照组：连根脚本一起封死
  const installIgnore = await runSelf("install(--ignore-scripts)", ["install", "--ignore-scripts"], {
    cwd: pluginDirIgnore,
    env: cacheEnv,
  });
  const rootMarkersIgnore = markers(pluginDirIgnore);
  const depMarkersIgnore = markers(join(pluginDirIgnore, "node_modules", "a2-lifecycle-probe"));
  check(
    "Q1.--ignore-scripts 连根脚本一并封死",
    installIgnore.exitCode === 0 && rootMarkersIgnore.length === 0 && depMarkersIgnore.length === 0,
    `exit=${installIgnore.exitCode} root=[${rootMarkersIgnore}] dep=[${depMarkersIgnore}]`,
  );

  const pmls = await runSelf("pm ls", ["pm", "ls"], { cwd: pluginDir, env: cacheEnv });
  check(
    "Q1.bun pm ls 可列依赖清单(审计素材)",
    pmls.exitCode === 0 && pmls.stdout.includes("picocolors"),
    `exit=${pmls.exitCode}`,
  );

  // ── Q2：BUN_BE_BUN 下能否 bun build --target=bun 打成单文件 ─────────────────
  const build = await runSelf(
    "build(--target=bun)",
    ["build", "./index.ts", "--target=bun", "--outfile", artifact],
    { cwd: pluginDir },
  );
  const artifactExists = existsSync(artifact);
  const artifactSize = artifactExists ? statSync(artifact).size : -1;
  check(
    "Q2.build 退出码 0 且产出工件",
    build.exitCode === 0 && artifactExists,
    `exit=${build.exitCode} size=${artifactSize}B`,
  );
  check(
    "Q2.登记区只有一个单文件(无 chunk / 无 node_modules)",
    artifactExists && readdirSync(registry).length === 1,
    `registry=[${readdirSync(registry)}]`,
  );
  const artifactText = artifactExists ? await Bun.file(artifact).text() : "";
  check(
    "Q2.依赖被内联进工件(picocolors + 本地 tarball 依赖)",
    artifactText.includes("isColorSupported") && artifactText.includes("a2-lifecycle-probe@1.0.0"),
    `bytes=${artifactText.length}`,
  );

  // 工件在源目录尚在时先跑一次 describe（对照组）
  const describeBefore = await runSelf("describe(源目录尚在)", [artifact, "describe"], {
    cwd: pluginDir,
  });

  // ── 运行期单文件：源目录（连同 node_modules）整个删掉 ───────────────────────
  rmSync(pluginDir, { recursive: true, force: true });
  rmSync(pluginDirIgnore, { recursive: true, force: true });
  check("Q3.源目录与 node_modules 已删除", !existsSync(pluginDir), pluginDir);

  // ── Q3：工件被同一个 bin 经 BUN_BE_BUN 作子进程拉起 ────────────────────────
  const describe = await runSelf("describe(源目录已删)", [artifact, "describe"], { cwd: neutral });
  const describeJSON = parseJSON(describe.stdout) as any;
  check(
    "Q3.describe 退出码 0 + stdout 合法 JSON 工具清单",
    describe.exitCode === 0 && Array.isArray(describeJSON?.tools) && describeJSON.tools.length === 2,
    `exit=${describe.exitCode} tools=${JSON.stringify(describeJSON?.tools?.map((t: any) => t.name))}`,
  );
  check(
    "Q3.删源目录前后 describe 输出一致",
    describeBefore.stdout.trim() === describe.stdout.trim(),
    `before=${describeBefore.exitCode} after=${describe.exitCode}`,
  );
  check(
    "Q3.工件内 npm 依赖运行期真的可用",
    describeJSON?.deps?.picocolors === true && describeJSON?.deps?.probe === "a2-lifecycle-probe@1.0.0",
    JSON.stringify(describeJSON?.deps),
  );

  const payload = { tool: "echo", input: { text: "hello-a2" } };
  const call = await runSelf("call echo(stdin JSON)", [artifact, "call"], {
    cwd: neutral,
    stdin: JSON.stringify(payload),
  });
  const callJSON = parseJSON(call.stdout) as any;
  check(
    "Q3.call stdin/stdout JSON 往返正确 + exit 0",
    call.exitCode === 0 && callJSON?.ok === true && callJSON?.output?.upper === "HELLO-A2",
    `exit=${call.exitCode} out=${clip(call.stdout, 200)}`,
  );
  check(
    "Q3.插件是独立子进程(PID 与内核不同)",
    typeof callJSON?.output?.pid === "number" && callJSON.output.pid !== process.pid,
    `kernelPid=${process.pid} pluginPid=${callJSON?.output?.pid}`,
  );

  const callFail = await runSelf("call boom(插件内失败)", [artifact, "call"], {
    cwd: neutral,
    stdin: JSON.stringify({ tool: "boom" }),
  });
  check(
    "Q3.插件失败 → 退出码 3 + 结构化错误",
    callFail.exitCode === 3 && (parseJSON(callFail.stdout) as any)?.error === "deliberate_failure",
    `exit=${callFail.exitCode}`,
  );

  const callUnknown = await runSelf("call unknown(未知工具)", [artifact, "call"], {
    cwd: neutral,
    stdin: JSON.stringify({ tool: "nope" }),
  });
  check(
    "Q3.未知工具 → 退出码 4",
    callUnknown.exitCode === 4,
    `exit=${callUnknown.exitCode}`,
  );

  const callBadJSON = await runSelf("call bad-json", [artifact, "call"], {
    cwd: neutral,
    stdin: "{not json",
  });
  check("Q3.坏 stdin → 退出码 2", callBadJSON.exitCode === 2, `exit=${callBadJSON.exitCode}`);

  // 推荐的内核调用姿势：--no-install（见下方 auto-install 边界），对正常工件必须无害
  const describeNoInstall = await runSelf(
    "describe(--no-install)",
    ["--no-install", artifact, "describe"],
    { cwd: neutral },
  );
  check(
    "Q3.--no-install 不影响正常单文件工件",
    describeNoInstall.exitCode === 0 && describeNoInstall.stdout.trim() === describe.stdout.trim(),
    `exit=${describeNoInstall.exitCode}`,
  );

  const callThrow = await runSelf("call throw(未捕获异常)", [artifact, "call"], {
    cwd: neutral,
    stdin: JSON.stringify({ tool: "throw" }),
  });
  check(
    "Q3.插件未捕获异常 → 非零退出码 + stderr 有栈",
    callThrow.exitCode !== 0 && callThrow.stderr.length > 0,
    `exit=${callThrow.exitCode} stderrHead=${clip(callThrow.stderr, 120)}`,
  );

  // ── 边界：打不进的怪包（供 12 票拒绝面设计）──────────────────────────────
  const edgeDyn = join(work, "edge-dynamic-require");
  const edgeDynOut = join(work, "edge-out", "dynamic.js");
  const edgeDynBuild = await runSelf(
    "build(动态 require)",
    ["build", "./index.ts", "--target=bun", "--outfile", edgeDynOut],
    { cwd: edgeDyn },
  );
  // 这里的实质命题是「打包期抓不到动态 require」：build 成功、有产物、且**一句告警都没有**。
  check(
    "边界.动态 require → 打包期静默通过(exit=0、有产物、零告警)",
    edgeDynBuild.exitCode === 0 &&
      existsSync(edgeDynOut) &&
      !/warn/i.test(edgeDynBuild.stderr + edgeDynBuild.stdout),
    `exit=${edgeDynBuild.exitCode} 产物=${existsSync(edgeDynOut)} stderr=${clip(edgeDynBuild.stderr, 200) || "<空>"}`,
  );
  // 若动态 require 能打进去，运行期是否翻车？分两种：内置模块 vs npm 包
  if (existsSync(edgeDynOut)) {
    const edgeDynBuiltin = await runSelf("run(动态 require:内置模块)", [edgeDynOut], {
      cwd: neutral,
    });
    check(
      "边界.动态 require 内置模块 → 打包通过且运行期正常",
      edgeDynBuiltin.exitCode === 0,
      `exit=${edgeDynBuiltin.exitCode} stdout=${clip(edgeDynBuiltin.stdout, 120)}`,
    );
    // auto-install 边界：工件所在目录树没有 node_modules 时，Bun 运行期会**联网**
    // 自动装包（装进 BUN_INSTALL_CACHE_DIR）——动态 require 因此在打包期静默通过、
    // 运行期偷偷联网跑通。这是 12 票必须显式处理的供应链面。
    const probeCache = join(work, "autoinstall-cache");
    rmSync(probeCache, { recursive: true, force: true });
    const edgeDynNpm = await runSelf("run(动态 require:npm 包, 默认)", [edgeDynOut], {
      cwd: neutral,
      env: { A2_MOD: "left-pad", BUN_INSTALL_CACHE_DIR: probeCache },
    });
    check(
      "边界.动态 require npm 包 → 打包期静默通过，运行期 Bun 自动联网装包(!)",
      edgeDynNpm.exitCode === 0 && existsSync(join(probeCache, "left-pad")),
      `exit=${edgeDynNpm.exitCode} 缓存目录=[${existsSync(probeCache) ? readdirSync(probeCache) : "<无>"}]`,
    );
    const probeCache2 = join(work, "autoinstall-cache-2");
    const edgeDynNoInstall = await runSelf(
      "run(动态 require:npm 包, --no-install)",
      ["--no-install", edgeDynOut],
      { cwd: neutral, env: { A2_MOD: "left-pad", BUN_INSTALL_CACHE_DIR: probeCache2 } },
    );
    check(
      "边界.--no-install 关掉 auto-install → 硬错(fail-closed，内核应默认加这个 flag)",
      edgeDynNoInstall.exitCode !== 0 && edgeDynNoInstall.stderr.includes("Cannot find package"),
      `exit=${edgeDynNoInstall.exitCode} stderrHead=${clip(edgeDynNoInstall.stderr, 160)}`,
    );
  }

  const edgeNative = join(work, "edge-native-addon");
  const edgeNativeOut = join(work, "edge-out", "native.js");
  const edgeNativeBuild = await runSelf(
    "build(native .node addon, --outfile)",
    ["build", "./index.ts", "--target=bun", "--outfile", edgeNativeOut],
    { cwd: edgeNative },
  );
  check(
    "边界.native .node addon + --outfile → build 失败(可作检出信号)",
    edgeNativeBuild.exitCode !== 0 && !existsSync(edgeNativeOut),
    `exit=${edgeNativeBuild.exitCode} stderrHead=${clip(edgeNativeBuild.stderr, 240)}`,
  );
  record(
    "native .node addon + --outfile 的报错原文(不提 addon，指引得内核自己写)",
    edgeNativeBuild.stderr.replace(/\x1b\[[0-9;]*m/g, "").trim(),
  );
  const edgeNativeDir = join(work, "edge-out", "native-outdir");
  const edgeNativeBuild2 = await runSelf(
    "build(native .node addon, --outdir)",
    ["build", "./index.ts", "--target=bun", "--outdir", edgeNativeDir],
    { cwd: edgeNative },
  );
  const nativeOutFiles = existsSync(edgeNativeDir) ? readdirSync(edgeNativeDir).sort() : [];
  // 实质命题：换成 --outdir 后 build **不再失败**，而是多吐一个 .node —— 所以 12 票
  // 用 --outdir 时的判据只能是「产物文件数 > 1」，不能指望非零退出码。
  check(
    "边界.native .node addon + --outdir → build 成功但产物不止一个文件(非单文件即拒绝依据)",
    edgeNativeBuild2.exitCode === 0 &&
      nativeOutFiles.length > 1 &&
      nativeOutFiles.some((f) => f.endsWith(".node")),
    `exit=${edgeNativeBuild2.exitCode} files=[${nativeOutFiles}] stderrHead=${clip(edgeNativeBuild2.stderr, 160)}`,
  );

  // auto-install 的触发规则：只看「祖先目录里有没有 node_modules」，与 package.json 无关
  const autoIsoCache = join(work, "auto-iso-cache");
  rmSync(autoIsoCache, { recursive: true, force: true });
  const runIso = await runSelf("run(全隔离目录, 静态 import 未装包)", ["./iso.ts"], {
    cwd: join(work, "auto-iso"),
    env: { BUN_INSTALL_CACHE_DIR: autoIsoCache },
  });
  check(
    "边界.目录树内无 node_modules → 连静态 import 都会 auto-install(联网)",
    runIso.exitCode === 0 && existsSync(join(autoIsoCache, "is-odd")),
    `exit=${runIso.exitCode} stdout=${clip(runIso.stdout, 120)}`,
  );
  // 对照：有 package.json、但仍无 node_modules —— auto-install 是否照样触发？
  const autoPkgCache = join(work, "auto-pkgjson-cache");
  rmSync(autoPkgCache, { recursive: true, force: true });
  const runPkgJSON = await runSelf("run(有 package.json、无 node_modules)", ["./iso.ts"], {
    cwd: join(work, "auto-pkgjson"),
    env: { BUN_INSTALL_CACHE_DIR: autoPkgCache },
  });
  check(
    "边界.有 package.json 但无 node_modules → 照样 auto-install(触发条件与 package.json 无关)",
    runPkgJSON.exitCode === 0 && existsSync(join(autoPkgCache, "is-odd")),
    `exit=${runPkgJSON.exitCode} stdout=${clip(runPkgJSON.stdout, 120)}`,
  );

  const runBlocked = await runSelf("run(祖先目录有空 node_modules)", ["./iso.ts"], {
    cwd: join(work, "auto-blocked", "sub"),
    env: { BUN_INSTALL_CACHE_DIR: join(work, "auto-blocked-cache") },
  });
  check(
    "边界.祖先目录存在 node_modules(哪怕是空的) → auto-install 关闭，硬错",
    runBlocked.exitCode !== 0 && runBlocked.stderr.includes("Cannot find package"),
    `exit=${runBlocked.exitCode} stderrHead=${clip(runBlocked.stderr, 140)}`,
  );

  const edgeMissing = join(work, "edge-missing-dep");
  const edgeMissingOut = join(work, "edge-out", "missing.js");
  const edgeMissingBuild = await runSelf(
    "build(依赖未装)",
    ["build", "./index.ts", "--target=bun", "--outfile", edgeMissingOut],
    { cwd: edgeMissing },
  );
  check(
    "边界.依赖未装时 build 明确失败(非静默产出坏工件)",
    edgeMissingBuild.exitCode !== 0 && !existsSync(edgeMissingOut),
    `exit=${edgeMissingBuild.exitCode} stderrHead=${clip(edgeMissingBuild.stderr, 200)}`,
  );

  const passed = checks.filter((c) => c.pass).length;
  const report = {
    spike: "K1 —— BUN_BE_BUN 自举 bun install / bun build（02 票）",
    kernelBin: process.execPath,
    bunVersionOfKernel: Bun.version,
    workdir: work,
    artifact: { path: artifact, bytes: artifactSize },
    checks,
    records,
    // 数字口径：只有硬断言进 total；records 是留档观察，不判成败、不计数。
    summary: {
      total: checks.length,
      passed,
      failed: checks.length - passed,
      recordCount: records.length,
    },
    steps,
  };
  console.log(JSON.stringify(report, null, 2));
  return passed === checks.length;
}

const [mode, work] = process.argv.slice(2);
if (mode === "selftest" && work) {
  const ok = await selftest(work);
  process.exit(ok ? 0 : 1);
} else {
  console.log(JSON.stringify({ ok: false, usage: "<bin> selftest <workdir>" }));
  process.exit(64);
}
