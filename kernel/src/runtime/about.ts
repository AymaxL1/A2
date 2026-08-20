// `a2 about` 的事实与正文 —— **GPL 义务的必有落点**(13 票,ADR 0007 修订版)。
//
// ============================================================================
// 为什么这份文本住在内核里,而不是一个随包的 .txt
// ============================================================================
// 义务面收缩为「调用外部程序」之后,要声明的东西有两类:
//   ① **结构事实**:调用了谁、什么许可、锁的哪一版、源码在哪、我们怎么调它(独立子进程红线);
//   ② **不依赖 UI 的落点**:Linux 无头端与 mac 终端一样能读到。
// 把正文写死在 bin 里,这两条就都成立了:随包静态文本是**本文件渲染出来的同一份字节**
// (`Scripts/release-assemble.sh` 跑 `a2 about` 落盘),`a2-panel` 的关于页是同一份声明的
// 可选呈现面(`Sources/A2PanelMacOS/A2AboutWindow.swift`,明写「权威落点是 a2 about」)。
// 于是三个呈现面**不可能各说各话** —— 它们要么是同一份字节,要么彼此指认。
//
// ============================================================================
// 锁版版本号的来源(APP-9 那条旧断言的新落点)
// ============================================================================
// `MIHOMO_LOCKED_VERSION` 来自 `src/mihomo/pin.ts`,而那个常量与 `kernel/contract/MIHOMO-VERSION.txt`
// 有一条同源断言守着(`cli-mihomo.test.ts` ▸ 锁版元数据与那份实测记录同源)。所以
// 「`a2 about` 报出的版本 ≡ MIHOMO-VERSION.txt」是**两跳传递**得来的,不需要第三份手抄。

import { existsSync } from "node:fs";
import path from "node:path";
import {
  PROTOCOL_VERSION,
  type AboutResult,
  type ExternalProgram,
  type NoticeFile,
} from "../contract/wire.ts";
import { MIHOMO_LOCKED_VERSION, MIHOMO_RELEASE_BASE } from "../mihomo/pin.ts";
import { KERNEL_VERSION } from "./version.ts";

/** 产品名(bin 名,也是品牌名 —— spec 命名节)。 */
export const PRODUCT_NAME = "a2";

/** mihomo 的项目与源码地址(GPL 的「源码获取指引」)。 */
export const MIHOMO_PROJECT_URL = "https://github.com/MetaCubeX/mihomo";

/** GPL-3.0 全文的公开地址。随包那份是同一份许可证的离线副本。 */
export const GPL3_TEXT_URL = "https://www.gnu.org/licenses/gpl-3.0.txt";

/** 随包静态文本的文件名(发布包里与 `a2` 同目录;`Scripts/release-assemble.sh` 负责落位)。 */
export const NOTICE_FILE_NAME = "NOTICE-external-programs.txt";
export const GPL_LICENSE_FILE_NAME = "LICENSE-mihomo-GPL-3.0.txt";

/**
 * **独立子进程红线的原文**(ADR 0007,与实现语言无关、与分发形态无关)。
 *
 * 旧仓把它挂在 `proxy.license` 能力上(APP-10「子进程红线原文经能力面暴露」);
 * 能力面要 daemon 在跑,而这条红线是**结构承诺**,不该只有 daemon 活着时才说得出口。
 * 落点因此改到 `a2 about`(ADR 0007 修订版明写)。
 */
export const SUBPROCESS_REDLINE =
  "a2 只以**独立子进程**运行 mihomo,控制面只走它的外部接口(本地 REST API / 配置文件)," +
  "**永不进程内链接**(含 c-archive / cgo 静态链接)。这条边界与实现语言无关,也不因分发形态而松动;" +
  "它同样适用于一切插件 —— 插件都是进程外子进程,能力只经协议白名单进出。";

/** a2 本体的许可口径。 */
export const PRODUCT_LICENSE =
  "a2 本体:未开源,保留所有权利。它**不包含、也不链接**任何 GPL 代码 —— " +
  "与 mihomo 的关系是「调用外部程序」(见下方红线),不是同一个可执行文件。";

/** 升级口径:**没有静默更新**,升级永远是显式动作。 */
export const UPGRADE_POLICY =
  "升级永远显式:重跑安装脚本(或直接换掉那个单文件 a2)即完成内核升级;" +
  "内嵌 mihomo 的版本锁死在 a2 里、随 a2 升级走(下次拉起前自动换成锁定版,没有独立的升级命令)。" +
  "a2 不做静默更新、不后台自查版本、不会在你不知情时替你升级任何**别人的**东西。";

/** 被调用的外部程序表。V1 只有一条,但形状是**表**——将来多一个外部程序,声明面不用改结构。 */
export function externalPrograms(): ExternalProgram[] {
  return [
    {
      name: "mihomo(Mihomo Meta)",
      role: "代理数据面(a2 只做配置、reload、存活探测与经系统 supervisor 的启停)",
      license: "GPL-3.0",
      lockedVersion: MIHOMO_LOCKED_VERSION,
      bundled: false,
      invocation: SUBPROCESS_REDLINE,
      source: MIHOMO_PROJECT_URL,
      releases: MIHOMO_RELEASE_BASE,
      licenseUrl: GPL3_TEXT_URL,
    },
  ];
}

/**
 * 随包静态文本应当在的位置 = **与 `a2` 同目录**。
 *
 * 编译产物里 `process.execPath` 就是那个单文件 bin 自己(Bun compile 的实测行为),
 * 所以"发布包里 a2 旁边应该躺着这两份文本"这句话是可以逐字检查的 —— `present` 就是那次检查。
 * (源码模式下 `process.execPath` 是 bun 自己,于是 `present` 恒为 false;那不是缺陷:
 *  源码模式本来就不是分发形态,而这条字段的用处正是**验一个发布包完不完整**。)
 */
export function distributionDir(): string {
  return path.dirname(process.execPath);
}

export function noticeFiles(dir: string = distributionDir()): NoticeFile[] {
  const entries: { name: string; purpose: string }[] = [
    {
      name: NOTICE_FILE_NAME,
      purpose: "外部程序声明的静态副本(与本命令输出同一份字节)",
    },
    {
      name: GPL_LICENSE_FILE_NAME,
      purpose: "mihomo 所用许可证 GPL-3.0 的全文(离线副本)",
    },
  ];
  return entries.map((entry) => {
    const file = path.join(dir, entry.name);
    return { ...entry, path: file, present: existsSync(file) };
  });
}

/**
 * 外部程序声明的**静态正文**。这段文字就是 GPL 义务履行本身:
 * 声明调用了什么、它是什么许可、源码怎么拿、我们怎么调它、以及我们**不分发**它。
 */
export function renderDeclaration(programs: ExternalProgram[] = externalPrograms()): string {
  const lines: string[] = [
    "── 外部程序声明 ──────────────────────────────────────",
    "",
    PRODUCT_LICENSE,
    "",
    "a2 会调用下列**外部**程序。它们不随任何 a2 分发物打包,由你的显式命令获取,",
    "或复用你机器上已有的那一份:",
    "",
  ];
  for (const program of programs) {
    lines.push(
      `  ${program.name} —— ${program.role}`,
      `    许可证    ${program.license}(全文:${program.licenseUrl})`,
      `    锁定版本  ${program.lockedVersion}(安装脚本只装这一版;换版本是一次显式决策)`,
      `    源码获取  ${program.source}`,
      `    发布渠道  ${program.releases}`,
      `    随包分发  否 —— a2 的任何分发物(单文件 bin、安装脚本包、A2 Panel.app)都不含它的二进制`,
      `    调用方式  ${program.invocation}`,
      "",
    );
  }
  lines.push(
    "本声明不依赖任何 UI:`a2 about` 是它的权威落点,发布包里另有一份同样内容的静态文本,",
    "菜单栏壳「A2 Panel」的关于页只是同一份声明的可选呈现面。",
  );
  return lines.join("\n");
}

/** `a2 about --json` 的 result:机读面与人类面同源。 */
export function buildAbout(dir: string = distributionDir()): AboutResult {
  const programs = externalPrograms();
  return {
    product: PRODUCT_NAME,
    version: KERNEL_VERSION,
    protocol: PROTOCOL_VERSION,
    license: PRODUCT_LICENSE,
    externalPrograms: programs,
    declaration: renderDeclaration(programs),
    noticeFiles: noticeFiles(dir),
    upgrade: UPGRADE_POLICY,
  };
}

/**
 * 人类面(也是随包静态文本的正文):版本 → 声明 → 静态文本落点 → 升级口径。
 *
 * `Scripts/release-assemble.sh` 把这段输出原样落成 `NOTICE-external-programs.txt`,
 * 所以它必须是**自足**的:读这一份文本就够履行义务,不必再去别处找上下文。
 */
export function renderAbout(about: AboutResult): string {
  const lines = [
    `${about.product} ${about.version}(线协议 v${about.protocol})—— agent-first 的本机代理内核`,
    "",
    about.declaration,
    "",
    "── 随包静态文本(与 a2 同目录)────────────────────────",
    "",
  ];
  for (const file of about.noticeFiles) {
    lines.push(`  ${file.name}  ${file.purpose}`);
    // **人类面只说相对位置,不打绝对路径**(13 票 CR 必修 1b):这段输出会被组装脚本原样落成
    // 随包的 `NOTICE-external-programs.txt` —— 打绝对路径就等于把**组装机**的临时目录
    // (`/private/tmp/…`)烙进每一份分发物,而那条路径在用户机器上毫无意义、也不该被看见。
    // 机读面(`--json` 的 `noticeFiles[].path`)仍给展开后的绝对路径:那是给此刻这台机器上的
    // 脚本/agent 用的,不进分发物。
    lines.push(
      file.present
        ? "    与 a2 同目录,已就位"
        : "    **不在此处** —— 单文件直接下载时可从发布页单独取",
    );
  }
  lines.push("", "── 升级 ──────────────────────────────────────────────", "", `  ${about.upgrade}`);
  return lines.join("\n");
}
