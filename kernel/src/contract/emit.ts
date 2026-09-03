// 契约导出:zod schema(TS 源)→ JSON Schema 文件(机器可读契约)。
//
// ADR 0010:契约以 TS 为**单一事实源**,导出 JSON Schema 供 agent 写客户端/插件、供 Swift 侧手写 Codable 对照;
// **不引入代码生成链** —— 导出物是给人和 agent 读的契约文本,不是编译输入。
//
// 用法:`bun run schema`(写 contract/schema/*.schema.json)。
// 门禁:`bun test` 里的漂移测试会重跑一遍导出并逐字节对照,改了 schema 忘了导出即红。
//
// 一条口径:导出的是**内核会产出的**报文形状(io=output),所以带 `additionalProperties: false`;
// 而运行时解析是宽松的(未知字段被丢弃、不报错),好让老客户端读新报文不炸。两者不矛盾:
// 「我产出的绝不多字段」与「我接受你多带字段」都是真话。

import path from "node:path";
import { z } from "zod";
import {
  AboutResultSchema,
  ArbitrationStateSchema,
  ArbitrationStatusResultSchema,
  AuditEventSchema,
  CapabilityCallResultSchema,
  CapabilityDescribeResultSchema,
  CapabilityDescriptorSchema,
  CapabilityEventSchema,
  CapabilityListResultSchema,
  CapabilitySetEventSchema,
  PluginCallOutputSchema,
  PluginCallRequestSchema,
  PluginChangeResultSchema,
  PluginDescribeResultSchema,
  PluginListResultSchema,
  PluginRecordSchema,
  ConfirmationErrorSchema,
  ConfirmationRequestSchema,
  ConfirmationResolveParamsSchema,
  ConfirmationResolveResultSchema,
  GuidanceSchema,
  GuideResultSchema,
  HelpResultSchema,
  KernelEventSchema,
  KernelSnapshotSchema,
  PendingConfirmationSchema,
  PushEnvelopeSchema,
  RoleRegisterParamsSchema,
  RoleRegisterResultSchema,
  MihomoChangeResultSchema,
  MihomoStatusResultSchema,
  ProxyConfigResultSchema,
  ProxyGroupsResultSchema,
  ProxyLatencyResultSchema,
  ProxyModeResultSchema,
  ProxyNodeSelectResultSchema,
  ProxyStatusResultSchema,
  ProxySupervisionResultSchema,
  RequestEnvelopeSchema,
  ResponseEnvelopeSchema,
  ServiceChangeResultSchema,
  ServiceStatusResultSchema,
  StatusResultSchema,
  SubscriptionChangeResultSchema,
  SubscriptionListResultSchema,
  SystemProxyChangeResultSchema,
  SystemProxyStatusResultSchema,
  UrlRouterConfigViewSchema,
  UrlRouterDecideResultSchema,
  UrlRouterExecuteCommandSchema,
  UrlRouterExecutorReportParamsSchema,
  UrlRouterExecutorReportResultSchema,
  UrlRouterHandlerSchema,
  UrlRouterHandoffResultSchema,
  UrlRouterRouteResultSchema,
  UrlRouterStatusResultSchema,
  VersionResultSchema,
  WireErrorSchema,
} from "./wire.ts";

/** 契约名 → schema。金标样本的 `schema` 字段、导出文件名都以这张表为准。 */
export const CONTRACT_SCHEMAS = {
  RequestEnvelope: RequestEnvelopeSchema,
  ResponseEnvelope: ResponseEnvelopeSchema,
  WireError: WireErrorSchema,
  Guidance: GuidanceSchema,
  StatusResult: StatusResultSchema,
  VersionResult: VersionResultSchema,
  HelpResult: HelpResultSchema,
  // 08 票:`a2 guide` 的机读面(给 AI 助手的使用说明全文)。与 version/help 同类 —— 无 op、
  // 不经 daemon,但**照样是登记契约**(`--json` 时 stdout 只有一条 JSON 包封,无一例外)。
  GuideResult: GuideResultSchema,
  // 13 票:GPL 义务的必有落点。登记成契约有两个用处 —— agent 能机读地拿到「调用了哪些外部程序、
  // 各是什么许可、源码在哪」,而 `bundled: false` 这条承诺有了 schema 层的守卫。
  // (`ExternalProgram` / `NoticeFile` 是它的嵌套形状,随 `AboutResult` 一起导出,不另登记一条 ——
  //  与 `GuidanceStep` 同一口径:嵌套类型只在被别人用到时才有意义。)
  AboutResult: AboutResultSchema,
  CapabilityDescriptor: CapabilityDescriptorSchema,
  CapabilityListResult: CapabilityListResultSchema,
  // 11 票:插件面。前四条是**内核 ↔ 插件**那条接口(导出成 JSON Schema 之后,agent 不必读本仓库
  // 的代码就能现场写一个插件);后三条是 `a2 plugin …` 的机读面。
  PluginDescribeResult: PluginDescribeResultSchema,
  PluginCallRequest: PluginCallRequestSchema,
  PluginCallOutput: PluginCallOutputSchema,
  PluginRecord: PluginRecordSchema,
  PluginListResult: PluginListResultSchema,
  PluginChangeResult: PluginChangeResultSchema,
  CapabilitySetEvent: CapabilitySetEventSchema,
  CapabilityDescribeResult: CapabilityDescribeResultSchema,
  CapabilityCallResult: CapabilityCallResultSchema,
  ServiceStatusResult: ServiceStatusResultSchema,
  ServiceChangeResult: ServiceChangeResultSchema,
  MihomoStatusResult: MihomoStatusResultSchema,
  MihomoChangeResult: MihomoChangeResultSchema,
  ProxyStatusResult: ProxyStatusResultSchema,
  ProxyGroupsResult: ProxyGroupsResultSchema,
  ProxyModeResult: ProxyModeResultSchema,
  ProxyNodeSelectResult: ProxyNodeSelectResultSchema,
  ProxyLatencyResult: ProxyLatencyResultSchema,
  ProxyConfigResult: ProxyConfigResultSchema,
  SystemProxyStatusResult: SystemProxyStatusResultSchema,
  SystemProxyChangeResult: SystemProxyChangeResultSchema,
  SubscriptionListResult: SubscriptionListResultSchema,
  SubscriptionChangeResult: SubscriptionChangeResultSchema,
  ProxySupervisionResult: ProxySupervisionResultSchema,
  // url-router 施工 02 票:五条能力的三种 result。
  // `UrlRouterConfigView` 与 `UrlRouterHandler` 是嵌套形状,但**单独登记**(与 `Guidance` 同一口径,
  // 与 `GuidanceStep` 相反):前者是 `roxyAPIKey` 那条脱敏纪律在契约层的落点、后者是接管幂等判据的
  // 读数源,两者都会被壳与 agent 单独引用,值得各有一份可读的 schema。
  UrlRouterConfigView: UrlRouterConfigViewSchema,
  UrlRouterHandler: UrlRouterHandlerSchema,
  UrlRouterStatusResult: UrlRouterStatusResultSchema,
  UrlRouterDecideResult: UrlRouterDecideResultSchema,
  UrlRouterRouteResult: UrlRouterRouteResultSchema,
  UrlRouterHandoffResult: UrlRouterHandoffResultSchema,
  // url-router 施工 04 票:执行指令帧那一对(内核 ↔ 机械执行器)。
  // 与确认器那一对(ConfirmationRequest / ConfirmationResolveParams)同一条登记理由 ——
  // **壳两侧都要用**:一边解指令帧,一边拼回执,所以两个方向都得有可读的 schema。
  UrlRouterExecuteCommand: UrlRouterExecuteCommandSchema,
  UrlRouterExecutorReportParams: UrlRouterExecutorReportParamsSchema,
  UrlRouterExecutorReportResult: UrlRouterExecutorReportResultSchema,
  // 08 票:角色注册、订阅推送、三层仲裁。09 票的 Swift 壳既要**读**推送(PushEnvelope/KernelEvent/
  // KernelSnapshot),也要**写**请求(RoleRegisterParams/ConfirmationResolveParams),两侧都在这张表上。
  RoleRegisterParams: RoleRegisterParamsSchema,
  RoleRegisterResult: RoleRegisterResultSchema,
  ConfirmationResolveParams: ConfirmationResolveParamsSchema,
  ConfirmationResolveResult: ConfirmationResolveResultSchema,
  PendingConfirmation: PendingConfirmationSchema,
  ConfirmationRequest: ConfirmationRequestSchema,
  ArbitrationState: ArbitrationStateSchema,
  ArbitrationStatusResult: ArbitrationStatusResultSchema,
  AuditEvent: AuditEventSchema,
  CapabilityEvent: CapabilityEventSchema,
  KernelSnapshot: KernelSnapshotSchema,
  KernelEvent: KernelEventSchema,
  PushEnvelope: PushEnvelopeSchema,
  ConfirmationError: ConfirmationErrorSchema,
} as const;

export type ContractName = keyof typeof CONTRACT_SCHEMAS;

/** 导出目录(仓库内,入库)。 */
export const SCHEMA_DIR = path.resolve(import.meta.dir, "../../contract/schema");

/** `RequestEnvelope` → `request-envelope.schema.json`。 */
export function schemaFileName(name: ContractName): string {
  const kebab = name.replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase();
  return `${kebab}.schema.json`;
}

/** 单个契约的 JSON Schema 文件内容(含末尾换行,便于 diff)。 */
export function renderSchemaFile(name: ContractName): string {
  const jsonSchema = z.toJSONSchema(CONTRACT_SCHEMAS[name], { target: "draft-2020-12" });
  return `${JSON.stringify({ title: name, ...jsonSchema }, null, 2)}\n`;
}

export async function emitSchemas(): Promise<string[]> {
  const written: string[] = [];
  for (const name of Object.keys(CONTRACT_SCHEMAS) as ContractName[]) {
    const file = path.join(SCHEMA_DIR, schemaFileName(name));
    await Bun.write(file, renderSchemaFile(name));
    written.push(file);
  }
  return written;
}

if (import.meta.main) {
  const written = await emitSchemas();
  for (const file of written) console.log(`已导出 ${path.relative(process.cwd(), file)}`);
}
