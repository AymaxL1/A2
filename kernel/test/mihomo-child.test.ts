// 内嵌子进程管理器的**单元面**(14 票 CR 补):认尸三对齐、孤儿/顶替不误杀、
// 停用悬牌(H1)、SIGTERM 宽限→SIGKILL 升级、健康清零。
// 全部探针/时钟/spawn 注入 —— 这正是 child.ts 头注承诺的「三种尸体都造得出来」。

import { afterEach, expect, test } from "bun:test";
import { mkdtemp, rm, mkdir } from "node:fs/promises";
import path from "node:path";
import {
  MihomoChild,
  childSnapshot,
  identifyChild,
  readChildRecord,
  writeChildRecord,
  type ChildHandle,
  type ChildRecord,
  type ProcessProbe,
} from "../src/mihomo/child.ts";
import { mihomoLayout } from "../src/mihomo/paths.ts";
import type { KernelPaths } from "../src/runtime/paths.ts";

let root: string | undefined;
const corpses: number[] = [];

afterEach(async () => {
  for (const pid of corpses.splice(0)) {
    try { process.kill(pid, "SIGKILL"); } catch { /* 已经没了 */ }
  }
  if (root) await rm(root, { recursive: true, force: true });
  root = undefined;
});

async function makeHome(): Promise<{ paths: KernelPaths; layout: ReturnType<typeof mihomoLayout> }> {
  root = await mkdtemp("/tmp/a2child-");
  const home = path.join(root, "home");
  await mkdir(path.join(home, "mihomo"), { recursive: true });
  const paths: KernelPaths = { home, runDir: path.join(home, "run"), socketPath: path.join(home, "run", "kernel.sock") };
  return { paths, layout: mihomoLayout(paths, {}) };
}

function probe(overrides: Partial<ProcessProbe>): ProcessProbe {
  return {
    alive: () => true,
    commandOf: async () => undefined,
    startedAtOf: async () => undefined,
    ...overrides,
  };
}

function record(layoutBinary: string, extra: Partial<ChildRecord> = {}): ChildRecord {
  return { pid: 4242, startedAt: Date.now(), binaryPath: layoutBinary, restartCount: 0, ...extra };
}

// MARK: - identifyChild(纯逻辑:三种尸体)

test("认尸·gone:pid 死了 / 命令行问不出来,一律当没有(绝不据缺失的证据动手)", async () => {
  const { layout } = await makeHome();
  const dead = await identifyChild(record(layout.binaryPath), probe({ alive: () => false }));
  expect(dead).toBe("gone");
  const blind = await identifyChild(record(layout.binaryPath), probe({ commandOf: async () => undefined }));
  expect(blind).toBe("gone");
});

test("认尸·not_ours:pid 被顶替(命令行没有任何一根指纹)→ 验不明,**不动手**", async () => {
  const { layout } = await makeHome();
  const identity = await identifyChild(
    record(layout.binaryPath, { configPath: layout.configPath }),
    probe({ commandOf: async () => "/usr/bin/some-other-daemon --serve" }),
  );
  expect(identity).toBe("not_ours");
});

test("认尸·三对齐:指纹对上但启动时间差超容差 → not_ours(顶替进程连路径都对时,时间是最后一格)", async () => {
  const { layout } = await makeHome();
  const cmd = `${layout.binaryPath} -d x -f y`;
  const now = Date.now();
  const ours = await identifyChild(
    record(layout.binaryPath, { startedAt: now }),
    probe({ commandOf: async () => cmd, startedAtOf: async () => now + 3_000 }),
  );
  expect(ours).toBe("ours");
  const impostor = await identifyChild(
    record(layout.binaryPath, { startedAt: now }),
    probe({ commandOf: async () => cmd, startedAtOf: async () => now + 60_000 }),
  );
  expect(impostor).toBe("not_ours");
  // 时间问不出来 → 降级双指纹(只可能漏杀,不可能误杀)。
  const degraded = await identifyChild(
    record(layout.binaryPath, { startedAt: now }),
    probe({ commandOf: async () => cmd, startedAtOf: async () => undefined }),
  );
  expect(degraded).toBe("ours");
});

// MARK: - 认尸红线(活体):验不明的真进程一根汗毛都不少

test("红线·活体:陈尸记录指向一个**不是我们的**真进程 → start() 不碰它;验明是自己的才补刀", async () => {
  const { paths, layout } = await makeHome();

  // ① 顶替:真 /bin/sleep,记录的指纹与它的命令行对不上。
  const impostor = Bun.spawn({ cmd: ["/bin/sleep", "300"], stdout: "ignore", stderr: "ignore" });
  corpses.push(impostor.pid);
  await writeChildRecord(layout, {
    pid: impostor.pid, startedAt: Date.now(), binaryPath: layout.binaryPath,
    configPath: layout.configPath, restartCount: 0,
  });
  const dummy: ChildHandle = { pid: 999_999, exited: new Promise(() => {}), kill: () => {} };
  const child = new MihomoChild(paths, layout, {
    spawn: () => dummy,
    sleep: async () => {},
    probe: undefined, // 用真探针:ps 真的去看那个 sleep
  });
  await child.start();
  // 顶替进程还活着 —— 认不出就不动手,端口冲突留给 mihomo 自己的报错去浮现。
  expect(() => process.kill(impostor.pid, 0)).not.toThrow();

  // ② 自己的残尸:记录指纹与命令行对得上(binaryPath=/bin/sleep)→ 补刀。
  const corpse = Bun.spawn({ cmd: ["/bin/sleep", "300"], stdout: "ignore", stderr: "ignore" });
  corpses.push(corpse.pid);
  const layout2 = { ...layout, binaryPath: "/bin/sleep" };
  await writeChildRecord(layout2, {
    pid: corpse.pid, startedAt: Date.now(), binaryPath: "/bin/sleep", restartCount: 0,
  });
  const child2 = new MihomoChild(paths, layout2, { spawn: () => dummy, sleep: async () => {} });
  await child2.start();
  await new Promise((resolve) => setTimeout(resolve, 200));
  expect(() => process.kill(corpse.pid, 0)).toThrow();
}, 20000);

// MARK: - H1 悬牌:节流窗内 disable,不得复活

test("停用悬牌(CR H1):崩溃后的节流窗内 stop() → 节流到点**不再**复拉", async () => {
  const { paths, layout } = await makeHome();
  let spawnCount = 0;
  let crash: (code: number | null) => void = () => {};
  const sleepers: Array<() => void> = [];
  const child = new MihomoChild(paths, layout, {
    spawn: () => {
      spawnCount += 1;
      return { pid: 100 + spawnCount, exited: new Promise((r) => { crash = r; }), kill: () => {} };
    },
    sleep: (ms) => new Promise((resolve) => { void ms; sleepers.push(resolve); }),
    probe: probe({ alive: () => false }),
    now: () => 1_000_000 + spawnCount, // 秒退口径(lived≈0)
  });

  await child.start();
  expect(spawnCount).toBe(1);
  crash(1); // 子进程崩了 → watch 进入节流睡眠
  await new Promise((resolve) => setTimeout(resolve, 50));
  expect(sleepers.length).toBe(1);

  await child.stop(); // 节流窗内停用:立「已停用」牌
  sleepers.shift()?.(); // 节流到点
  await new Promise((resolve) => setTimeout(resolve, 50));
  expect(spawnCount).toBe(1); // **没有**复拉

  // 对照:start()(= 重新 enable/apply)摘牌后照常拉起。
  await child.start();
  expect(spawnCount).toBe(2);
});

// MARK: - 宽限升级与健康清零

test("stop():SIGTERM 被无视 → 宽限到点补 SIGKILL,幂等返回", async () => {
  const { paths, layout } = await makeHome();
  const signals: string[] = [];
  let die: (code: number | null) => void = () => {};
  const handle: ChildHandle = {
    pid: 4242,
    exited: new Promise((r) => { die = r; }),
    kill: (signal) => {
      signals.push(signal);
      if (signal === "SIGKILL") die(null); // 只有必杀才倒下(「卡死不理 SIGTERM」档)
    },
  };
  const child = new MihomoChild(paths, layout, {
    spawn: () => handle,
    sleep: async () => {}, // 宽限立即到点
    probe: probe({ alive: () => false }),
  });
  await child.start();
  expect(await child.stop()).toBe(true);
  expect(signals).toEqual(["SIGTERM", "SIGKILL"]);
  expect(await child.stop()).toBe(false); // 幂等
});

test("健康清零(CR M7):带着旧计数拉起、活过健康阈值 → 认尸文件里的 restartCount 归零", async () => {
  const { paths, layout } = await makeHome();
  await writeChildRecord(layout, { restartCount: 2 });
  const child = new MihomoChild(paths, layout, {
    spawn: () => ({ pid: 4242, exited: new Promise(() => {}), kill: () => {} }),
    sleep: async () => {}, // 健康计时立即到点
    probe: probe({}),
  });
  await child.start();
  await new Promise((resolve) => setTimeout(resolve, 50));
  expect((await readChildRecord(layout)).restartCount).toBe(0);
});

test("childSnapshot:failed 态优先于身份探测,lastError 原样带出", async () => {
  const { layout } = await makeHome();
  await writeChildRecord(layout, { restartCount: 3, failed: true, lastError: "FATA boom" });
  const snapshot = await childSnapshot(layout, probe({}));
  expect(snapshot.state).toBe("failed");
  expect(snapshot.lastError).toBe("FATA boom");
});
