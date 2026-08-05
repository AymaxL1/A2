// `a2 about` —— 版本、许可与外部程序声明(13 票)。
//
// **不经 daemon、不碰任何系统状态**:GPL 义务的落点不该依赖一个可能没装、没跑的进程
// (ADR 0007 修订版 + ADR 0008 第 4 条「义务落点必须 CLI 化」)。
// 机读面走的仍是全内核同一条模板(`outcomeFromOpOutcome` → 契约校验 → 退出码 → 人类面),
// agent 看不出这条命令没去过 UDS。

import { AboutResultSchema, opSuccess, payload } from "../contract/wire.ts";
import { buildAbout, renderAbout } from "../runtime/about.ts";
import { outcomeFromOpOutcome, type CommandOutcome } from "./outcome.ts";
import { aboutUsageOutcome, ABOUT_USAGE, helpOutcome } from "./usage.ts";

export function aboutCommand(args: string[]): CommandOutcome {
  if (args[0] === "--help" || args[0] === "-h") return helpOutcome(ABOUT_USAGE);
  if (args.length > 0) {
    return aboutUsageOutcome(`about 不接受多余参数:${args.join(" ")}`);
  }
  return outcomeFromOpOutcome(
    opSuccess(payload(buildAbout())),
    "about",
    AboutResultSchema,
    renderAbout,
  );
}
