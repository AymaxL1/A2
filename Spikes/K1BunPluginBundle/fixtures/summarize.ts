// 把 selftest 报告打成人读表格。故意用 `BUN_BE_BUN=1 <bin> summarize.ts` 跑——
// 顺带再证一次编译产物当通用 bun CLI 执行外部 .ts 文件这条路。
const report = JSON.parse(await Bun.file(process.argv[2]).text());
const clip = (s: string, n = 600) => (s.length > n ? s.slice(0, n) + " …" : s);

for (const c of report.checks) {
  console.log(`${c.pass ? "PASS" : "FAIL"}  ${c.name}${c.detail ? `  —— ${c.detail}` : ""}`);
}
console.log("\n—— 以下是留档记录(无对错、不判成败、不计入断言数)——");
for (const r of report.records ?? []) {
  console.log(`REC   ${r.name}\n      ${clip(r.detail).replace(/\n/g, "\n      ")}`);
}
console.log("");
for (const s of report.steps) {
  console.log(`step ${s.step.padEnd(28)} exit=${String(s.exitCode).padStart(3)}  ${s.ms}ms`);
}
console.log(
  `\n${report.summary.passed}/${report.summary.total} 硬断言通过` +
    `(另有 ${report.summary.recordCount ?? 0} 条留档记录，不计入)；` +
    `工件 ${report.artifact.bytes} 字节；报告全文：${report.workdir}/report.json`,
);
process.exit(report.summary.failed === 0 ? 0 : 1);
