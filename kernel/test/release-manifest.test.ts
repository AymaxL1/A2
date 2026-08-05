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
import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
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

test("元数据文件名两处一致(脚本按它取元数据)", () => {
  const script = readFileSync(INSTALLER, "utf8");
  expect(/METADATA_FILE="([^"]+)"/.exec(script)![1]).toBe(RELEASE_METADATA_FILE);
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
  },
  60_000,
);
