// mihomo 的**锁版事实**:装哪个版本、从哪儿拿、拿到之后拿什么校验、以及"低于多少就不认"。
//
// 为什么单独一个文件:这几个值是 06 票唯一会被人问「凭什么是这个数」的地方,必须一处成文、一处可改。
// 「升级永远显式」这条决策的技术含义就是:**没有任何代码路径会绕过这里的 `MIHOMO_LOCKED_VERSION`**——
// 下载只下这一版,升级也只升到这一版,想换版本得改这个常量并重新发布内核。
//
// mihomo **不随任何分发物打包**(ADR 0007 修订版 / spec):这里只有元数据,仓库里没有那 42MiB 的二进制。

/**
 * 锁定版本。
 *
 * **出处**:`kernel/contract/MIHOMO-VERSION.txt` 首行 `Mihomo Meta v1.19.28 darwin arm64` ——
 * (该文件原在 `Sources/PluginProxy/Resources/`,10 票旧 Swift 面退场时搬到这里 —— 锁版事实自此完全归内核。)
 * 那是旧仓随包分发过、且被旧门禁逐字节校验过的那一份,是本仓库里唯一一个**有实测背书**的版本。
 * (研究文档 `docs/research/mihomo-integration.md` §7 记录 v1.19.29 是当时的最新稳定版,但我们没有它的
 * 校验和实测背书 —— 锁版必须锁到能验的那一版,而不是最新的那一版。换版是一次显式决策,连同下面的摘要表一起改。)
 */
export const MIHOMO_LOCKED_VERSION = "v1.19.28";

// 兼容地板(`MIHOMO_COMPAT_FLOOR` / `versionShortfall`)随 14 票退场:embedded 一律跑内核自己下的
// 锁定版(版本由 `MIHOMO_LOCKED_VERSION` 说了算),而别人那份的版本内核只如实报告、不做达标裁定 ——
// 「不接管、不复用」之后,一条"你那份太旧"的判词既无处施加也无人负责。

/** 官方发布渠道(`A2_MIHOMO_RELEASE_BASE` 可覆写 —— 镜像源与测试都靠它)。 */
export const MIHOMO_RELEASE_BASE = "https://github.com/MetaCubeX/mihomo/releases";

/**
 * 锁定版各平台资产的 **SHA-256(解压后的可执行本体)**。
 *
 * `darwin-arm64` 那条是当年对随包那份二进制 `shasum -a 256` 现场核对过的(二进制已随 10 票退场 ——
 * ADR 0007 修订版起不再分发 GPL 二进制),
 * 与 `MIHOMO-VERSION.txt` 的 `SHA-256:` 行一致。**其余平台留空是有意的**:没有可信摘要就没有可信安装 ——
 * 内核在那些平台上 fail-closed 拒绝下载并给出指引,而不是"先装了再说"。补表的方式写在拒绝报文里。
 */
export const MIHOMO_ASSET_DIGESTS: Readonly<Record<string, string>> = {
  "darwin-arm64": "55b7286331cb30a54b2564013b02b84a0c280e8b690bd1e5da4b9d4f4ca007ac",
};

/** 本机的资产键(`<os>-<arch>`,官方资产命名口径:amd64 而非 x64)。 */
export function assetKey(
  platform: string = process.platform,
  arch: string = process.arch,
): string {
  const os = platform === "darwin" ? "darwin" : platform === "linux" ? "linux" : platform;
  const cpu = arch === "x64" ? "amd64" : arch === "arm64" ? "arm64" : arch;
  return `${os}-${cpu}`;
}

/** 官方资产文件名:`mihomo-darwin-arm64-v1.19.28.gz`。 */
export function assetFileName(key: string, version: string = MIHOMO_LOCKED_VERSION): string {
  return `mihomo-${key}-${version}.gz`;
}

/** 完整下载地址。 */
export function assetUrl(
  key: string,
  version: string = MIHOMO_LOCKED_VERSION,
  base: string = MIHOMO_RELEASE_BASE,
): string {
  return `${base.replace(/\/+$/, "")}/download/${version}/${assetFileName(key, version)}`;
}

/**
 * 从 `mihomo -v` 或 `/version` 的应答里抠出版本号,统一成 `v1.19.28` 形态。
 * 认得的两种形态:`Mihomo Meta v1.19.28 darwin arm64 with gc go1.24.5 …` 与裸的 `v1.19.28` / `1.19.28`。
 */
export function parseVersion(text: string): string | undefined {
  const match = /v?(\d+\.\d+(?:\.\d+)?(?:[-.\w]*)?)/.exec(text.trim());
  return match ? `v${match[1]}` : undefined;
}

/** 版本比较:a < b → 负,a > b → 正。只比数字段,预发布后缀(`-alpha` 等)忽略。 */
export function compareVersions(a: string, b: string): number {
  const parts = (v: string) =>
    v.replace(/^v/, "").split(/[-+]/)[0]!.split(".").map((n) => Number.parseInt(n, 10) || 0);
  const left = parts(a);
  const right = parts(b);
  for (let i = 0; i < Math.max(left.length, right.length); i += 1) {
    const diff = (left[i] ?? 0) - (right[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}
