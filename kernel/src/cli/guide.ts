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

import { GuideResultSchema, opSuccess } from "../contract/wire.ts";
import { KERNEL_VERSION } from "../runtime/version.ts";
import { outcomeFromOpOutcome, type CommandOutcome } from "./outcome.ts";
import { GUIDE_USAGE, guideUsageOutcome, helpOutcome } from "./usage.ts";

/** 说明全文(08 票逐字定稿)。第一读者是 agent,人以第三人称出现。 */
export const GUIDE_TEXT = `【给 AI 助手的 A2 使用说明】(A2 内核 ${KERNEL_VERSION})

本机装有 A2——agent-first 的代理管理工具。用户期望你通过它了解并管理本机代理。

■ 调用方式
· CLI 完整路径:~/.a2/bin/a2(刻意不在 PATH 上,请始终用完整路径调用)
· 每条命令都加 --json:stdout 只有一条 JSON 包封,成功失败同一形状;失败时读 error.code 与 error.guidance——guidance 里有修复步骤与命令原文,照做即可。
· 全貌以本机为准:~/.a2/bin/a2 help;~/.a2/bin/a2 capabilities list --json

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

/** 同步返回:这条命令的全部事实都在编译进 bin 的那段文本里,没有任何 I/O 可等。 */
export function guideCommand(args: string[]): CommandOutcome {
  if (args[0] === "--help" || args[0] === "-h") return helpOutcome(GUIDE_USAGE);
  if (args.length > 0) {
    return guideUsageOutcome(`guide 不接受多余参数:${args.join(" ")}`);
  }
  return outcomeFromOpOutcome(
    opSuccess({ text: GUIDE_TEXT }),
    "guide",
    GuideResultSchema,
    (result) => result.text,
  );
}
