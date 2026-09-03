// 接管 / 还原的**编排**(url-router 施工 04 票,spec §5)——「谁来弹这个框、弹完了算什么」。
//
// ============================================================================
// 一条命令的全程,顺序即安全语义
// ============================================================================
//   ① 幂等判据(02 票已落,在调用方):当前 handler 已经是目标 → `already: true` 直通,
//      **一个系统调用都不发、一个框都不弹**。所以它排在最前面 —— 幂等的调用不该打扰任何人。
//   ② 执行器在场吗?在 → 直接下发。
//   ③ 不在 → `open -b com.a2.panel` 拉一把壳,再有界地等它注册。
//      **拉壳不违「永不隐式拉起」**:那条红线管的是查询(ADR 0008 第 6 条),而这是用户显式发起的
//      一次系统状态变更,拉壳是这次变更的其中一步(04 决策底账第 2 条)。
//      `open -b` 找不到那个 bundle id 就会非零退出 —— **那就是「壳没装」的判据本身**,
//      不必再发明第二套探测(02 研究票:别造新探测机制)。
//   ④ 下发执行指令帧,等 120s。回执 → 映射;没回执 → 超时。
//
// ============================================================================
// 错误面**一个新词都不造**(spec §5)
// ============================================================================
// 「确认换了个地方」不该让 agent 多学一套词:
//   * 没人能替你确认(壳没装 / 拉不起来 / 中途走了)→ `confirmation_unavailable`(退出码 2)
//   * 人点了取消                                   → `confirmation_denied`    (退出码 2)
//   * 120s 没人点                                  → `confirmation_timeout`   (退出码 3)
// 只有两种收场是这条链独有的,它们各自带着**别处没有的下一步**:
//   * 两个 scheme 只成了一个 → `url_router_partial_takeover`(5),报文里指名道姓说缺哪个;
//   * 一个都没成(目标 app 不在、系统 API 报错)→ `capability_failed`(5),带上原样 NSError。
//
// ============================================================================
// 目标缺失为什么由**壳**报(spec §5 的「前置报错」在本票的落点)
// ============================================================================
// spec 说还原目标不存在时要「在任何 LS 调用前结构化报错」。这件事的**唯一真值**是
// `urlForApplication(withBundleIdentifier:)`,而那个 API 只在壳那侧有。
// 于是本票的口径是:内核**不预判**目标存在性(预判只会得到第二份可能过时的答案),
// 壳在执行的第一步解析 bundle id,解析不到就 `outcome: "error"` 并说清"目标 app 不存在" ——
// **一个系统 API 都没调、一个框都没弹**,语义与「前置报错」等价,而真值只有一处。

import {
  ErrorCode,
  type Guidance,
  type UrlRouterExecuteCommand,
  type UrlRouterExecutorReportParams,
  type UrlRouterPerScheme,
  type UrlRouterScheme,
  type UrlRouterSchemeReport,
} from "../contract/wire.ts";
import { CapabilityFailedError } from "../capability/registry.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { PROCESS_TIMEOUT_MS, type UrlRouterPorts } from "./execute.ts";
import { A2_PANEL_BUNDLE_ID, HANDLER_SCHEMES } from "./handler.ts";

/** 编排要用到的执行器那一侧(daemon 注入真实现,单测注入假件)。 */
export interface UrlRouterExecutorPort {
  readonly timeoutMs: number;
  readonly launchWaitMs: number;
  present(): boolean;
  waitForPresence(timeoutMs: number): Promise<boolean>;
  dispatch(command: UrlRouterExecuteCommand): Promise<
    | { kind: "reported"; report: UrlRouterExecutorReportParams }
    | { kind: "timeout" }
    | { kind: "gone"; detail: string }
  >;
}

export interface HandoffInputs {
  paths: KernelPaths;
  ports: UrlRouterPorts;
  executor: UrlRouterExecutorPort;
  /** 要成为 http+https 默认 handler 的 bundle id。 */
  target: string;
  /** 这次是接管还是还原(只影响报文措辞与指引,不影响那条链)。 */
  action: "takeover" | "restore";
}

/** 执行成功时交回给调用方的两样(调用方负责再读一次 handler 现状拼进 result)。 */
export interface HandoffExecution {
  perScheme: UrlRouterPerScheme;
}

/**
 * 把一次接管/还原真的做掉。**成功返回执行结果,别的一切都抛 `CapabilityFailedError`**——
 * 与 registry 的铁律一致:能力面上没有"半成功的返回值"。
 */
export async function performHandoff(inputs: HandoffInputs): Promise<HandoffExecution> {
  const { executor } = inputs;

  // ② / ③ 执行器在场吗?不在就拉一把壳,再有界地等。
  if (!executor.present()) {
    await launchPanel(inputs);
    const arrived = await executor.waitForPresence(executor.launchWaitMs);
    if (!arrived) {
      throw executorUnavailable(inputs, {
        message: `已经拉起过 ${A2_PANEL_BUNDLE_ID},但它在 ${executor.launchWaitMs}ms 内没有连上内核。`,
        detail:
          "`open -b` 成功只说明 LaunchServices 认得这个 bundle id,不说明壳真的跑起来并注册成了执行器。" +
          "常见原因:壳被系统拦下了(头一次打开需要用户放行)、或它起来了但连不上这个 A2_HOME 的 socket。",
      });
    }
  }

  // ④ 下发 + 有界等待。
  const command: UrlRouterExecuteCommand = {
    id: crypto.randomUUID(),
    op: "set-default-handler",
    schemes: [...HANDLER_SCHEMES],
    bundleID: inputs.target,
    // 帧上的秒数与内核自己的窗口**同源**:壳据此知道内核会等多久,而它自己不设第二个钟。
    timeoutSeconds: Math.max(1, Math.round(executor.timeoutMs / 1000)),
  };
  const settlement = await executor.dispatch(command);

  if (settlement.kind === "gone") {
    throw executorUnavailable(inputs, {
      message: "执行指令已经下发,但机械执行器在等结果的过程中离场了 —— 这次接管没有结果可言。",
      detail:
        `${settlement.detail}系统弹框可能仍在屏幕上,` +
        "但没有人能把你点的结果送回内核了。请确认 A2 Panel 还在运行,然后重新发起。",
    });
  }
  if (settlement.kind === "timeout") throw executionTimeout(inputs, executor.timeoutMs);

  return mapReport(inputs, command, settlement.report);
}

// MARK: - ③ 拉起壳

/**
 * `open -b com.a2.panel`。**非零退出即「壳没装」**(02 研究票:不发明第二套探测)。
 *
 * 这里有意不传任何 URL、不带 `-g`:目的就是"把它拉到前台来",因为接下来用户要在系统弹框上点东西。
 */
async function launchPanel(inputs: HandoffInputs): Promise<void> {
  const result = await inputs.ports.run(
    [inputs.ports.bin.open, "-b", A2_PANEL_BUNDLE_ID],
    PROCESS_TIMEOUT_MS,
  );
  if (result.exitCode === 0) return;
  throw executorUnavailable(inputs, {
    message: `这台机器上找不到 ${A2_PANEL_BUNDLE_ID}(A2 Panel.app 没装,或还没被 LaunchServices 认到)。`,
    detail:
      `${inputs.ports.bin.open} -b 退出码 ${result.exitCode}` +
      `${result.stderr.trim() ? `:${result.stderr.trim().slice(0, 300)}` : ""}。` +
      "改系统默认浏览器**只有一条合法路径**:由 A2 Panel 调系统 API、让 OS 弹框、由你亲自点头。" +
      "壳不在,这条路就走不通 —— 内核不走任何替代路径(那等于替你按下那个框)。",
    installFirst: true,
  });
}

// MARK: - ④ 回执 → 报文

/** 壳回执里某个 scheme 的结果(缺席 = 那个 scheme 压根没轮到)。 */
function reportOf(
  perScheme: UrlRouterPerScheme,
  scheme: UrlRouterScheme,
): UrlRouterSchemeReport | undefined {
  return scheme === "http" ? perScheme.http : perScheme.https;
}

/**
 * 收场映射。**先看 `outcome` 里那两个只有壳知道的词,再看 `perScheme` 这份事实**:
 *   * `denied` / `timeout` —— 只有壳能分辨的两件事(用户点了取消 / 它自己那侧超时了),照直映射;
 *   * 其余 —— 一律**按 perScheme 数数**:全成 / 全没成 / 成了一半。
 *
 * 为什么不直接信 `outcome: "confirmed"`:那是一句概括,而 `perScheme` 是逐条的事实。
 * 两者万一不一致(壳写错了、协议将来加了 scheme),**以事实为准**才不会报出"成功了但其实没有"。
 */
function mapReport(
  inputs: HandoffInputs,
  command: UrlRouterExecuteCommand,
  report: UrlRouterExecutorReportParams,
): HandoffExecution {
  if (report.outcome === "denied") throw executionDenied(inputs, report);
  if (report.outcome === "timeout") throw executionTimeout(inputs, inputs.executor.timeoutMs);

  const succeeded: UrlRouterScheme[] = [];
  const failed: UrlRouterScheme[] = [];
  for (const scheme of command.schemes) {
    if (reportOf(report.perScheme, scheme)?.ok === true) succeeded.push(scheme);
    else failed.push(scheme);
  }

  if (failed.length === 0) return { perScheme: report.perScheme };
  if (succeeded.length > 0) throw partialTakeover(inputs, report, succeeded, failed);
  throw executionFailed(inputs, report, failed);
}

// MARK: - 五条错误报文(词表见文件头)

/** 「没人能替你确认」——壳没装 / 拉不起来 / 中途走了。三种局面对发起方是同一件事。 */
function executorUnavailable(
  inputs: HandoffInputs,
  options: { message: string; detail: string; installFirst?: boolean },
): CapabilityFailedError {
  const steps: Guidance["steps"] = [];
  if (options.installFirst) {
    steps.push({
      description: "先装上 A2 Panel.app(把它拖进 /Applications 并打开一次,让系统认到它)",
    });
  } else {
    steps.push({ description: "确认 A2 Panel 正在运行", command: 'open -b com.a2.panel' });
  }
  steps.push(
    {
      description:
        inputs.action === "takeover"
          ? "不想装壳也行:在「系统设置 → 桌面与程序坞 → 默认网页浏览器」里手选 A2 Panel"
          : `不想装壳也行:在「系统设置 → 桌面与程序坞 → 默认网页浏览器」里手选 ${inputs.target}`,
    },
    { description: "改完回来核对一下现状", command: "a2 url-router status --json" },
  );
  return new CapabilityFailedError(options.message, options.detail, {
    code: ErrorCode.confirmationUnavailable,
    guidance: {
      summary:
        "改系统默认浏览器要由 A2 Panel 调系统 API、让操作系统弹框确认 —— 此刻没有可用的执行器。",
      steps,
      context: capabilityContext(inputs),
    },
  });
}

/** 「人看了,他不同意」。与默拒是两件事:agent 拿到这条该停手转告,而不是想办法把壳弄起来。 */
function executionDenied(
  inputs: HandoffInputs,
  report: UrlRouterExecutorReportParams,
): CapabilityFailedError {
  return new CapabilityFailedError(
    `url-router.${inputs.action} 的系统确认被拒绝,系统默认浏览器一个字都没改。`,
    `${report.error ?? "用户在系统弹框上点了取消。"}` +
      "决定由操作系统的弹框承载,内核不复议、也不提供任何旁路(`--yes` 类旁路永禁)。",
    {
      code: ErrorCode.confirmationDenied,
      guidance: {
        summary: "这次接管/还原被用户拒绝了 —— 请把这条原样转告用户,由用户决定要不要再来一次。",
        steps: [
          { description: "确认这确实是用户想做的事(核对下面 context 里的目标 bundle id)" },
          { description: "如果确实要做,请由用户重新发起,并在系统弹框上亲自点「使用」" },
        ],
        context: { ...capabilityContext(inputs), ...perSchemeContext(report.perScheme) },
      },
    },
  );
}

/** 「框弹了,没人点」。超时不是拒绝也不是成功 —— 用户晚点才点也算数,所以指引是"去核实"。 */
function executionTimeout(inputs: HandoffInputs, timeoutMs: number): CapabilityFailedError {
  return new CapabilityFailedError(
    `url-router.${inputs.action} 等系统确认超时(${timeoutMs}ms),这次调用不作数。`,
    "执行指令已经下发、系统弹框应当已经出现,但在窗口内没有人做决定。" +
      "**这不代表它一定没成**:用户晚点才点也算数 —— 所以请去核实现状,而不是直接再发一次。",
    {
      code: ErrorCode.confirmationTimeout,
      guidance: {
        summary: "系统弹框还等着人点。稍后核实一下系统此刻的默认浏览器到底是谁。",
        steps: [
          { description: "看看屏幕上是不是还挂着「是否将…设为默认浏览器」的系统弹框(可能被别的窗口挡住了)" },
          { description: "稍后核实现状", command: "a2 url-router status --json" },
        ],
        context: { ...capabilityContext(inputs), timeoutMs: String(timeoutMs) },
      },
    },
  );
}

/** 「一个成了、一个没成」——http 与 https 是两次独立的系统弹框,这是 spec §5 明写的一种收场。 */
function partialTakeover(
  inputs: HandoffInputs,
  report: UrlRouterExecutorReportParams,
  succeeded: UrlRouterScheme[],
  failed: UrlRouterScheme[],
): CapabilityFailedError {
  return new CapabilityFailedError(
    `url-router.${inputs.action} 只成了一半:${succeeded.join("+")} 已经是 ${inputs.target},${failed.join("+")} 没有。`,
    "http 与 https 是两次独立的系统弹框(OS 行为),用户完全可能同意一个、取消另一个。" +
      `没成的那些带着原样错误:${failureLines(report.perScheme, failed)}` +
      "**半接管是会出事的状态**:点普通链接与点安全链接会走到两个不同的浏览器。",
    {
      code: ErrorCode.urlRouterPartialTakeover,
      guidance: {
        summary: `补齐剩下的 ${failed.join("+")} —— 再跑一次同一条命令即可(已经成的那个是幂等的,不会再弹框)。`,
        steps: [
          {
            description: "再来一次,只有没成的那个 scheme 会弹框",
            command:
              inputs.action === "takeover"
                ? "a2 url-router takeover --json"
                : `a2 url-router restore --to ${inputs.target} --json`,
          },
          { description: "核对两个 scheme 现在各自是谁", command: "a2 url-router status --json" },
        ],
        context: {
          ...capabilityContext(inputs),
          succeeded: succeeded.join("+"),
          failed: failed.join("+"),
          ...perSchemeContext(report.perScheme),
        },
      },
    },
  );
}

/** 「一个都没成」——目标 app 不在、系统 API 报错。路走通了、事没办成(退出码 5)。 */
function executionFailed(
  inputs: HandoffInputs,
  report: UrlRouterExecutorReportParams,
  failed: UrlRouterScheme[],
): CapabilityFailedError {
  return new CapabilityFailedError(
    `url-router.${inputs.action} 没能把 ${inputs.target} 设成默认 handler,系统状态一个字都没改。`,
    `${report.error === undefined ? "" : `${report.error} `}` +
      `没成的 scheme:${failureLines(report.perScheme, failed)}` +
      "最常见的一种是**目标 app 根本不在这台机器上** —— 那时壳连系统 API 都没调,更没有弹过框。",
    {
      // **有意不造新码**:这一档就是「能力执行了,但业务上失败了」的标准形状(退出码 5)。
      // 真正需要机读分支的是"成了一半"(那条有自己的码与补齐命令),而这一条的下一步永远是
      // 「把目标改对再来」——一句 guidance 说得清,不值得让 agent 再记一个词。
      code: ErrorCode.capabilityFailed,
      guidance: {
        summary:
          inputs.action === "takeover"
            ? "确认 A2 Panel.app 真的在这台机器上,然后重试。"
            : `确认还原目标 ${inputs.target} 真的在这台机器上;要换一个目标,用 --to 显式指定。`,
        steps:
          inputs.action === "takeover"
            ? [
                { description: "确认 A2 Panel 能被系统找到", command: "open -b com.a2.panel" },
                { description: "核对现状", command: "a2 url-router status --json" },
              ]
            : [
                {
                  description: "换一个装着的浏览器作为还原目标(Safari 在 macOS 上删不掉)",
                  command: "a2 url-router restore --to com.apple.Safari --json",
                },
                {
                  description: "或者改配置里的兜底浏览器,让缺省目标从此就是对的",
                  command: `编辑 ${inputs.paths.home}/url-router.json 的 fallbackBrowserBundleID`,
                },
              ],
        context: { ...capabilityContext(inputs), ...perSchemeContext(report.perScheme) },
      },
    },
  );
}

// MARK: - 报文里的公共事实

function capabilityContext(inputs: HandoffInputs): Record<string, string> {
  return {
    capability: `url-router.${inputs.action}`,
    risk: "dangerous",
    confirmation: "os-dialog",
    target: inputs.target,
    home: inputs.paths.home,
    socketPath: inputs.paths.socketPath,
  };
}

/** 逐 scheme 的结果进 context(机读面:agent 据此知道该补哪个)。 */
function perSchemeContext(perScheme: UrlRouterPerScheme): Record<string, string> {
  const out: Record<string, string> = {};
  for (const scheme of HANDLER_SCHEMES) {
    const report = reportOf(perScheme, scheme);
    if (report === undefined) continue;
    out[scheme] = report.ok
      ? "ok"
      : report.error === undefined
        ? "failed"
        : `${report.error.domain}(${report.error.code}):${report.error.description}`;
  }
  return out;
}

/** 人读的一行:没成的那些 scheme 各自带着原样 NSError。 */
function failureLines(perScheme: UrlRouterPerScheme, failed: UrlRouterScheme[]): string {
  const parts = failed.map((scheme) => {
    const report = reportOf(perScheme, scheme);
    if (report === undefined) return `${scheme}(压根没轮到)`;
    if (report.error === undefined) return `${scheme}(没成,执行器没给出错误)`;
    return `${scheme}(${report.error.domain} ${report.error.code}:${report.error.description})`;
  });
  return `${parts.join("、")}。`;
}
