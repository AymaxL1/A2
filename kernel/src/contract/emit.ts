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
  CapabilityCallResultSchema,
  CapabilityDescribeResultSchema,
  CapabilityDescriptorSchema,
  CapabilityListResultSchema,
  GuidanceSchema,
  HelpResultSchema,
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
  CapabilityDescriptor: CapabilityDescriptorSchema,
  CapabilityListResult: CapabilityListResultSchema,
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
