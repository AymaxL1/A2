// 边界样本：native addon（.node）。fake.node 是占位文本文件——本样本只用来看
// bun build 编译期的行为（拒绝 / 静默外置 / 打进去），不验证真实 addon 的运行期加载。
const addon = require("./fake.node");
console.log(JSON.stringify({ ok: true, addon: typeof addon }));
