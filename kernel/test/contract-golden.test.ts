// 契约面:金标报文快照 + JSON Schema 漂移门禁。
//
// 样本是**手写**的(`contract/golden/`),不是从 schema 生成的 —— 期望值必须来自独立的事实源,
// 否则测试只是把代码重算一遍、永远不会跟代码吵架。09 票的 Swift 侧读同一批样本做手写 Codable 对照。

import { expect, test } from "bun:test";
import path from "node:path";
import {
  CONTRACT_SCHEMAS,
  renderSchemaFile,
  schemaFileName,
  type ContractName,
} from "../src/contract/emit.ts";

const GOLDEN_DIR = path.resolve(import.meta.dir, "../contract/golden");
const SCHEMA_DIR = path.resolve(import.meta.dir, "../contract/schema");

interface GoldenSample {
  file: string;
  schema: ContractName;
  kind: "valid" | "invalid";
  why: string;
}

const index: { protocol: number; samples: GoldenSample[] } = await Bun.file(
  path.join(GOLDEN_DIR, "index.json"),
).json();

test("金标样本清单非空,且每个样本的 schema 名都是已登记契约", () => {
  expect(index.samples.length).toBeGreaterThan(0);
  for (const sample of index.samples) {
    expect(Object.keys(CONTRACT_SCHEMAS)).toContain(sample.schema);
  }
});

for (const sample of index.samples.filter((s) => s.kind === "valid")) {
  test(`金标(合法):${sample.file} —— ${sample.why}`, async () => {
    const raw = await Bun.file(path.join(GOLDEN_DIR, sample.file)).json();

    const parsed = CONTRACT_SCHEMAS[sample.schema].parse(raw);

    // 往返不掉字段、不改形状:解析结果必须与磁盘上的样本逐字段相等。
    expect(parsed).toEqual(raw);
  });
}

for (const sample of index.samples.filter((s) => s.kind === "invalid")) {
  test(`金标(非法):${sample.file} —— ${sample.why}`, async () => {
    const raw = await Bun.file(path.join(GOLDEN_DIR, sample.file)).json();

    const result = CONTRACT_SCHEMAS[sample.schema].safeParse(raw);

    expect(result.success).toBe(false);
  });
}

test("JSON Schema 导出物与 TS 契约源同步(漂移即红,修法:bun run schema)", async () => {
  for (const name of Object.keys(CONTRACT_SCHEMAS) as ContractName[]) {
    const file = path.join(SCHEMA_DIR, schemaFileName(name));
    const committed = await Bun.file(file).text();
    expect(committed).toBe(renderSchemaFile(name));
  }
});
