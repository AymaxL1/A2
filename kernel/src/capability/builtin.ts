// 内置能力集(04 票)。
//
// 这三条是**风险三档各一个的自检样本**,沿用旧 Swift 注册表的同名能力(`demo.echo` / `demo.note.set` /
// `demo.wipe`)与同样的行为,好让既有断言逐条对得上 —— 唯一一处有意的出入是 `demo.note.set` 多了一个
// `scope` 参数(旧 Swift 无此参数),为的是让 `allowedValues` 这段校验代码有活体断言可守,
// 出处见 `test/swift-parity-map.md`「有意的契约变更」第 9 条。它们全部是纯数据回显,**不碰文件、
// 不碰网络、不碰任何系统状态** —— `demo.wipe` 尤其:它叫 wipe 只是为了让"dangerous 被默拒"这条链
// 在门禁里端到端可验证,handler 本身什么都不擦。
//
// 真能力(service / mihomo / 代理)分别归 05、06、07 票,往这张表上加即可。

import {
  CapabilityFailedError,
  type Capability,
  type CapabilityInput,
} from "./registry.ts";

/** 业务失败的演示触发词:`demo.echo` 收到它就报 capability_failed(退出码 5 的活体样本)。 */
export const DEMO_ECHO_FAILURE_MESSAGE = "boom";

function requiredString(input: CapabilityInput, name: string): string {
  // 走到 handler 说明校验已过(必填 + 类型都对),这里只是取值,不重复校验。
  return input[name] as string;
}

const echo: Capability = {
  descriptor: {
    id: "demo.echo",
    risk: "safe",
    summary: "回显一条消息(只读,直通;用于验证调用闭环)",
    parameters: [
      {
        name: "message",
        type: "string",
        required: true,
        description: `要回显的文本;传 "${DEMO_ECHO_FAILURE_MESSAGE}" 会演示一次业务失败`,
      },
    ],
  },
  handler: (input) => {
    const message = requiredString(input, "message");
    if (message === DEMO_ECHO_FAILURE_MESSAGE) {
      throw new CapabilityFailedError(
        "demo.echo 按约定演示了一次业务失败。",
        `message = ${JSON.stringify(DEMO_ECHO_FAILURE_MESSAGE)}`,
      );
    }
    return { echo: message };
  },
};

const noteSet: Capability = {
  descriptor: {
    id: "demo.note.set",
    risk: "normal",
    summary: "记一条便签(可逆写,直通不打断;用于验证 normal 档零确认)",
    parameters: [
      { name: "key", type: "string", required: true, description: "便签的键" },
      { name: "value", type: "string", required: true, description: "便签的值" },
      {
        name: "scope",
        type: "string",
        required: false,
        description: "作用域(可选,默认 session);取值受限,用于验证 allowedValues 校验",
        allowedValues: ["session", "persistent"],
      },
    ],
  },
  // normal 档不落盘:本能力存在的意义是"可逆写档不该被任何确认打断",不是真的存东西。
  handler: (input) => {
    const scope = input["scope"];
    return {
      set: true,
      key: requiredString(input, "key"),
      value: requiredString(input, "value"),
      scope: typeof scope === "string" ? scope : "session",
    };
  },
};

const wipe: Capability = {
  descriptor: {
    id: "demo.wipe",
    risk: "dangerous",
    summary: "演示 dangerous 档仲裁(无确认器时默拒;handler 不做任何实际动作)",
    parameters: [
      {
        name: "target",
        type: "string",
        required: false,
        // 故意可选:不带任何参数也要能触发仲裁,免得"被拒"其实是"参数没填对"。
        description: "假想的目标名(可选;本能力不会对它做任何事)",
      },
    ],
  },
  handler: (input) => {
    const target = input["target"];
    return { wiped: true, target: typeof target === "string" ? target : "(未指定)" };
  },
};

/** 登记顺序即 `capabilities list` 的输出顺序。 */
export const BUILTIN_CAPABILITIES: Capability[] = [echo, noteSet, wipe];
