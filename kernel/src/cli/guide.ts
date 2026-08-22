// `a2 guide` —— 给 AI 助手的 A2 使用说明**全文**(08 票)。
//
// 为什么它是一条 CLI 命令,而不是继续躺在面板的剪贴板里:说明要随内核一起升级。
// 05 票把全文放在面板生成(Swift 一份、TS 一份口径),于是每改一句都要两处对齐,
// 而拿到那段文字的 agent 还未必装着同一版内核。改判之后**内核自报**:面板只给一句指针
// (「先跑 ~/.a2/bin/a2 guide」),全文永远来自当下这份 bin。
//
// 与 version / help / about 同类:**无 op、不经 daemon、不碰网络** —— 一个还没把内核服务
// 装起来的 agent,恰恰最需要读到这份说明。
//
// 文中路径**写死 `~/.a2/bin/a2`**(不插值 A2_HOME):它是给用户贴进对话框的一段话,
// 而缺省安装就落在那里;自定义 A2_HOME 的人自己知道该换成什么,agent 照 status 的输出走即可。

import {
  GuideResultSchema,
  opSuccess,
  type Guidance,
  type MihomoStatusResult,
} from "../contract/wire.ts";
import { mihomoStatus } from "../mihomo/manager.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { KERNEL_VERSION } from "../runtime/version.ts";
import { outcomeFromOpOutcome, type CommandOutcome } from "./outcome.ts";
import { GUIDE_USAGE, guideUsageOutcome, helpOutcome } from "./usage.ts";

/** 说明全文(08 票逐字定稿)。第一读者是 agent,人以第三人称出现。 */
export const GUIDE_TEXT = `【给 AI 助手的 A2 使用说明】(A2 内核 ${KERNEL_VERSION})

本机装有 A2——agent-first 的代理管理工具。用户期望你通过它了解并管理本机代理。

■ 调用方式
· CLI 完整路径:~/.a2/bin/a2(刻意不在 PATH 上,请始终用完整路径调用)
· 用户若想在终端直接敲 a2:请转告 ta 自行加一行 export PATH="$HOME/.a2/bin:$PATH"(A2 刻意不改 shell 配置、不建 symlink——零 sudo、卸载才删得净;这是可选项,你自己始终用完整路径)
· 每条命令都加 --json:stdout 只有一条 JSON 包封,成功失败同一形状;失败时读 error.code 与 error.guidance——guidance 里有修复步骤与命令原文,照做即可。
· 全貌以本机为准:~/.a2/bin/a2 help;~/.a2/bin/a2 capabilities list --json

■ 读完后先给用户一个编号菜单
不要只回复「说明已读取」,也不要未经选择就开始改动。先把下面这份清单列给用户:
1. 安装或启用 mihomo 代理内核
2. 配置代理节点或导入订阅
3. 查看 A2、mihomo 与系统代理状态
4. 开启系统代理
5. 关闭并还原系统代理
6. 排查代理不可用、断网或节点异常
用户可以回复编号,也可以直接说需求。收到选择后继续完成该项,不要让用户自己找命令。
· 选 1 或 2:直接运行 ~/.a2/bin/a2 guide --mihomo,按其中基于本机现状生成的步骤继续;不要再让用户回到 Panel 复制「安装 mihomo」提示词。
· 选 3:运行下面三条 status 并用通俗话汇总。
· 选 4 或 5:先查看现状,再分别执行 proxy on 或 proxy off;涉及改变系统代理时先告诉用户将发生什么并确认。
· 选 6:先运行三条 status,根据返回的 error.guidance 或 guidance 继续排查。
纯只读检查可以直接做;下载、改配置或改变网络状态前,先向用户说明具体动作并征得同意。

■ 要把代理配起来(用户让你"配代理 / 装 mihomo"时,先读这个)
· ~/.a2/bin/a2 guide --mihomo    # 代理内核怎么回事 + **这台机器此刻**的下一步(随现状变)

■ 先了解现状(开工前各跑一次)
· ~/.a2/bin/a2 status --json          # 内核与服务状态
· ~/.a2/bin/a2 mihomo status --json   # 代理内核状态:含配置路径与下一步指引(guidance)——你的主要行动依据
· ~/.a2/bin/a2 proxy status --json    # 系统代理运行面

■ 常用命令
· ~/.a2/bin/a2 mihomo enable --mode=embedded --json   # 启用内置代理内核(须先与用户确认;将下载 mihomo,约 15 MB)
· ~/.a2/bin/a2 mihomo restart --json                  # 改完配置后重启生效
· ~/.a2/bin/a2 proxy on --json / ~/.a2/bin/a2 proxy off --json   # 接管/归还系统代理

■ 配置归你(agent)管
mihomo 的配置是一份 YAML,路径以 mihomo status 的输出为准。你可以直接读改它;改完执行 mihomo restart 生效。把机场订阅的节点合并进配置也是你的活:直接读订阅 YAML、把其中的节点(proxies)合并进配置——只搬节点与所需分组,不要把订阅里的 rules 整份搬来覆盖用户已有策略。

■ 边界(务必遵守)
· dangerous 档操作会被内核默拒并附「人类如何完成」的指引:转告用户,不要试图绕过。
· 本机若有用户自己装的 mihomo(非 A2 管理):不要动它——对它只读。`;

/**
 * `--mihomo` 的**静态半边**:把代理内核这件事讲清楚(它是什么、会发生什么、边界在哪)。
 *
 * 这里**刻意不写"第几步敲什么命令"** —— 那是 `mihomo status` 的 guidance 的活,而 guidance
 * 知道本机此刻的处境(还没启用?已经跑着但没节点?故障了?)。写死一份步骤在这里,等于把同一件事
 * 说两遍:改一处忘一处不说,它还会对着一台"早就配好了"的机器,永远劝人从头启用。
 * 于是这条命令的形态是:**静态散文 + 动态步骤**,后者由下面的 `renderGuidance` 从 guidance 现取。
 */
const MIHOMO_INTRO = `【给 AI 助手:把 A2 的代理配起来】

A2 用 mihomo 作代理内核。启用「内置模式」之后,mihomo 是 A2 内核服务的子进程:
随 A2 一起启动、一起退出,配置与保活都归 A2 管,用户不必自己伺候它。

要点(动手前先读):
· 首次启用会**下载** mihomo(约 15 MB,校验后落位)—— 下载、改配置这类动作,先征得用户同意。
· 配置是一份 YAML,路径以 \`mihomo status\` 的输出为准,**直接读改它就是你的活**;改完 restart 生效。
· 把机场订阅并进配置时**只搬节点**(proxies)与所需分组,别把订阅里的 rules 整份搬来覆盖用户已有策略。
· 用户本机若另有他自己装的 mihomo(非 A2 管理):不要动它 —— A2 对它只读,你也只读。
· 配好之后要不要接管系统代理(\`a2 proxy on\`),问过用户再说。

下面是**这台机器此刻**的下一步(由内核按现状生成,与 \`a2 mihomo status --json\` 里的 guidance 同源):`;

/** 把 guidance 渲染成人读的步骤块。**唯一的步骤出处**,壳与文档都不再各写一份。 */
function renderGuidance(guidance: Guidance | undefined): string {
  if (!guidance) {
    // 没有 guidance = 内核认为此刻无事可做(如 embedded 跑着、节点也配好了)。
    // 与其编一段假的下一步,不如如实说,并把"去哪看现状"给出来。
    return [
      "内核此刻没有给出下一步 —— 多半是代理已经配好在跑了。",
      "确认一眼:~/.a2/bin/a2 mihomo status --json",
    ].join("\n");
  }
  const lines = [guidance.summary, ""];
  guidance.steps.forEach((step, index) => {
    lines.push(`${index + 1}. ${step.description}`);
    if (step.command) lines.push(`   ~/.a2/bin/${step.command}`);
  });
  return lines.join("\n");
}

/**
 * `a2 guide` = A2 本身怎么用;`a2 guide --mihomo` = 怎么把代理配起来(2026-08-22 用户裁定的分工)。
 *
 * 前者是纯静态文本(没有 I/O 可等);后者要读一次本机现状,所以整条命令是 async。
 * 两者都**不经 daemon**:说明与指引必须在服务还没跑起来的时候就读得到。
 */
export async function guideCommand(args: string[], paths: KernelPaths): Promise<CommandOutcome> {
  if (args[0] === "--help" || args[0] === "-h") return helpOutcome(GUIDE_USAGE);

  const mihomo = args.includes("--mihomo");
  const rest = args.filter((arg) => arg !== "--mihomo");
  if (rest.length > 0) {
    return guideUsageOutcome(`guide 只认 --mihomo(收到多余参数:${rest.join(" ")})`);
  }

  if (!mihomo) {
    return outcomeFromOpOutcome(
      opSuccess({ text: GUIDE_TEXT }),
      "guide",
      GuideResultSchema,
      (result) => result.text,
    );
  }

  // 现状读不出来(极少见:文件系统层面的意外)也别让这条命令哑掉 —— 静态半边照样值得读,
  // 步骤那半边如实说"问不出来,去跑 status"。指引不许因为一次读失败就变成空白。
  const outcome = await mihomoStatus(paths);
  const status = outcome.ok ? (outcome.result as MihomoStatusResult) : undefined;
  const text = `${MIHOMO_INTRO}\n\n${
    status ? renderGuidance(status.guidance) : "(本机现状读取失败,请直接跑 ~/.a2/bin/a2 mihomo status --json 看它怎么说)"
  }`;
  return outcomeFromOpOutcome(
    opSuccess({ text }),
    "guide",
    GuideResultSchema,
    (result) => result.text,
  );
}
