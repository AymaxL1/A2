// 发布元数据与组装脚本(13 票)—— 「发布产物集齐」那条验收框的可门禁部分。
//
// 分三层:
//   ① **元数据的结构约束**(纯函数):摘要格式、平台↔资产名对得上、声明文本必须在、
//      不认识的文件不许混进发布包 —— 这些是 fail-closed 的,发不出去比发错强;
//   ② **两处字面量不许各写各的**:平台键与渠道占位符在 TS 与 `install.sh` 里各有一份,
//      这里逐条对账(漂了就是"元数据说的资产名"与"脚本去下的名字"对不上,用户收到 404);
//   ③ **组装脚本真跑一遍**:用假 bin 验结构;本机有真产物时再跑一遍**带自检**的完整流程。
//
// 摘要的期望值取自 `shasum -a 256`(系统工具,独立实现)—— 不拿 Bun 的哈希去验 Bun 的哈希。

import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { mkdir, mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { UPGRADE_POLICY } from "../src/runtime/about.ts";
import {
  KERNEL_TARGETS,
  RELEASE_CHANNEL_PLACEHOLDER,
  RELEASE_METADATA_FILE,
  ReleaseManifestSchema,
  buildReleaseManifest,
  classifyArtifact,
  renderReleaseManifest,
  sha256Of,
} from "../src/release/manifest.ts";

const REPO = path.resolve(import.meta.dir, "../..");
const INSTALLER = path.join(REPO, "Scripts/install.sh");
const ASSEMBLE = path.join(REPO, "Scripts/release-assemble.sh");
const BUILD_APP = path.join(REPO, "Scripts/build-app.sh");
const CHECK = path.join(REPO, "Scripts/check.sh");
const KERNEL_BUILD = path.join(REPO, "kernel/scripts/build.sh");
const DIST_BIN = path.join(REPO, "kernel/dist/a2");

let box: string;

beforeEach(async () => {
  box = await mkdtemp("/tmp/a2rel-");
});

afterEach(async () => {
  await rm(box, { recursive: true, force: true });
});

/** 摆一个最小但合法的发布包(内核 bin + 声明 + GPL 全文 + 安装脚本)。 */
async function writePackage(dir: string, extra: Record<string, string> = {}): Promise<void> {
  await writeFile(path.join(dir, "a2-darwin-arm64"), "#!/bin/sh\necho 0.1.0\n");
  await writeFile(path.join(dir, "NOTICE-external-programs.txt"), "外部程序声明\n");
  await writeFile(path.join(dir, "LICENSE-mihomo-GPL-3.0.txt"), "GPL-3.0\n");
  await writeFile(path.join(dir, "install.sh"), "#!/bin/sh\n");
  for (const [name, content] of Object.entries(extra)) {
    await writeFile(path.join(dir, name), content);
  }
}

// MARK: - ① 结构约束

test("元数据:扫一个发布包扫出全部工件,每条带 kind / 摘要 / 字节数", async () => {
  await writePackage(box);

  const manifest = await buildReleaseManifest({ dir: box, version: "0.1.0" });

  expect(manifest.schema).toBe("a2-release/1");
  expect(manifest.artifacts.map((artifact) => artifact.kind).sort()).toEqual([
    "installer",
    "kernel-bin",
    "license",
    "notice",
  ]);
  const bin = manifest.artifacts.find((artifact) => artifact.kind === "kernel-bin")!;
  expect(bin.platform).toBe("darwin-arm64");
  expect(bin.bytes).toBe(readFileSync(path.join(box, "a2-darwin-arm64")).byteLength);
});

test("摘要就是 SHA-256:与系统的 shasum -a 256 逐字相同(独立实现对照)", async () => {
  await writePackage(box);
  const manifest = await buildReleaseManifest({ dir: box, version: "0.1.0" });

  for (const artifact of manifest.artifacts) {
    const proc = Bun.spawn({
      cmd: ["shasum", "-a", "256", path.join(box, artifact.name)],
      stdout: "pipe",
    });
    const expected = (await new Response(proc.stdout).text()).split(/\s+/)[0];
    expect(artifact.sha256).toBe(expected!);
  }
});

test("**mihomo 锁定版进元数据**(06 票安装档的版本源),且与那份实测记录同源", async () => {
  await writePackage(box);
  const record = await Bun.file(path.resolve(import.meta.dir, "../contract/MIHOMO-VERSION.txt")).text();
  const expected = /v\d+\.\d+\.\d+/.exec(record)![0];

  const manifest = await buildReleaseManifest({ dir: box, version: "0.1.0" });

  expect(manifest.mihomo.lockedVersion).toBe(expected);
  expect(manifest.mihomo.license).toBe("GPL-3.0");
  // 不随包分发这条承诺在元数据里也是硬的(与 AboutResult 那条同一个 literal)。
  expect(manifest.mihomo.bundled).toBe(false);
});

test("**GPL 义务的结构守卫**:发布包少了声明文本或 GPL 全文,元数据就生成不出来", async () => {
  await writePackage(box);
  await rm(path.join(box, "NOTICE-external-programs.txt"));

  await expect(buildReleaseManifest({ dir: box, version: "0.1.0" })).rejects.toThrow();

  await writeFile(path.join(box, "NOTICE-external-programs.txt"), "声明\n");
  await rm(path.join(box, "LICENSE-mihomo-GPL-3.0.txt"));
  await expect(buildReleaseManifest({ dir: box, version: "0.1.0" })).rejects.toThrow();
});

test("**不认识的文件不许混进发布包**:组装当场停,而不是发出去之后再问那是什么", async () => {
  await writePackage(box, { "random-notes.txt": "顺手放的" });

  await expect(buildReleaseManifest({ dir: box, version: "0.1.0" })).rejects.toThrow(
    /不认识的文件/,
  );
});

test("发布包里一个内核 bin 都没有:拒绝", async () => {
  await writePackage(box);
  await rm(path.join(box, "a2-darwin-arm64"));

  await expect(buildReleaseManifest({ dir: box, version: "0.1.0" })).rejects.toThrow();
});

test("schema 层:资产名与平台对不上、摘要不是 64 位十六进制、工件重名 —— 一律拒", () => {
  const base = {
    schema: "a2-release/1",
    product: "a2",
    version: "0.1.0",
    generatedAt: "2026-08-05T00:00:00.000Z",
    channel: { base: "https://example.test/a2", status: "configured", note: "n" },
    mihomo: {
      lockedVersion: "v1.19.28",
      license: "GPL-3.0",
      source: "s",
      releases: "r",
      licenseUrl: "l",
      bundled: false,
    },
    artifacts: [
      { name: "NOTICE-external-programs.txt", kind: "notice", sha256: "a".repeat(64), bytes: 1 },
      { name: "LICENSE-mihomo-GPL-3.0.txt", kind: "license", sha256: "b".repeat(64), bytes: 1 },
    ],
  };
  const bin = (over: object) => ({
    name: "a2-linux-x64",
    kind: "kernel-bin",
    platform: "linux-x64",
    sha256: "c".repeat(64),
    bytes: 1,
    ...over,
  });

  expect(ReleaseManifestSchema.safeParse({ ...base, artifacts: [...base.artifacts, bin({})] }).success).toBe(true);
  // 平台说 linux-x64,名字却是 darwin 那份 —— 安装脚本会按名字去下,于是下错文件。
  expect(
    ReleaseManifestSchema.safeParse({
      ...base,
      artifacts: [...base.artifacts, bin({ name: "a2-darwin-arm64" })],
    }).success,
  ).toBe(false);
  expect(
    ReleaseManifestSchema.safeParse({
      ...base,
      artifacts: [...base.artifacts, bin({ platform: "solaris-sparc" })],
    }).success,
  ).toBe(false);
  expect(
    ReleaseManifestSchema.safeParse({
      ...base,
      artifacts: [...base.artifacts, bin({ sha256: "not-a-digest" })],
    }).success,
  ).toBe(false);
  expect(
    ReleaseManifestSchema.safeParse({
      ...base,
      artifacts: [...base.artifacts, bin({}), bin({})],
    }).success,
  ).toBe(false);
});

// MARK: - ①b 面板包 ↔ 内嵌内核版本(14 票「面板自足」,ADR 0012)

test("**一个发布包里只许有一版内核**:面板包必须记内嵌内核版本,且与本次发布的内核同版", () => {
  const base = {
    schema: "a2-release/1",
    product: "a2",
    version: "0.1.0",
    generatedAt: "2026-08-09T00:00:00.000Z",
    channel: { base: "https://example.test/a2", status: "configured", note: "n" },
    mihomo: {
      lockedVersion: "v1.19.28",
      license: "GPL-3.0",
      source: "s",
      releases: "r",
      licenseUrl: "l",
      bundled: false,
    },
    artifacts: [
      { name: "a2-darwin-arm64", kind: "kernel-bin", platform: "darwin-arm64", sha256: "a".repeat(64), bytes: 1 },
      { name: "NOTICE-external-programs.txt", kind: "notice", sha256: "b".repeat(64), bytes: 1 },
      { name: "LICENSE-mihomo-GPL-3.0.txt", kind: "license", sha256: "c".repeat(64), bytes: 1 },
    ],
  };
  const panel = (over: object) => ({
    name: "A2-Panel-0.1.0-macos.zip",
    kind: "panel-app",
    platform: "darwin",
    embeddedKernelVersion: "0.1.0",
    sha256: "d".repeat(64),
    bytes: 1,
    ...over,
  });
  const parse = (artifact: object) =>
    ReleaseManifestSchema.safeParse({ ...base, artifacts: [...base.artifacts, artifact] });

  expect(parse(panel({})).success).toBe(true);
  // 没记 —— 那就没人知道"点安装并启动会装上哪一版"。
  expect(parse(panel({ embeddedKernelVersion: undefined })).success).toBe(false);
  // 记了但对不上 —— 同一个包里两版内核,装到哪一版取决于用户点了哪里。
  const mismatch = parse(panel({ embeddedKernelVersion: "0.0.9" }));
  expect(mismatch.success).toBe(false);
  expect(JSON.stringify(mismatch.error?.issues)).toContain("两版内核");
  // 别的工件不该带这个字段(带了说明有人把它当通用字段用)。
  expect(
    ReleaseManifestSchema.safeParse({
      ...base,
      artifacts: [
        { ...base.artifacts[0]!, embeddedKernelVersion: "0.1.0" },
        ...base.artifacts.slice(1),
      ],
    }).success,
  ).toBe(false);
});

test("面板包在场时,版本要由调用方**实跑得来**地传进来 —— 不传就生成不出元数据", async () => {
  await writePackage(box, { "A2-Panel-0.1.0-macos.zip": "假 zip" });

  await expect(buildReleaseManifest({ dir: box, version: "0.1.0" })).rejects.toThrow();

  const manifest = await buildReleaseManifest({
    dir: box,
    version: "0.1.0",
    panelEmbeddedKernelVersion: "0.1.0",
  });
  const panel = manifest.artifacts.find((artifact) => artifact.kind === "panel-app")!;
  expect(panel.embeddedKernelVersion).toBe("0.1.0");
  // 渲染出来仍是一行一个工件(安装脚本那条 grep 的前提没被新字段破坏)。
  const line = renderReleaseManifest(manifest)
    .split("\n")
    .find((text) => text.includes('"kind":"panel-app"'))!;
  expect(JSON.parse(line.trim().replace(/,$/, "")).embeddedKernelVersion).toBe("0.1.0");
});

test("classifyArtifact:平台 bin / 声明 / 许可证 / 安装脚本 / .app 压缩包各归其位,别的认不出", () => {
  expect(classifyArtifact("a2-linux-arm64")).toEqual({ kind: "kernel-bin", platform: "linux-arm64" });
  expect(classifyArtifact("NOTICE-external-programs.txt")).toEqual({ kind: "notice" });
  expect(classifyArtifact("LICENSE-mihomo-GPL-3.0.txt")).toEqual({ kind: "license" });
  expect(classifyArtifact("install.sh")).toEqual({ kind: "installer" });
  expect(classifyArtifact("A2-Panel-0.1.0-macos.zip")).toEqual({ kind: "panel-app", platform: "darwin" });
  expect(classifyArtifact("a2")).toBeUndefined();
  expect(classifyArtifact("mihomo-darwin-arm64")).toBeUndefined();
});

test("渲染:**每个工件恰好一行**(安装脚本没有 jq,靠一条 grep 拿整条记录),且 JSON 仍然合法", async () => {
  await writePackage(box);
  const manifest = await buildReleaseManifest({ dir: box, version: "0.1.0" });

  const text = renderReleaseManifest(manifest);

  expect(JSON.parse(text)).toEqual(manifest);
  const artifactLines = text
    .split("\n")
    .filter((line) => line.trim().startsWith("{") && line.includes('"sha256"'));
  expect(artifactLines.length).toBe(manifest.artifacts.length);
  for (const line of artifactLines) {
    expect(() => JSON.parse(line.trim().replace(/,$/, ""))).not.toThrow();
  }
});

// MARK: - ② 两处字面量的对账(TS ↔ install.sh)

test("平台键两处一致:KERNEL_TARGETS 的键 = install.sh 认得的 <os>-<arch> 组合", () => {
  const script = readFileSync(INSTALLER, "utf8");
  const osKeys = [...script.matchAll(/os_key="([a-z0-9]+)"/g)].map((match) => match[1]!);
  const archKeys = [...script.matchAll(/arch_key="([a-z0-9]+)"/g)].map((match) => match[1]!);
  const scriptPlatforms = new Set(osKeys.flatMap((os) => archKeys.map((arch) => `${os}-${arch}`)));

  expect(new Set(Object.keys(KERNEL_TARGETS))).toEqual(scriptPlatforms);
});

test("渠道占位符两处一致:改渠道时 TS 与 install.sh 必须同时改", () => {
  const script = readFileSync(INSTALLER, "utf8");
  const declared = /DEFAULT_RELEASE_BASE="([^"]+)"/.exec(script)![1];

  expect(declared).toBe(RELEASE_CHANNEL_PLACEHOLDER);
  // 占位符必须是**注定连不上**的地址(.invalid 是 RFC 2606 保留域)——
  // 一个看起来能用的假地址比一条清楚的失败危险得多。
  expect(RELEASE_CHANNEL_PLACEHOLDER).toContain(".invalid");
});

test("元数据文件名三处一致(装的人按它取,组装的人按它对账)", () => {
  expect(/METADATA_FILE="([^"]+)"/.exec(readFileSync(INSTALLER, "utf8"))![1]).toBe(RELEASE_METADATA_FILE);
  // 14 票起组装脚本也要读它一次(面板内嵌内核版本的对账),于是这个名字有了第三处落点。
  expect(/METADATA_FILE="([^"]+)"/.exec(readFileSync(ASSEMBLE, "utf8"))![1]).toBe(RELEASE_METADATA_FILE);
});

// 14 票:内核 bin 的编译命令散在四个脚本里(内核构建、门禁 ②b、`.app` 出包、发布组装)。
// 它们各有各的产物路径与 target,但**入口只有一个**。入口漂了的后果很具体:某一条链路编的是
// 另一份源码,而四条链路都自称"编的是内核"。所以这里只对账入口本身。
test("内核编译入口四处一致:凡 `--compile` 编内核的地方,编的都是同一个入口", () => {
  const scripts = [KERNEL_BUILD, CHECK, BUILD_APP, ASSEMBLE];
  const entries: string[] = [];
  for (const script of scripts) {
    const found = [...readFileSync(script, "utf8").matchAll(/\bbuild\s+(\.\/\S+\.ts)\s+--compile\b/g)].map(
      (match) => match[1]!,
    );
    expect(found.length).toBe(1); // 每个脚本恰好编一次;多出来一条就该问问那是在编什么
    entries.push(found[0]!);
  }
  expect(new Set(entries).size).toBe(1);
  expect(entries[0]).toBe("./src/cli/main.ts");
});

// 14 票:`.app` 里那份内嵌内核的**文件名**是三方约定 —— 出包脚本往那儿拷、组装脚本去那儿问版本、
// 面板(16 票)按 `Bundle.main.resourceURL/<它>` 去找。这里对账前两处(第三处在 Swift 侧)。
test("内嵌内核 bin 的落点两处一致:出包往哪儿拷,组装就去哪儿问版本", () => {
  const buildApp = readFileSync(BUILD_APP, "utf8");
  const assemble = readFileSync(ASSEMBLE, "utf8");
  const embedded = /KERNEL_EXE_NAME="([^"]+)"/.exec(buildApp)![1]!;
  const probed = /PANEL_KERNEL_NAME="([^"]+)"/.exec(assemble)![1]!;

  expect(embedded).toBe(probed);
  expect(buildApp).toContain('"$APP/Contents/Resources/$KERNEL_EXE_NAME"');
  expect(assemble).toContain('*/Contents/Resources/$PANEL_KERNEL_NAME');
});

/** 从一个 sh 脚本里抠出 `uname` 的映射表:`Darwin) os_key="darwin"` / `arm64|aarch64) arch="arm64"`。 */
function unameMapOf(script: string): Record<string, string> {
  const map: Record<string, string> = {};
  for (const match of script.matchAll(/^\s*([\w|_.-]+)\)\s*(?:os|arch)(?:_key)?="([a-z0-9]+)"/gm)) {
    for (const pattern of (match[1] as string).split("|")) map[pattern] = match[2] as string;
  }
  return map;
}

// CR 必修 4:`install.sh::detect_platform` 与 `release-assemble.sh::host_platform` 各写了一遍
// uname 映射。两处漂了的后果很具体:组装机自认为是 A 平台、装的人自认为是 B 平台,
// 于是"包里有没有你的平台"这个判断在两边给出不同答案。
test("uname 映射两处一致:安装脚本与组装脚本认的是同一套 <os>-<arch>", () => {
  const installer = unameMapOf(readFileSync(INSTALLER, "utf8"));
  const assemble = unameMapOf(readFileSync(ASSEMBLE, "utf8"));

  expect(Object.keys(installer).length).toBeGreaterThan(0);
  expect(assemble).toEqual(installer);
  // 顺带钉住"aarch64 与 arm64 是同一个键"这条真实世界的写法差异(Linux 报前者)。
  expect(installer["aarch64"]).toBe("arm64");
  expect(installer["x86_64"]).toBe("x64");
});

// CR 必修 6:票面框 4 说「升级永远显式」三处成文**并各有断言** —— 前两处早有断言
// (`a2 about` 的 upgrade 字段、安装脚本结束时的提示),第三处(分发 runbook)此前只是散文。
test("「升级永远显式 / 无静默更新」三处落点都在文:about、安装脚本、分发 runbook", () => {
  const runbook = readFileSync(path.join(REPO, "docs/runbooks/distribution.md"), "utf8");
  const installer = readFileSync(INSTALLER, "utf8");

  expect(UPGRADE_POLICY).toContain("升级永远显式");
  expect(UPGRADE_POLICY).toContain("不做静默更新");
  expect(installer).toContain("升级永远显式");
  expect(runbook).toContain("升级永远显式");
  expect(runbook).toContain("没有静默更新");
  // runbook 还必须写清"升级 = 重跑脚本"这条动作,否则那句口号没有落点。
  expect(runbook).toMatch(/显式重跑/);
});

// MARK: - ③ 组装脚本真跑一遍

async function runAssemble(args: string[]): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  const proc = Bun.spawn({
    cmd: ["bash", ASSEMBLE, ...args],
    env: { ...process.env, TMPDIR: box },
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

test("组装脚本:一条命令产出 bin + 声明 + GPL 全文 + 安装脚本 + 元数据(假 bin,验结构)", async () => {
  const stub = path.join(box, "stub-a2");
  await writeFile(
    stub,
    `#!/bin/sh
case "$1" in
  version) echo "0.1.0" ;;
  about) echo "假 a2 的声明正文(由 bin 产出,不是抄的)" ;;
  *) exit 1 ;;
esac
`,
  );
  await Bun.spawn({ cmd: ["chmod", "755", stub] }).exited;
  const out = path.join(box, "release");

  const result = await runAssemble([
    "--output", out,
    "--targets", "darwin-arm64",
    "--bin", `darwin-arm64=${stub}`,
    "--skip-self-check",
  ]);

  expect(result.exitCode).toBe(0);
  const files = (await readdir(out)).sort();
  expect(files).toEqual([
    "LICENSE-mihomo-GPL-3.0.txt",
    "NOTICE-external-programs.txt",
    "a2-darwin-arm64",
    RELEASE_METADATA_FILE,
    "install.sh",
  ]);
  // 声明文本是**跑 bin 得来的**,不是从别处抄的 —— 抄一份就开始漂了。
  expect(readFileSync(path.join(out, "NOTICE-external-programs.txt"), "utf8")).toContain(
    "由 bin 产出",
  );
  // GPL 全文与安装脚本是仓库里那两份的逐字节副本。
  expect(readFileSync(path.join(out, "LICENSE-mihomo-GPL-3.0.txt"), "utf8")).toBe(
    readFileSync(path.join(REPO, "docs/legal/LICENSE-mihomo-GPL-3.0.txt"), "utf8"),
  );
  expect(readFileSync(path.join(out, "install.sh"), "utf8")).toBe(readFileSync(INSTALLER, "utf8"));

  const manifest = ReleaseManifestSchema.parse(
    JSON.parse(readFileSync(path.join(out, RELEASE_METADATA_FILE), "utf8")),
  );
  expect(manifest.version).toBe("0.1.0");
  expect(manifest.channel.status).toBe("undecided");
  expect(await sha256Of(path.join(out, "a2-darwin-arm64"))).toBe(
    manifest.artifacts.find((artifact) => artifact.kind === "kernel-bin")!.sha256,
  );
});

/** 摆一个**假 .app**:结构与真包同形(壳 + `Contents/Resources/a2`),内嵌 bin 是个会自报版本的 sh 桩。 */
async function writeFakeApp(dir: string, kernelVersion: string): Promise<string> {
  const app = path.join(dir, "A2 Panel.app");
  await mkdir(path.join(app, "Contents/MacOS"), { recursive: true });
  await mkdir(path.join(app, "Contents/Resources"), { recursive: true });
  await writeFile(path.join(app, "Contents/MacOS/a2-panel"), "#!/bin/sh\nexit 0\n");
  await writeFile(
    path.join(app, "Contents/Resources/a2"),
    `#!/bin/sh\n[ "$1" = "version" ] && echo "${kernelVersion}" && exit 0\nexit 1\n`,
  );
  await Bun.spawn({ cmd: ["chmod", "755", path.join(app, "Contents/Resources/a2")] }).exited;
  return app;
}

/** 会答 `version` / `about` / `about --json` 的假内核 bin(足够跑完组装脚本的全部自检)。 */
async function writeStubKernel(file: string, version: string): Promise<string> {
  await writeFile(
    file,
    `#!/bin/sh
case "$1$2" in
  version) echo "${version}" ;;
  "about--json") echo '{"bundled":false,"bundledTexts":[{"present":true},{"present":true}]}' ;;
  about) echo "假 a2 的声明正文(由 bin 产出,不是抄的)" ;;
  *) exit 1 ;;
esac
`,
  );
  await Bun.spawn({ cmd: ["chmod", "755", file] }).exited;
  return file;
}

// 14 票:panel zip 现在是**自带内核的完整包**,于是"包里有几版内核"成了一件发得出去的事故。
// 这两条把它按在组装期:版本进元数据(**实跑 zip 里那个 bin** 得来),对不上就当场停。
test("组装脚本(面板包):内嵌内核版本进元数据,且过得了三处对账的自检", async () => {
  const stub = await writeStubKernel(path.join(box, "stub-a2"), "0.1.0");
  const app = await writeFakeApp(box, "0.1.0");
  const out = path.join(box, "release-panel");

  const result = await runAssemble([
    "--output", out,
    "--targets", "darwin-arm64",
    "--bin", `darwin-arm64=${stub}`,
    "--app", app,
  ]);

  expect(result.exitCode).toBe(0);
  expect(result.stdout).toContain("三处对账");
  const manifest = ReleaseManifestSchema.parse(
    JSON.parse(readFileSync(path.join(out, RELEASE_METADATA_FILE), "utf8")),
  );
  const panel = manifest.artifacts.find((artifact) => artifact.kind === "panel-app")!;
  expect(panel.name).toBe("A2-Panel-0.1.0-macos.zip");
  expect(panel.embeddedKernelVersion).toBe("0.1.0");
}, 60_000);

test("组装脚本(面板包):zip 里嵌的是**另一版**内核 —— 组装当场停,发不出去", async () => {
  const stub = await writeStubKernel(path.join(box, "stub-a2"), "0.1.0");
  const app = await writeFakeApp(box, "0.0.9"); // 拿了一个旧 .app 来随附
  const out = path.join(box, "release-mismatch");

  const result = await runAssemble([
    "--output", out,
    "--targets", "darwin-arm64",
    "--bin", `darwin-arm64=${stub}`,
    "--app", app,
  ]);

  expect(result.exitCode).not.toBe(0);
  expect(`${result.stdout}${result.stderr}`).toContain("两版内核");
  expect(existsSync(path.join(out, RELEASE_METADATA_FILE))).toBe(false);
}, 60_000);

test("组装脚本(面板包):.app 里根本没有内嵌内核(14 票之前的旧包)—— 也当场停", async () => {
  const stub = await writeStubKernel(path.join(box, "stub-a2"), "0.1.0");
  const app = await writeFakeApp(box, "0.1.0");
  await rm(path.join(app, "Contents/Resources/a2"));
  const out = path.join(box, "release-nokernel");

  const result = await runAssemble([
    "--output", out,
    "--targets", "darwin-arm64",
    "--bin", `darwin-arm64=${stub}`,
    "--app", app,
  ]);

  expect(result.exitCode).not.toBe(0);
  expect(`${result.stdout}${result.stderr}`).toContain("问不出内嵌内核的版本");
}, 60_000);

// 真产物那一遍:`kernel/dist/a2` 是门禁 ②b 步恒重建的,本机跑过一次门禁就有。
// 没有它时如实跳过(而不是假装验过) —— 这条验的是**自检真的会跑**:
// 包里那个 a2 得看得见随包的两份静态文本。
test.skipIf(!existsSync(DIST_BIN))(
  "组装脚本(真产物):自检通过 —— 包里的 a2 看得见随包的两份静态文本",
  async () => {
    const out = path.join(box, "release-real");

    const result = await runAssemble([
      "--output", out,
      "--targets", "darwin-arm64",
      "--bin", `darwin-arm64=${DIST_BIN}`,
    ]);

    expect(result.exitCode).toBe(0);
    expect(result.stdout).toContain("自检通过");
    const notice = readFileSync(path.join(out, "NOTICE-external-programs.txt"), "utf8");
    expect(notice).toContain("外部程序声明");
    expect(notice).toContain("GPL-3.0");
    expect(notice).toContain("永不进程内链接");

    // CR 必修 1c:**随包 NOTICE ≡ 包里那个 a2 的 about 输出**,逐字节。
    // 「声明不是手抄的」这句承诺此前只靠组装顺序保证,现在是一条断言。
    const proc = Bun.spawn({ cmd: [path.join(out, "a2-darwin-arm64"), "about"], stdout: "pipe" });
    expect(await new Response(proc.stdout).text()).toBe(notice);

    // CR 必修 1a/1b:GPL 全文先就位,所以声明里不该说「不在此处」;
    // 也不该烙进**组装机**的绝对路径(那份文本要发给别人)。
    expect(notice).not.toContain("不在此处");
    expect(notice).not.toContain(out);
    expect(notice).toContain("与 a2 同目录");
  },
  60_000,
);
