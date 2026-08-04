// 边界样本：非静态可分析的 require（打包器无法在编译期解析）
const name = process.env.A2_MOD ?? "node:os";
const mod = require(name);
console.log(JSON.stringify({ ok: true, mod: name, keys: Object.keys(mod).length }));
