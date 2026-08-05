// 发布元数据 `a2-release.json` —— 一个发布包里都有什么、各自的 SHA-256、以及 mihomo 锁定版(13 票)。
//
// ============================================================================
// 它是谁的事实源
// ============================================================================
//   * **安装脚本**(`Scripts/install.sh`)据它挑平台资产、据它校验摘要 —— 没有第二处写死的下载地址;
//   * **06 票的安装档**据 `mihomo.lockedVersion` 知道该装哪一版 mihomo(spec 明写"发布元数据同时
//     承载 mihomo 锁定版本");这里的值来自 `src/mihomo/pin.ts`,而那个常量与
//     `kernel/contract/MIHOMO-VERSION.txt` 有同源断言守着 —— 三处永远是同一个数。
//
// ============================================================================
// 为什么它**不**在 `CONTRACT_SCHEMAS` 里
// ============================================================================
// 那张表登记的是**线协议**报文(内核 ↔ 客户端 / 内核 ↔ 插件),Swift 侧要对着它做手写 Codable 对账。
// 发布元数据不经任何 socket:它是**分发工件**,消费者是安装脚本与人。把它塞进线协议契约表
// 只会让壳那边多一条"永远不会解的报文"的记账。它自己的漂移由本文件的 zod schema + `bun test` 守着。
//
// ============================================================================
// 两条 fail-closed 的结构约束(写在 schema 里,不是写在注释里)
// ============================================================================
//   ① **发布包必须带声明文本**:`notice` 与 `license` 各恰好一份。GPL 义务不能靠"组装时记得拷"——
//      忘了拷,元数据就生成不出来,发布流程当场停(ADR 0007 修订版:随包静态文本是必有落点之一)。
//   ② **不认识的文件不许混进发布包**:`classifyArtifact` 认不出的文件名一律报错。
//      发布物是要被 curl 下来执行的东西,"顺手多带了个文件"不该是静默通过的事。

import { readdirSync, statSync } from "node:fs";
import path from "node:path";
import { z } from "zod";
import {
  GPL_LICENSE_FILE_NAME,
  GPL3_TEXT_URL,
  MIHOMO_PROJECT_URL,
  NOTICE_FILE_NAME,
  PRODUCT_NAME,
} from "../runtime/about.ts";
import { MIHOMO_LOCKED_VERSION, MIHOMO_RELEASE_BASE } from "../mihomo/pin.ts";

/** 元数据自身的格式版本(不兼容变更才 +1 —— 安装脚本据它判断读不读得懂)。 */
export const RELEASE_SCHEMA_ID = "a2-release/1";

/** 元数据文件名(发布包内;安装脚本默认从 `<base>/<这个名字>` 取)。 */
export const RELEASE_METADATA_FILE = "a2-release.json";

/** 安装脚本在发布包里的名字。 */
export const INSTALLER_FILE_NAME = "install.sh";

/**
 * **发布渠道占位符**。
 *
 * 13 票的实况:仓库无 remote、无发布渠道(GitHub Releases / 自建对象存储都还没定),
 * 所以这里给的是一个**注定连不上**的地址(`.invalid` 是 RFC 2606 保留的顶级域,永远解析不了)。
 * 这样"渠道未定"是一条**会当场失败并给出指引**的事实,而不是一个看起来能用、点下去 404 的假地址。
 * 安装脚本认同一个常量(有断言对着),渠道定下来时改这一处 + 脚本那一处,断言逼着两边同时改。
 */
export const RELEASE_CHANNEL_PLACEHOLDER = "https://RELEASE-CHANNEL-UNDECIDED.invalid/a2";

/**
 * 内核 bin 的平台表:平台键 → 资产名 + `bun build --compile --target=` 的目标名。
 *
 * 平台键的写法(`<os>-<arch>`,x64 而非 amd64)取自 **bun 自己的 target 命名**,不是 mihomo 的口径
 * (`src/mihomo/pin.ts::assetKey` 那边用 amd64,因为那是 mihomo 官方资产的命名)。
 * 两套命名各自对着各自的上游,不互相迁就 —— 硬凑成一套只会让"这个名字是谁的"变成谜。
 */
export const KERNEL_TARGETS = {
  "darwin-arm64": { asset: "a2-darwin-arm64", bunTarget: "bun-darwin-arm64" },
  "darwin-x64": { asset: "a2-darwin-x64", bunTarget: "bun-darwin-x64" },
  "linux-x64": { asset: "a2-linux-x64", bunTarget: "bun-linux-x64" },
  "linux-arm64": { asset: "a2-linux-arm64", bunTarget: "bun-linux-arm64" },
} as const satisfies Record<string, { asset: string; bunTarget: string }>;

export type KernelPlatform = keyof typeof KERNEL_TARGETS;

/**
 * 默认产出的平台。
 *
 * 只有这两个有**实测背书**:`darwin-arm64` 是本机原生编译(门禁每次都在跑),
 * `linux-x64` 是 13 票现场交叉编译出来并核过 ELF 文件头的那一份(**本机跑不了它**,只验产出)。
 * 另外两个平台的目标运行时本机没下过,不默认产出 —— 发布元数据里出现一个没人验过的资产,
 * 比少一个平台危险得多。要加就显式 `--targets`。
 */
export const DEFAULT_TARGETS: KernelPlatform[] = ["darwin-arm64", "linux-x64"];

export const ARTIFACT_KINDS = [
  "kernel-bin",
  "panel-app",
  "notice",
  "license",
  "installer",
] as const;

export const ReleaseArtifactSchema = z.object({
  name: z.string().min(1),
  kind: z.enum(ARTIFACT_KINDS),
  /** 只有 `kernel-bin` / `panel-app` 有平台。 */
  platform: z.string().min(1).optional(),
  /** 小写十六进制 SHA-256(安装脚本逐字比对这一串)。 */
  sha256: z.string().regex(/^[0-9a-f]{64}$/),
  bytes: z.number().int().nonnegative(),
});
export type ReleaseArtifact = z.infer<typeof ReleaseArtifactSchema>;

export const ReleaseManifestSchema = z
  .object({
    schema: z.literal(RELEASE_SCHEMA_ID),
    product: z.literal(PRODUCT_NAME),
    version: z.string().min(1),
    generatedAt: z.string().min(1),
    channel: z.object({
      /** 资产的下载根地址;仍是占位符时 `status` 为 `undecided`。 */
      base: z.string().min(1),
      status: z.enum(["undecided", "configured"]),
      note: z.string().min(1),
    }),
    /** **06 票安装档的版本源**。`bundled: false` 与 `AboutResult` 那条同一个承诺。 */
    mihomo: z.object({
      lockedVersion: z.string().min(1),
      license: z.literal("GPL-3.0"),
      source: z.string().min(1),
      releases: z.string().min(1),
      licenseUrl: z.string().min(1),
      bundled: z.literal(false),
    }),
    artifacts: z.array(ReleaseArtifactSchema).min(1),
  })
  .superRefine((manifest, ctx) => {
    const names = manifest.artifacts.map((artifact) => artifact.name);
    if (new Set(names).size !== names.length) {
      ctx.addIssue({ code: "custom", message: "发布包里出现了重名工件(下载时无从区分)。" });
    }
    const count = (kind: (typeof ARTIFACT_KINDS)[number]) =>
      manifest.artifacts.filter((artifact) => artifact.kind === kind).length;

    if (count("kernel-bin") < 1) {
      ctx.addIssue({ code: "custom", message: "发布包里一个内核 bin 都没有。" });
    }
    // GPL 义务的结构守卫:声明文本与许可证全文各恰好一份,少一份就发不出去。
    if (count("notice") !== 1) {
      ctx.addIssue({
        code: "custom",
        message: `发布包必须恰好带一份外部程序声明(${NOTICE_FILE_NAME}),现在有 ${count("notice")} 份。`,
      });
    }
    if (count("license") !== 1) {
      ctx.addIssue({
        code: "custom",
        message: `发布包必须恰好带一份 GPL-3.0 全文(${GPL_LICENSE_FILE_NAME}),现在有 ${count("license")} 份。`,
      });
    }
    for (const artifact of manifest.artifacts) {
      if (artifact.kind === "kernel-bin") {
        const platform = artifact.platform as KernelPlatform | undefined;
        if (platform === undefined || !(platform in KERNEL_TARGETS)) {
          ctx.addIssue({
            code: "custom",
            message: `内核 bin ${artifact.name} 的 platform 不在已登记平台表里:${String(artifact.platform)}`,
          });
          continue;
        }
        if (KERNEL_TARGETS[platform].asset !== artifact.name) {
          ctx.addIssue({
            code: "custom",
            message:
              `内核 bin 的资产名与平台对不上:${artifact.name} vs ${KERNEL_TARGETS[platform].asset}` +
              "(安装脚本按平台键找资产名,对不上就下错文件)。",
          });
        }
      }
    }
  });
export type ReleaseManifest = z.infer<typeof ReleaseManifestSchema>;

/**
 * 文件名 → 它在发布包里是什么。**认不出就报错**(不许有来路不明的文件混进发布物)。
 *
 * `panel-app` 的名字形如 `A2-Panel-0.1.0-macos.zip`:`.app` 是个目录,要进"一个工件一个摘要"
 * 的元数据就必须先压成单个文件。
 */
export function classifyArtifact(
  name: string,
): { kind: (typeof ARTIFACT_KINDS)[number]; platform?: string } | undefined {
  for (const [platform, target] of Object.entries(KERNEL_TARGETS)) {
    if (target.asset === name) return { kind: "kernel-bin", platform };
  }
  if (name === NOTICE_FILE_NAME) return { kind: "notice" };
  if (name === GPL_LICENSE_FILE_NAME) return { kind: "license" };
  if (name === INSTALLER_FILE_NAME) return { kind: "installer" };
  if (/^A2-Panel-.+-macos\.zip$/.test(name)) return { kind: "panel-app", platform: "darwin" };
  return undefined;
}

/** SHA-256(小写十六进制)—— 与安装脚本里 `shasum -a 256` / `sha256sum` 比对的是同一串。 */
export async function sha256Of(file: string): Promise<string> {
  const hasher = new Bun.CryptoHasher("sha256");
  hasher.update(await Bun.file(file).arrayBuffer());
  return hasher.digest("hex");
}

export interface BuildManifestOptions {
  /** 发布包目录(元数据文件本身若已在里面,会被跳过)。 */
  dir: string;
  version: string;
  /** 缺省取当前时刻(ISO 8601)。 */
  generatedAt?: string;
  /** 渠道根地址;缺省是占位符(渠道未定)。 */
  channelBase?: string;
}

/** 扫描发布包目录,算摘要,拼出(并**校验**)一份元数据。 */
export async function buildReleaseManifest(
  options: BuildManifestOptions,
): Promise<ReleaseManifest> {
  const entries = readdirSync(options.dir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && entry.name !== RELEASE_METADATA_FILE)
    .map((entry) => entry.name)
    .sort();

  const artifacts: ReleaseArtifact[] = [];
  for (const name of entries) {
    const classified = classifyArtifact(name);
    if (classified === undefined) {
      throw new Error(
        `发布包里有一个不认识的文件:${name}。` +
          "发布物是要被 curl 下来执行的东西 —— 每一个文件都必须在 classifyArtifact 的表上有名字。",
      );
    }
    const file = path.join(options.dir, name);
    artifacts.push({
      name,
      kind: classified.kind,
      ...(classified.platform === undefined ? {} : { platform: classified.platform }),
      sha256: await sha256Of(file),
      bytes: statSync(file).size,
    });
  }

  const base = options.channelBase ?? RELEASE_CHANNEL_PLACEHOLDER;
  const undecided = base === RELEASE_CHANNEL_PLACEHOLDER;
  return ReleaseManifestSchema.parse({
    schema: RELEASE_SCHEMA_ID,
    product: PRODUCT_NAME,
    version: options.version,
    generatedAt: options.generatedAt ?? new Date().toISOString(),
    channel: {
      base,
      status: undecided ? "undecided" : "configured",
      note: undecided
        ? "发布渠道尚未确定(13 票记为人工项)。把 A2_RELEASE_BASE 指到实际地址(或本地目录的 file:// 路径)即可安装。"
        : "资产按 <base>/<工件名> 取;安装脚本先取本文件,再据其中的 sha256 校验下载物。",
    },
    mihomo: {
      lockedVersion: MIHOMO_LOCKED_VERSION,
      license: "GPL-3.0",
      source: MIHOMO_PROJECT_URL,
      releases: MIHOMO_RELEASE_BASE,
      licenseUrl: GPL3_TEXT_URL,
      bundled: false,
    },
    artifacts,
  });
}

/**
 * 渲染成 JSON 文本。**每个工件一行**,这是一条与安装脚本的约定:
 * 那边是一个 POSIX sh 脚本,没有 jq 可用(不能要求用户先装一个 JSON 解析器才能装 a2),
 * 于是它用 `grep` 找到"平台对得上的那一行",再用 `sed` 抠出 name 与 sha256。
 * 把工件对象拆成多行会让那条 grep 拿不到完整信息 —— 所以这条格式约定有测试钉着
 * (`release-manifest.test.ts` ▸ 每个工件恰好一行 + 安装脚本真的解得出来)。
 */
export function renderReleaseManifest(manifest: ReleaseManifest): string {
  const { artifacts, ...head } = manifest;
  const headJson = JSON.stringify(head, null, 2);
  const body = artifacts.map((artifact) => `    ${JSON.stringify(artifact)}`).join(",\n");
  return `${headJson.slice(0, -2)},\n  "artifacts": [\n${body}\n  ]\n}\n`;
}
