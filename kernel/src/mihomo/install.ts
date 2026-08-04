// 就位的那几件实事:建数据目录、写配置、把二进制弄到 a2 自己的落点上。
//
// 「脚本化安装」在这里是**内核自己做**,而不是再出一个 shell 安装脚本 —— 摘要校验、失败指引与错误码
// 必须与内核同源,在 shell 里重写一遍就是第二份会漂移的事实源。对外的形态不变:一条显式命令
// (`a2 mihomo install`)从官方渠道拉锁定版、校验、落位。
//
// 三条硬性质,顺序即安全语义:
//   1. **先验后落**:摘要对不上时磁盘上一个字节都没写过(不留半成品二进制);
//   2. **没有可信摘要就不装**(fail-closed):本平台没登记摘要 → 结构化拒绝 + 指引,不"先装了再说";
//   3. **只读复用别人的二进制** = 建一个指向它的符号链接,内核从不写、不改、不移动那个真身。

import { chmod, lstat, mkdir, readlink, rename, stat, symlink, unlink, writeFile } from "node:fs/promises";
import path from "node:path";
import { ErrorCode, type Guidance, type WireError } from "../contract/wire.ts";
import { MihomoEnv, readControllerFromConfig, type MihomoLayout } from "./paths.ts";
import {
  assetKey,
  assetUrl,
  MIHOMO_ASSET_DIGESTS,
  MIHOMO_LOCKED_VERSION,
  MIHOMO_RELEASE_BASE,
} from "./pin.ts";

/** 数据目录权限:里面有 secret 与缓存,不给外人看(与 `<home>/run` 同档)。 */
const DATA_DIR_MODE = 0o700;
const BINARY_MODE = 0o755;
const CONFIG_MODE = 0o600;

/** 就位过程中的可预期失败。manager 把它翻成 `OpOutcome`;**永远带指引**。 */
export class MihomoOperationError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly detail: string,
    readonly guidance: Guidance,
  ) {
    super(message);
    this.name = "MihomoOperationError";
  }

  toWireError(): WireError {
    return { code: this.code, message: this.message, detail: this.detail, guidance: this.guidance };
  }
}

/**
 * 收编记录 —— **收编档唯一会落盘的东西**,而且只落在 a2 自己的 home 里。
 *
 * 为什么非要有它:「被收编的实例死了要报警」这句话得有主语。没有记录的话,内核无从区分
 * 「我收编过的那个实例没了」与「这台机器上本来就没有跑着的 mihomo」—— 后者该顺势走复用/安装档,
 * 前者必须停下来报警 + 指路(票面第 2 条:内核不越权重拉)。
 */
export interface MihomoAdoption {
  controller: string;
  configFile?: string;
  adoptedAt: string;
}

function adoptionFile(layout: MihomoLayout): string {
  return path.join(layout.dataDir, "adopted.json");
}

export async function readAdoption(layout: MihomoLayout): Promise<MihomoAdoption | undefined> {
  const text = await Bun.file(adoptionFile(layout)).text().catch(() => undefined);
  if (text === undefined) return undefined;
  try {
    const parsed = JSON.parse(text) as Partial<MihomoAdoption>;
    return typeof parsed.controller === "string" && parsed.controller.length > 0
      ? {
          controller: parsed.controller,
          ...(typeof parsed.configFile === "string" ? { configFile: parsed.configFile } : {}),
          adoptedAt: typeof parsed.adoptedAt === "string" ? parsed.adoptedAt : "",
        }
      : undefined;
  } catch {
    return undefined;
  }
}

/** 记下收编对象。已经记着同一个就什么都不做(幂等)。 */
export async function recordAdoption(
  layout: MihomoLayout,
  adoption: Omit<MihomoAdoption, "adoptedAt">,
): Promise<boolean> {
  const current = await readAdoption(layout);
  if (current?.controller === adoption.controller && current.configFile === adoption.configFile) {
    return false;
  }
  await mkdir(layout.dataDir, { recursive: true, mode: DATA_DIR_MODE });
  await chmod(layout.dataDir, DATA_DIR_MODE);
  await writeFile(
    adoptionFile(layout),
    `${JSON.stringify({ ...adoption, adoptedAt: new Date().toISOString() }, null, 2)}\n`,
    { mode: CONFIG_MODE },
  );
  return true;
}

/** 解除收编。返回是否**本次**真的删掉了记录。 */
export async function releaseAdoption(layout: MihomoLayout): Promise<boolean> {
  if ((await readAdoption(layout)) === undefined) return false;
  await removeIfPresent(adoptionFile(layout));
  return true;
}

/** 建 a2 自管的数据目录。已在则什么都不做(返回是否**本次**建的 —— 幂等的可观察面靠它)。 */
export async function ensureDataDir(layout: MihomoLayout): Promise<boolean> {
  const created = !(await dirExists(layout.dataDir));
  await mkdir(layout.dataDir, { recursive: true, mode: DATA_DIR_MODE });
  // mkdir 的 mode 会被 umask 削,建完补一次(与 `<home>/run` 同一处理)。
  await chmod(layout.dataDir, DATA_DIR_MODE);
  return created;
}

/**
 * 落一份已经渲染好的 a2 自管配置。**逐字比较,有差才写** —— 幂等("这次什么都没改")的判据就是它。
 *
 * 渲染本身在 `src/proxy/config.ts`(它要读可调项与激活订阅);本函数只管"写不写、怎么写"。
 * secret 的留存不在这里做,而在渲染那一侧(`currentSecret()` 现读磁盘那份)—— 换钥匙会把
 * 已连着的客户端踢掉,也让幂等不成立。
 */
export async function ensureConfig(layout: MihomoLayout, rendered: string): Promise<boolean> {
  const current = await Bun.file(layout.configPath)
    .text()
    .catch(() => undefined);
  if (current === rendered) return false;
  await mkdir(path.dirname(layout.configPath), { recursive: true, mode: DATA_DIR_MODE });
  await writeFile(layout.configPath, rendered, { mode: CONFIG_MODE });
  await chmod(layout.configPath, CONFIG_MODE);
  return true;
}

/**
 * 自管配置里此刻那把钥匙:磁盘上有就用它,没有就现造一把。
 * **不写盘** —— 写盘是 `ensureConfig` 的事,这里只负责"别把钥匙换了"。
 */
export async function currentSecret(layout: MihomoLayout): Promise<string> {
  const current = await Bun.file(layout.configPath)
    .text()
    .catch(() => undefined);
  return (current ? readControllerFromConfig(current)?.secret : undefined) ?? newSecret();
}

/**
 * 只读复用:在 a2 落点上建一个指向既有二进制的符号链接。
 * 已经指对了就什么都不做;指错了(或那儿是别的东西)就换掉 —— 换的永远是链接,不是它指向的真身。
 */
export async function linkForeignBinary(layout: MihomoLayout, target: string): Promise<boolean> {
  const resolved = path.resolve(target);
  const current = await currentLinkTarget(layout.binaryPath);
  if (current === resolved) return false;
  await mkdir(layout.binDir, { recursive: true, mode: DATA_DIR_MODE });
  await removeIfPresent(layout.binaryPath);
  await symlink(resolved, layout.binaryPath);
  return true;
}

/**
 * 按锁定版下载 + 校验 + 落位。**校验通过之前不往落点写任何东西。**
 * `A2_MIHOMO_RELEASE_BASE` 覆写发布渠道(镜像源 / 测试夹具),
 * `A2_MIHOMO_EXPECT_SHA256` 覆写期望摘要(仅测试与诊断 —— 生产走 `pin.ts` 的摘要表)。
 */
export async function downloadLockedBinary(
  layout: MihomoLayout,
  env: Record<string, string | undefined> = process.env,
): Promise<void> {
  const key = env[MihomoEnv.assetKey]?.trim() || assetKey();
  const expected = env[MihomoEnv.expectSha256]?.trim() || MIHOMO_ASSET_DIGESTS[key];
  if (!expected) {
    throw new MihomoOperationError(
      `本平台(${key})没有登记锁定版 mihomo 的校验摘要,已拒绝下载。`,
      ErrorCode.mihomoOperationFailed,
      `内核只安装能验的东西:${MIHOMO_LOCKED_VERSION} 的摘要表里没有 ${key} 这一项。`,
      {
        summary: "没有可信摘要就没有可信安装。要么复用一份你自己验过的二进制,要么让内核补上这一项。",
        steps: [
          {
            description: "自己下载并核对官方摘要后,把它放到 PATH 上,再让 a2 只读复用它",
            command: `a2 mihomo status --json`,
          },
          {
            description: "或指定一份已有二进制所在目录后重跑安装(只读复用,内核不会改它)",
            command: `${MihomoEnv.binDirs}=/your/bin/dir a2 mihomo install --json`,
          },
        ],
        context: { platform: key, lockedVersion: MIHOMO_LOCKED_VERSION },
      },
    );
  }

  const base = env[MihomoEnv.releaseBase]?.trim() || MIHOMO_RELEASE_BASE;
  const url = assetUrl(key, MIHOMO_LOCKED_VERSION, base);

  let compressed: Uint8Array<ArrayBuffer>;
  try {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    compressed = new Uint8Array(await response.arrayBuffer());
  } catch (error) {
    throw new MihomoOperationError(
      "从发布渠道取锁定版 mihomo 失败。",
      ErrorCode.mihomoOperationFailed,
      `GET ${url} 失败:${String(error)}`,
      downloadGuidance(url),
    );
  }

  // 类型断言的唯一理由:`Bun.gunzipSync` 声明成 `Uint8Array<ArrayBufferLike>`,而 CryptoHasher 只收
  // `Uint8Array<ArrayBuffer>`。运行时永远是普通 ArrayBuffer(SharedArrayBuffer 到不了这里),
  // 拷一份只为过类型检查是白花 40MiB。
  let binary: Uint8Array<ArrayBuffer>;
  try {
    binary = Bun.gunzipSync(compressed) as Uint8Array<ArrayBuffer>;
  } catch (error) {
    throw new MihomoOperationError(
      "下载到的资产不是合法的 gzip 资产。",
      ErrorCode.mihomoOperationFailed,
      `解压 ${url} 失败:${String(error)}`,
      downloadGuidance(url),
    );
  }

  const actual = new Bun.CryptoHasher("sha256").update(binary).digest("hex");
  if (actual !== expected) {
    throw new MihomoOperationError(
      "下载物的 SHA-256 与锁定版摘要不符,已拒绝落位。",
      ErrorCode.mihomoOperationFailed,
      `期望 ${expected},实际 ${actual}(来源 ${url})。磁盘上未写入任何内容。`,
      {
        summary: "摘要不符只有两种可能:渠道被改了,或锁定版元数据过时了。两种都不该由内核自作主张。",
        steps: [
          { description: "换回官方渠道再试一次", command: "a2 mihomo install --json" },
          { description: "查当前锁定版与本机现状", command: "a2 mihomo status --json" },
        ],
        context: { url, expectedSha256: expected, actualSha256: actual },
      },
    );
  }

  // 先落临时文件再原子改名:中途失败也不会留下一个"看起来装好了"的半成品。
  await mkdir(layout.binDir, { recursive: true, mode: DATA_DIR_MODE });
  const staging = `${layout.binaryPath}.download`;
  await writeFile(staging, binary, { mode: BINARY_MODE });
  await chmod(staging, BINARY_MODE);
  await removeIfPresent(layout.binaryPath);
  await rename(staging, layout.binaryPath);
}

function downloadGuidance(url: string): Guidance {
  return {
    summary: "内核只从锁定版渠道取二进制,不会退而求其次。先确认网络/渠道可达,再重跑(幂等)。",
    steps: [
      { description: "手动确认这个资产能取到", command: `curl -fsSLI ${url}` },
      { description: "确认后重跑安装(幂等)", command: "a2 mihomo install --json" },
      {
        description: "或复用一份已有二进制(只读复用,内核不会改它)",
        command: "a2 mihomo status --json",
      },
    ],
    context: { url, lockedVersion: MIHOMO_LOCKED_VERSION },
  };
}

function newSecret(): string {
  return crypto.randomUUID().replaceAll("-", "");
}

async function currentLinkTarget(link: string): Promise<string | undefined> {
  try {
    const info = await lstat(link);
    if (!info.isSymbolicLink()) return undefined;
    return path.resolve(path.dirname(link), await readlink(link));
  } catch {
    return undefined;
  }
}

async function removeIfPresent(file: string): Promise<void> {
  try {
    await unlink(file);
  } catch {
    /* 本来就没有 */
  }
}

async function dirExists(dir: string): Promise<boolean> {
  try {
    return (await stat(dir)).isDirectory();
  } catch {
    return false;
  }
}
