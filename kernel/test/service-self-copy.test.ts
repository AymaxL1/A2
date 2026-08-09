// 15 票 —— 拷贝机制与「unit 指着谁」的反向读法(单元缝)。
//
// 这一层测的是两件 CLI 缝上不方便逼出来的事:
//   * **幂等判据是内容**:同一批字节复跑不该换 inode(换了就说明白拷了一次,收敛升级也会跟着白重启);
//   * **渲染器与反向读法逐条对位**:unit 里的路径经过 XML 转义 / systemd 引号与 `%%` 之后,
//     还能被原样读回来 —— 家目录里出现空格、`&`、`%` 都不是奇谈,而 `binPath` 是面板的判据。
//
// 纪律:所有落盘都在 mktemp 出来的临时目录里,真 `~/.a2` 一个字节都不碰。

import { afterEach, expect, test } from "bun:test";
import { existsSync, statSync } from "node:fs";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  copySelfToHome,
  homeBinPath,
  HOME_BIN_MODE,
  HOME_BIN_DIR_MODE,
  resolveSelfBin,
  SELF_BIN_ENV,
  STAGING_PREFIX,
} from "../src/service/self-copy.ts";
import { renderLaunchdPlist, renderSystemdUnit, unitBinaryPath } from "../src/service/unit.ts";

const workspaces: string[] = [];

async function workspace(): Promise<string> {
  const dir = await mkdtemp("/tmp/a2copy-");
  workspaces.push(dir);
  return dir;
}

afterEach(async () => {
  while (workspaces.length > 0) {
    await rm(workspaces.pop() as string, { recursive: true, force: true });
  }
});

function mode(file: string): number {
  return statSync(file).mode & 0o777;
}

// MARK: - 原子拷贝与幂等

test("首装拷贝:落位 0755、目录 0700、内容逐字节相同,且不留暂存件", async () => {
  const root = await workspace();
  const source = path.join(root, "src-a2");
  await writeFile(source, "#!/bin/sh\necho v1\n", { mode: 0o755 });
  const target = path.join(root, "home", "bin", "a2");

  const outcome = await copySelfToHome(source, target);

  expect(outcome).toBe("copied");
  expect(await readFile(target, "utf8")).toBe(await readFile(source, "utf8"));
  // supervisor 要 exec 它,可执行位必须显式给(写文件的 mode 会被 umask 削)。
  expect(mode(target)).toBe(HOME_BIN_MODE);
  expect(mode(path.dirname(target))).toBe(HOME_BIN_DIR_MODE);
  // 落位靠"临时件 + rename",成了就不该留下半成品。
  expect(await readdir(path.dirname(target))).toEqual(["a2"]);
});

test("幂等按内容判:同一批字节复跑不报拷贝,inode 一个都没换", async () => {
  const root = await workspace();
  const source = path.join(root, "src-a2");
  await writeFile(source, "#!/bin/sh\necho v1\n", { mode: 0o755 });
  const target = path.join(root, "home", "bin", "a2");
  await copySelfToHome(source, target);
  const before = statSync(target).ino;

  // mtime 变了但内容没变 —— 判据若是 mtime,这一步就会白拷一次(并让收敛升级白重启一次服务)。
  await writeFile(source, "#!/bin/sh\necho v1\n", { mode: 0o755 });
  const outcome = await copySelfToHome(source, target);

  expect(outcome).toBe("unchanged");
  expect(statSync(target).ino).toBe(before);
});

test("内容变了就换 inode(rename 换目录项),旧内容不再是那份", async () => {
  const root = await workspace();
  const source = path.join(root, "src-a2");
  await writeFile(source, "#!/bin/sh\necho v1\n", { mode: 0o755 });
  const target = path.join(root, "home", "bin", "a2");
  await copySelfToHome(source, target);
  const before = statSync(target).ino;

  await writeFile(source, "#!/bin/sh\necho v2\n", { mode: 0o755 });
  const outcome = await copySelfToHome(source, target);

  expect(outcome).toBe("copied");
  expect(await readFile(target, "utf8")).toContain("v2");
  // 换的是目录项而不是那份 inode —— 正在跑的旧进程因此照常活着(这就是自拷贝合法的理由)。
  expect(statSync(target).ino).not.toBe(before);
});

test("大小相同但字节不同也算变了(判据是摘要,不是长度)", async () => {
  const root = await workspace();
  const source = path.join(root, "src-a2");
  await writeFile(source, "AAAA", { mode: 0o755 });
  const target = path.join(root, "home", "bin", "a2");
  await copySelfToHome(source, target);

  await writeFile(source, "AAAB", { mode: 0o755 });

  expect(await copySelfToHome(source, target)).toBe("copied");
  expect(await readFile(target, "utf8")).toBe("AAAB");
});

test("源不在:抛错,且不留下暂存件也不留下半截的目标", async () => {
  const root = await workspace();
  const target = path.join(root, "home", "bin", "a2");

  await expect(copySelfToHome(path.join(root, "查无此文件"), target)).rejects.toThrow();

  expect(existsSync(target)).toBe(false);
  const dir = path.dirname(target);
  if (existsSync(dir)) expect(await readdir(dir)).toEqual([]);
});

// MARK: - 暂存件:名字每次唯一 + 陈旧残留会被捡走(CR 尾款 1)

test("暂存件不用固定名:目标旁边占着老固定名的东西也挡不住落位", async () => {
  const root = await workspace();
  const source = path.join(root, "src-a2");
  await writeFile(source, "#!/bin/sh\necho v1\n", { mode: 0o755 });
  const target = path.join(root, "home", "bin", "a2");
  await mkdir(path.dirname(target), { recursive: true });
  // 旧方案写的就是 `<target>.staging` 这一个固定名 —— 这里让那个名字被一个**目录**占着:
  // 旧方案会当场 EISDIR,新方案(唯一名)压根不看它。
  await mkdir(`${target}.staging`);

  expect(await copySelfToHome(source, target)).toBe("copied");

  expect(await readFile(target, "utf8")).toContain("v1");
});

test("陈旧暂存件会被捡走:内容没变那一路也清(升级中途被杀留下的孤儿只有这里能捡)", async () => {
  const root = await workspace();
  const source = path.join(root, "src-a2");
  await writeFile(source, "#!/bin/sh\necho v1\n", { mode: 0o755 });
  const target = path.join(root, "home", "bin", "a2");
  await copySelfToHome(source, target);
  const dir = path.dirname(target);
  // 上一次升级写到一半被 SIGKILL 留下的那个 60MiB 孤儿(这里用一个小文件代表)。
  const orphan = path.join(dir, `${STAGING_PREFIX}a2-01890000-dead-7000-8000-000000000000`);
  await writeFile(orphan, "半截的产物");

  // 内容没变 —— 早退那一路。
  expect(await copySelfToHome(source, target)).toBe("unchanged");

  expect(existsSync(orphan)).toBe(false);
  expect(await readdir(dir)).toEqual(["a2"]);
});

test("陈旧暂存件会被捡走:内容变了那一路也清,且不误伤目标", async () => {
  const root = await workspace();
  const source = path.join(root, "src-a2");
  await writeFile(source, "#!/bin/sh\necho v1\n", { mode: 0o755 });
  const target = path.join(root, "home", "bin", "a2");
  await copySelfToHome(source, target);
  const dir = path.dirname(target);
  const orphan = path.join(dir, `${STAGING_PREFIX}a2-01890000-beef-7000-8000-000000000000`);
  await writeFile(orphan, "半截的产物");

  await writeFile(source, "#!/bin/sh\necho v2\n", { mode: 0o755 });
  expect(await copySelfToHome(source, target)).toBe("copied");

  expect(existsSync(orphan)).toBe(false);
  expect(await readdir(dir)).toEqual(["a2"]);
  expect(await readFile(target, "utf8")).toContain("v2");
});

test("清扫只认自己的前缀:同目录下别人的文件一根汗毛都不动", async () => {
  const root = await workspace();
  const source = path.join(root, "src-a2");
  await writeFile(source, "#!/bin/sh\necho v1\n", { mode: 0o755 });
  const target = path.join(root, "home", "bin", "a2");
  await copySelfToHome(source, target);
  const dir = path.dirname(target);
  const innocent = path.join(dir, "a2.staging-备份");
  await writeFile(innocent, "别人的东西");

  expect(await copySelfToHome(source, target)).toBe("unchanged");

  expect(existsSync(innocent)).toBe(true);
});

// MARK: - 落点与「本 bin 是谁」

test("拷贝落点恒为 $A2_HOME/bin/a2", () => {
  expect(homeBinPath({ home: "/tmp/x", runDir: "/tmp/x/run", socketPath: "/tmp/x/run/kernel.sock" }))
    .toBe("/tmp/x/bin/a2");
});

test("开发态没有可分发的自身;A2_SELF_BIN 覆写成绝对路径", () => {
  // 本测试进程就是源码态(bun test),所以这条是活体判据而不是模拟。
  expect(resolveSelfBin({})).toBeUndefined();
  expect(resolveSelfBin({ [SELF_BIN_ENV]: "  " })).toBeUndefined();
  expect(resolveSelfBin({ [SELF_BIN_ENV]: "./a2" })).toBe(path.resolve("./a2"));
});

// MARK: - unit 反向读法(与两个渲染器逐条对位)

const AWKWARD_PATHS = [
  "/Users/alice/.a2/bin/a2",
  "/Users/a b c/.a2/bin/a2",
  "/Users/alice & bob/.a2/bin/a2",
  "/Users/100%pure/.a2/bin/a2",
  "/Users/alice/<odd>/a2",
  "/Users/back\\slash/a2",
  // 双引号与 `$` —— systemd 侧最不平凡的那条分支:`"` 被写成 `\"`,反转义必须逐个认出来
  // (`$` 则有意不转义,见 `systemdQuote` 的头注:它的展开是上下文相关的)。
  '/Users/say "hi"/$a2',
  // 一条把三样凑齐的:引号 + 反斜杠 + 百分号,三种转义在同一个词里叠着。
  '/Users/q"b\\s/100%/a2',
];

test("launchd:render → parse 逐条还原 argv[0](转义过的 & < > 也还得回来)", () => {
  for (const bin of AWKWARD_PATHS) {
    const plist = renderLaunchdPlist({
      label: "com.a2.kernel",
      programArguments: [bin, "daemon", "run"],
      environment: { A2_HOME: "/Users/alice/.a2" },
    });
    expect(unitBinaryPath("launchd", plist)).toBe(bin);
  }
});

test("systemd:render → parse 逐条还原 argv[0](引号与 %% 都得反过来)", () => {
  for (const bin of AWKWARD_PATHS) {
    const unit = renderSystemdUnit({
      programArguments: [bin, "daemon", "run"],
      environment: { A2_HOME: "/home/alice/.a2" },
    });
    expect(unitBinaryPath("systemd", unit)).toBe(bin);
  }
});

test("形状不认识的 unit 内容:说不知道,不瞎猜", () => {
  expect(unitBinaryPath("launchd", "<plist><dict></dict></plist>")).toBeUndefined();
  expect(unitBinaryPath("systemd", "[Service]\nType=simple\n")).toBeUndefined();
  // 引号没闭合 —— 不是本内核写出来的东西。
  expect(unitBinaryPath("systemd", 'ExecStart="/usr/bin/a2 daemon run\n')).toBeUndefined();
});
