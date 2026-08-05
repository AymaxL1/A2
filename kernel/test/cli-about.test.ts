// CLI 缝:`a2 about` —— GPL 义务的必有落点(13 票 / ADR 0007 修订版)。
//
// 这批断言守的是**法律义务**,不是功能:裁决序里法律义务在 agent-first 之上,而义务落点
// 必须 CLI 化、不依赖任何 UI、也不依赖任何常驻进程。于是这里逐条钉:
//   * 声明说得出该说的(外部程序、许可、锁版、源码获取、独立子进程红线、不随包分发);
//   * daemon 没跑照样说得出(而且**一个字节的状态都不写**);
//   * 报出的锁版版本与那份实测记录同源(对等映射表 APP-9 的新落点);
//   * 机读面与人类面同源(agent 与人读到的是同一批事实)。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { AboutResultSchema } from "../src/contract/wire.ts";
import {
  GPL_LICENSE_FILE_NAME,
  NOTICE_FILE_NAME,
  buildAbout,
  noticeFiles,
  renderAbout,
} from "../src/runtime/about.ts";
import { cleanupHome, makeHome, parseJsonStdout, runCli, socketPathFor } from "./support/harness.ts";

let home: string;

beforeEach(async () => {
  home = await makeHome();
});

afterEach(async () => {
  await cleanupHome(home);
});

/** 锁版版本的**独立事实源**:那份实测记录本身(不经 pin.ts,免得拿代码去验代码)。 */
async function lockedVersionFromRecord(): Promise<string> {
  const text = await Bun.file(path.resolve(import.meta.dir, "../contract/MIHOMO-VERSION.txt")).text();
  const match = /v\d+\.\d+\.\d+/.exec(text);
  if (!match) throw new Error(`MIHOMO-VERSION.txt 里找不到版本号:${text}`);
  return match[0];
}

test("about --json:一条包封,result 合 AboutResult 契约", async () => {
  const result = await runCli(["about", "--json"], { home });

  expect(result.exitCode).toBe(0);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(true);
  expect(AboutResultSchema.safeParse(body.result).success).toBe(true);
  expect(body.result.product).toBe("a2");
});

test("about 与 version 报的是同一个版本号(两条命令不许各说各的)", async () => {
  const about = parseJsonStdout(await runCli(["about", "--json"], { home }));
  const version = await runCli(["version"], { home });

  expect(about.result.version).toBe(version.stdout.trim());
});

test("**GPL 义务**:声明里有外部程序、许可证、源码获取地址与发布渠道", async () => {
  const body = parseJsonStdout(await runCli(["about", "--json"], { home }));
  const programs = body.result.externalPrograms as {
    name: string;
    license: string;
    source: string;
    releases: string;
    licenseUrl: string;
  }[];

  expect(programs.length).toBeGreaterThan(0);
  const mihomo = programs.find((program) => program.name.includes("mihomo"));
  expect(mihomo).toBeDefined();
  expect(mihomo!.license).toBe("GPL-3.0");
  expect(mihomo!.source).toContain("github.com/MetaCubeX/mihomo");
  expect(mihomo!.releases).toContain("releases");
  expect(mihomo!.licenseUrl).toContain("gpl-3.0");

  // 人类面与机读面同源:同一批事实,散文里也必须找得到。
  const human = await runCli(["about"], { home });
  expect(human.stdout).toContain("GPL-3.0");
  expect(human.stdout).toContain("github.com/MetaCubeX/mihomo");
});

test("**不随包分发**:每个外部程序 bundled=false,人类面明说分发物里没有它的二进制", async () => {
  const body = parseJsonStdout(await runCli(["about", "--json"], { home }));

  for (const program of body.result.externalPrograms as { bundled: boolean }[]) {
    expect(program.bundled).toBe(false);
  }
  const human = await runCli(["about"], { home });
  expect(human.stdout).toContain("随包分发  否");
});

// APP-10 的新落点(旧断言:「子进程红线原文经能力面暴露」;`proxy.license` 随义务面收缩淘汰)。
test("**独立子进程红线**的原文出现在声明里(旧 APP-10 的落点从能力面改到这里)", async () => {
  const body = parseJsonStdout(await runCli(["about", "--json"], { home }));
  const invocation = (body.result.externalPrograms as { invocation: string }[])[0]!.invocation;

  expect(invocation).toContain("独立子进程");
  expect(invocation).toContain("永不进程内链接");
  expect(body.result.declaration).toContain("永不进程内链接");
});

// APP-9 的新落点(旧断言:「`aa proxy license` 报出的内核版本与 MIHOMO-VERSION.txt 一致」)。
test("**锁版同源**:about 报的 mihomo 版本 = MIHOMO-VERSION.txt 里那一版", async () => {
  const expected = await lockedVersionFromRecord();
  const body = parseJsonStdout(await runCli(["about", "--json"], { home }));
  const mihomo = (body.result.externalPrograms as { lockedVersion: string }[])[0]!;

  expect(mihomo.lockedVersion).toBe(expected);
  const human = await runCli(["about"], { home });
  expect(human.stdout).toContain(expected);
});

test("**升级永远显式**:机读面带升级口径,且明说没有静默更新", async () => {
  const body = parseJsonStdout(await runCli(["about", "--json"], { home }));

  expect(body.result.upgrade).toContain("显式");
  expect(body.result.upgrade).toContain("不做静默更新");
});

test("**不依赖 daemon**:daemon 没跑照样退出 0,而且一个字节的状态都不写", async () => {
  const result = await runCli(["about", "--json"], { home });

  expect(result.exitCode).toBe(0);
  expect(parseJsonStdout(result).ok).toBe(true);
  // 义务落点不该有副作用:socket 没建,A2_HOME 里连一个文件都没多出来。
  expect(await Bun.file(socketPathFor(home)).exists()).toBe(false);
  expect(await readdir(home)).toEqual([]);
});

test("随包静态文本:两份文本各自报出名字与**应当在的位置**,以及此刻在不在", async () => {
  const body = parseJsonStdout(await runCli(["about", "--json"], { home }));
  const files = body.result.noticeFiles as { name: string; path: string; present: boolean }[];

  expect(files.map((file) => file.name)).toEqual([NOTICE_FILE_NAME, GPL_LICENSE_FILE_NAME]);
  // 落点恒为「与 a2 同目录」——测试环境里那两份文本当然不在,`present` 说的就是这件事。
  for (const file of files) {
    expect(path.basename(file.path)).toBe(file.name);
    expect(path.isAbsolute(file.path)).toBe(true);
    expect(file.present).toBe(false);
  }
});

test("`present` 是真的在查盘:两份文本真放到那个目录里,它就变成 true", async () => {
  const dir = await mkdtemp("/tmp/a2about-");
  try {
    expect(noticeFiles(dir).every((file) => file.present)).toBe(false);

    await writeFile(path.join(dir, NOTICE_FILE_NAME), "声明", "utf8");
    await writeFile(path.join(dir, GPL_LICENSE_FILE_NAME), "GPL", "utf8");

    // 组装脚本的自检(`release-assemble.sh` ⑥)判的就是这两个 true —— 少拷一份声明当场停。
    expect(noticeFiles(dir).map((file) => file.present)).toEqual([true, true]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("人类面自足:随包静态文本那份可以原样当声明用(版本、声明、落点、升级四段齐)", () => {
  const about = buildAbout("/opt/a2");
  const text = renderAbout(about);

  expect(text).toContain(`a2 ${about.version}`);
  expect(text).toContain("外部程序声明");
  expect(text).toContain(NOTICE_FILE_NAME);
  expect(text).toContain(GPL_LICENSE_FILE_NAME);
  expect(text).toContain("升级");
});

// CR 必修 1b:这段输出会被原样落成随包的 NOTICE —— 打绝对路径就等于把**组装机**的
// 临时目录烙进每一份分发物。人类面只说"与 a2 同目录",机读面才给展开后的绝对路径。
test("人类面**不打绝对路径**:同一份字节要能当随包声明用,不能带组装机的目录", () => {
  const text = renderAbout(buildAbout("/private/tmp/a2-assemble-XYZ"));

  expect(text).not.toContain("/private/tmp/a2-assemble-XYZ");
  expect(text).toContain("与 a2 同目录");
  // 机读面反过来:路径必须是展开后的绝对路径(此刻这台机器上的脚本要用)。
  expect(buildAbout("/private/tmp/a2-assemble-XYZ").noticeFiles[0]!.path).toBe(
    `/private/tmp/a2-assemble-XYZ/${NOTICE_FILE_NAME}`,
  );
});

test("两份文本都在时,声明里不该出现「不在此处」(那句话是给单文件直接下载的人看的)", async () => {
  const dir = await mkdtemp("/tmp/a2about-");
  try {
    await writeFile(path.join(dir, NOTICE_FILE_NAME), "声明", "utf8");
    await writeFile(path.join(dir, GPL_LICENSE_FILE_NAME), "GPL", "utf8");

    expect(renderAbout(buildAbout(dir))).not.toContain("不在此处");
    // 反过来:少一份时那句提示必须在(它才是"你还缺一份"的唯一提示)。
    await rm(path.join(dir, GPL_LICENSE_FILE_NAME));
    expect(renderAbout(buildAbout(dir))).toContain("不在此处");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("about 不接受多余参数:用法错(退出码 1)+ 指引指向那条正确写法", async () => {
  const result = await runCli(["about", "--json", "license"], { home });

  expect(result.exitCode).toBe(1);
  const body = parseJsonStdout(result);
  expect(body.ok).toBe(false);
  expect(body.error.code).toBe("usage");
  expect(body.error.guidance.steps.map((step: { command?: string }) => step.command)).toContain(
    "a2 about",
  );
});

test("可发现性:顶层帮助里有 about 这一行(找不到的义务落点等于没有)", async () => {
  const help = await runCli(["help", "--json"], { home });

  expect(parseJsonStdout(help).result.usage).toContain("about");
  const own = await runCli(["about", "--help"], { home });
  expect(own.exitCode).toBe(0);
  expect(own.stdout).toContain("GPL 义务");
});
