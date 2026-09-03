#!/usr/bin/env bun
// a2 CLI 入口。一个编译产物多模式(ADR 0010):默认 CLI 子命令,`a2 daemon run` 进常驻模式。
//
// 纪律(ADR 0005/0008):永不交互阻塞、无 `--yes` 旁路、`--json` 时 stdout 只有一条 JSON 包封。

import { ExitCode } from "../contract/exit-codes.ts";
import { PROTOCOL_VERSION, successResponse } from "../contract/wire.ts";
import { resolvePaths } from "../runtime/paths.ts";
import { KERNEL_VERSION } from "../runtime/version.ts";
import { aboutCommand } from "./about.ts";
import { capabilitiesCommand } from "./capabilities.ts";
import { daemonRunCommand } from "./daemon.ts";
import { domainCommand } from "./domain.ts";
import { guideCommand } from "./guide.ts";
import { mihomoCommand } from "./mihomo.ts";
import { emitOutcome, type CommandOutcome } from "./outcome.ts";
import { pluginCommand } from "./plugin.ts";
import { serviceCommand } from "./service.ts";
import { statusCommand } from "./status.ts";
import { normalizeUrlRouterArgs } from "./url-router.ts";
import { USAGE, helpOutcome, usageOutcome } from "./usage.ts";

/** argv(不含 argv0/argv1)→ 结果。**不**碰进程状态,好让下面那三行决定怎么输出、怎么退出。 */
async function dispatch(argv: string[]): Promise<CommandOutcome> {
  const [command, ...args] = argv.filter((arg) => arg !== "--json");

  // 光敲 `a2` 不是"帮我打印帮助",是"我没说要干什么" —— 照用法错处理(ok=false + 退出码 1),
  // 免得 agent 读到 ok=true 却拿到非零退出码。
  if (command === undefined) return usageOutcome("缺少子命令。");
  if (command === "help" || command === "-h" || command === "--help") return helpOutcome(USAGE);
  if (command === "version" || command === "-V" || command === "--version") {
    // 版本不走 daemon,但机读面一视同仁:`--json` 下照样是一条包封(result 形状见 wire.ts 的 VersionResult)。
    // 人类面仍是裸版本号,脚本里的 `$(a2 version)` 不会突然变成一坨 JSON。
    return {
      envelope: successResponse(crypto.randomUUID(), {
        version: KERNEL_VERSION,
        protocol: PROTOCOL_VERSION,
      }),
      human: KERNEL_VERSION,
      exitCode: ExitCode.success,
    };
  }
  // GPL 义务的必有落点(13 票 / ADR 0007 修订版)。与 version/help 同类:**不经 daemon** ——
  // 声明必须在 daemon 没装、没跑的时候一样读得到。
  if (command === "about") {
    return aboutCommand(args);
  }
  // 给 AI 助手的使用说明(08 票)。与 version/help/about 同类:**不经 daemon、不碰网络** ——
  // 面板只给一句「先跑 a2 guide」的指针,全文永远来自当下这份 bin(说明随内核一起升级)。
  if (command === "guide") {
    // `--mihomo` 那一路要读本机现状(它的步骤**就是** `mihomo status` 的 guidance,同一个函数生成),
    // 于是要 paths;仍不经 daemon —— 现状读的是文件系统与只读探测。
    return await guideCommand(args, resolvePaths());
  }
  if (command === "status") {
    if (args.length > 0) return usageOutcome(`status 不接受多余参数:${args.join(" ")}`);
    return await statusCommand(resolvePaths());
  }
  if (command === "capabilities") {
    return await capabilitiesCommand(args, resolvePaths());
  }
  // 域子命令面(07 票):`a2 proxy on` 等价于 `a2 capabilities call proxy.system.enable`,
  // 别名表由 daemon 的注册表说了算 —— 这里不写死任何动作名。
  // 08 票加了 `arbitration`(仲裁面只读查询),走的是同一个解析器。
  if (command === "proxy" || command === "arbitration") {
    return await domainCommand(command, args, resolvePaths());
  }
  // url-router(02 票)走的**也是**那个解析器,只是先过一次纯 argv 改写:spec §4 给它定的写法
  // 带一个位置参数 URL 与一个 `--dry-run`(后者换的是能力,不是参数),与 `--名字 值` 不同形。
  // 改写之后一切照旧 —— 别名匹配、仲裁、渲染、退出码,一条都没有第二份实现。
  if (command === "url-router") {
    return await domainCommand(command, normalizeUrlRouterArgs(args), resolvePaths());
  }
  if (command === "service") {
    return await serviceCommand(args, resolvePaths());
  }
  if (command === "mihomo") {
    return await mihomoCommand(args, resolvePaths());
  }
  // 插件装载面(11 票)。**装载零闸**:这条路上没有任何确认闸 —— 危险性只在调用层把关
  // (`a2 capabilities call plugin.…` 撞上 dangerous 声明时自动走三层仲裁)。
  if (command === "plugin") {
    return await pluginCommand(args, resolvePaths());
  }
  if (command === "daemon") {
    if (args[0] !== "run" || args.length > 1) {
      return usageOutcome("daemon 只支持 run 子命令:a2 daemon run");
    }
    return await daemonRunCommand(resolvePaths());
  }
  return usageOutcome(`未知子命令:${command}`);
}

const argv = process.argv.slice(2);
const outcome = await dispatch(argv);
emitOutcome(outcome, argv.includes("--json"));
process.exit(outcome.exitCode);
