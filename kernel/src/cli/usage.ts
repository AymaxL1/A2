// 帮助文本与用法错 —— CLI 的"可发现性"面。
//
// 用法错也照「拒绝即指引」办:错误报文里带的是**能直接敲的下一条命令**,而不是一句"请查看帮助"。

import { ExitCode } from "../contract/exit-codes.ts";
import { ErrorCode, failureResponse, successResponse } from "../contract/wire.ts";
// 帮助文本里的默认端口从常量插值 —— 帮助与实现是同一个数,改常量不会留下一句过时的散文。
import { A2_MIHOMO_CONTROLLER_PORT } from "../mihomo/paths.ts";
import { KERNEL_VERSION } from "../runtime/version.ts";
import { renderWireError, type CommandOutcome } from "./outcome.ts";

export const USAGE = `a2 ${KERNEL_VERSION} —— agent-first 的本机代理内核

用法:
  a2 [--json] <子命令> [参数]

子命令:
  status               查询 daemon 运行态(经 UDS 往返)
  capabilities …       能力面:list / describe <id> / call <id>(见 a2 capabilities --help)
  service …            常驻服务:install / uninstall / status(见 a2 service --help)
  mihomo …             mihomo 共存:status / install / uninstall / upgrade(见 a2 mihomo --help)
  daemon run           前台起常驻内核(调试用;开机自启请用 service 安装)
  help                 打印本帮助
  version              打印版本

全局参数:
  --json               机读输出:stdout 上只有一条 JSON 包封(成功与失败同一形状)
  -h, --help           同 help
  -V, --version        同 version

环境变量:
  A2_HOME              覆写 ~/.a2(socket 落 <A2_HOME>/run/kernel.sock)

退出码:0 成功 / 1 用法错 / 2 denied / 3 超时 / 4 daemon 不可达 / 5 能力业务失败 / 6 协议·校验错`;

export const CAPABILITIES_USAGE = `a2 capabilities —— 能力面(内核的唯一调用面)

用法:
  a2 [--json] capabilities list
  a2 [--json] capabilities describe <id>
  a2 [--json] capabilities call <id> [--input '<JSON 对象>']

参数:
  --input <JSON>       调用入参,必须是一个 JSON 对象(按参数名取值);不带等价于 {}

风险三档:
  safe                 只读,直通
  normal               可逆写,直通(零确认打断)
  dangerous            需真人在场证明;无确认器在场时结构化默拒(confirmation_unavailable,退出码 2),
                       拒绝报文自带「人类如何完成」的精确命令。永不交互阻塞,无 --yes 旁路。

退出码:0 成功 / 2 dangerous 被拒 / 4 daemon 不可达 / 5 能力业务失败 / 6 能力或参数不合契约 / 1 用法错`;

export const SERVICE_USAGE = `a2 service —— 常驻服务的显式安装(系统托管,应用层不造看门狗)

用法:
  a2 [--json] service install       装成系统托管的常驻服务并确保它跑着(幂等)
  a2 [--json] service uninstall     停掉并干净移除(幂等)
  a2 [--json] service status        查安装态与运行态(只读)

三条命令都不接受参数:unit 名恒为 com.a2.kernel,内核只碰这一个 unit。

托管形态:
  macOS                launchd user 域 agent(~/Library/LaunchAgents),KeepAlive.Crashed 自愈 + RunAtLoad 自启
  Linux                systemd user 单元(~/.config/systemd/user),Restart=on-failure 自愈 + WantedBy=default.target 自启

status 的三态(机读字段 result.state):
  not_installed         unit 文件不在,supervisor 也不认识它
  installed_not_running 装了,但此刻没有进程
  running               supervisor 报了 pid(取 supervisor 视角;"daemon 应不应答"请用 a2 status)

三态都是**查询成功**(退出码 0),状态在 result.state 里 —— 想要"没跑就非零退出"的判据请用 a2 status(退出码 4)。

环境变量:
  A2_HOME              覆写 ~/.a2;install 会把它写进 unit(supervisor 不读 shell 配置)
  A2_SERVICE_SUPERVISOR 覆写 supervisor 选择(launchd|systemd)。仅测试与诊断用

退出码:0 成功 / 1 用法错 / 5 操作失败(supervisor 报错、装完没跑起来)/ 6 本平台无已支持的 supervisor`;

export const MIHOMO_USAGE = `a2 mihomo —— mihomo 的获取与共存(数据面不随控制面起落)

用法:
  a2 [--json] mihomo status                检测本机现状与将采用的阶梯档位(只读)
  a2 [--json] mihomo install [--isolated]  按阶梯就位(幂等);--isolated = 不复用别人的,装 a2 自己那份
  a2 [--json] mihomo uninstall             卸掉 a2 自管的那份(unit + 进程;二进制/配置/数据保留)
  a2 [--json] mihomo upgrade               显式升级 a2 自管的二进制到锁定版

共存阶梯(检测并优先复用,复用到实例级):
  adopt_instance        有跑着的实例且 external-controller 可达 → 经 API 接管配置与存活监督;
                        **进程生死归原托管方** —— 内核绝不 stop/restart/kill 它,实例没了只报警 + 指引
  reuse_binary          只有二进制 → 只读复用它(落点上放一个符号链接,真身一个字节都不碰),
                        配置/数据目录与 com.a2.mihomo unit 全套自建
  managed_install       全无(或 --isolated)→ 按锁定版从官方渠道下载 + SHA-256 校验 + 落位,再挂 unit

兼容地板:被收编/被复用的那份不达地板时,内核**不擅自升级别人的东西** —— 收编档结构化拒绝并给两条明路,
复用档回退为隔离安装并在报文里说明原因(result.fallback)。

版本:锁定版由内核编译期常量固定;**任何路径都不静默换版本**,换版本只有 a2 mihomo upgrade 一条命令。

数据面不随控制面起落:com.a2.mihomo 与 com.a2.kernel 是两个独立 unit —— 卸内核不卸 mihomo,
内核崩了 mihomo 照跑,mihomo 崩了由系统按 KeepAlive.Crashed / Restart=on-failure 重拉。

环境变量:
  A2_HOME                  覆写 ~/.a2(自管 mihomo 落在 <A2_HOME>/mihomo/)
  A2_MIHOMO_CONTROLLER     直接指定要收编的 external-controller(host:port),跳过配置解析
  A2_MIHOMO_SECRET         配套上一条的 secret
  A2_MIHOMO_CONTROLLER_PORT 覆写 a2 自管实例的控制端口(默认 ${A2_MIHOMO_CONTROLLER_PORT},有意避开 mihomo 默认的 9090)
  A2_MIHOMO_RELEASE_BASE   覆写发布渠道根地址(镜像源)
  A2_MIHOMO_BIN_DIRS       覆写二进制搜索目录(冒号分隔)。仅测试与诊断用
  A2_MIHOMO_CONFIG_FILES   覆写配置搜索路径(冒号分隔)。仅测试与诊断用
  A2_MIHOMO_EXPECT_SHA256  覆写下载物的期望摘要。仅测试与诊断用
  A2_MIHOMO_ASSET_KEY      覆写本机资产键(如 linux-amd64,用于在别的平台上验这条路径)。仅测试与诊断用

内核只对回环地址上的 external-controller 发只读请求(GET /version、GET /configs),从不做端口扫描。

退出码:0 成功 / 1 用法错 / 5 事没办成(不可达、不达地板、不归 a2 管、下载校验失败)/ 6 本平台无已支持的 supervisor`;

/** 帮助 = 一条成功包封(机读面无例外)+ 人类面原文。 */
export function helpOutcome(usage: string): CommandOutcome {
  return {
    envelope: successResponse(crypto.randomUUID(), { usage }),
    human: usage,
    exitCode: ExitCode.success,
  };
}

/**
 * 用法错。`steps` 给的是**这一层**的下一步命令(顶层给 `a2 help`,能力面给能力面的两条),
 * 人类面则把错误 + 对应的用法段落一起打到 stderr。
 */
export function usageOutcome(
  message: string,
  options: { usage?: string; steps?: { description: string; command?: string }[] } = {},
): CommandOutcome {
  const usage = options.usage ?? USAGE;
  const envelope = failureResponse(crypto.randomUUID(), {
    code: ErrorCode.usage,
    message,
    guidance: {
      summary: "查看可用子命令与参数后重试。",
      steps: options.steps ?? [{ description: "打印帮助", command: "a2 help" }],
    },
  });
  return {
    envelope,
    human: `${renderWireError(envelope.error)}\n\n${usage}`,
    exitCode: ExitCode.usage,
  };
}

/** 能力面的用法错:指引直接指向能力面自己的帮助与"看看有哪些能力"。 */
export function capabilitiesUsageOutcome(message: string): CommandOutcome {
  return usageOutcome(message, {
    usage: CAPABILITIES_USAGE,
    steps: [
      { description: "打印能力面用法", command: "a2 capabilities --help" },
      { description: "列出本内核实际提供的能力", command: "a2 capabilities list --json" },
    ],
  });
}

/** 服务面的用法错:指引指向服务面自己的帮助与"先看看现在装没装"。 */
export function serviceUsageOutcome(message: string): CommandOutcome {
  return usageOutcome(message, {
    usage: SERVICE_USAGE,
    steps: [
      { description: "打印服务面用法", command: "a2 service --help" },
      { description: "查当前安装态与运行态", command: "a2 service status --json" },
    ],
  });
}

/** mihomo 面的用法错:指引指向本面帮助与"先看看本机现在是什么现状"。 */
export function mihomoUsageOutcome(message: string): CommandOutcome {
  return usageOutcome(message, {
    usage: MIHOMO_USAGE,
    steps: [
      { description: "打印 mihomo 面用法", command: "a2 mihomo --help" },
      { description: "查本机现状与将采用的阶梯档位", command: "a2 mihomo status --json" },
    ],
  });
}
