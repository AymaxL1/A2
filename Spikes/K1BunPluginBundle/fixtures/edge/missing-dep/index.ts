// 边界样本：package.json 里声明了依赖但没跑 install（node_modules 缺席）
import lp from "left-pad";
console.log(JSON.stringify({ ok: true, lp: typeof lp }));
