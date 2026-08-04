// 内核客户端:CLI 侧「问 daemon 一件事」的唯一入口。
//
// 深模块的意义:调用方只拿到**一种东西** —— 一个响应包封。连不上、超时、对面胡说,
// 全被翻译成带指引的失败包封(而不是抛异常让每条子命令各写各的 catch)。
// 「永不隐式拉起 daemon」这条红线也就只需要在这一处守住:本模块只 connect,从不 spawn。

import {
  ErrorCode,
  Op,
  failureResponse,
  request,
  type JsonValue,
  type ResponseEnvelope,
} from "../contract/wire.ts";
import type { KernelPaths } from "../runtime/paths.ts";
import { DaemonUnreachableError, ProtocolViolationError, requestOnce } from "./uds-client.ts";

/** daemon 不可达时的「人类如何完成」—— 精确命令 + 展开后的路径事实。 */
function daemonUnreachableEnvelope(id: string, paths: KernelPaths, detail: string): ResponseEnvelope {
  return failureResponse(id, {
    code: ErrorCode.daemonUnreachable,
    message: "a2 daemon 未在运行,或 socket 不可连接。",
    detail,
    guidance: {
      summary: "CLI 永不隐式拉起 daemon,请由人类显式安装或启动内核后重试。",
      steps: [
        {
          description: "推荐:装成系统托管的常驻服务(开机自启与崩溃自愈都归系统 supervisor)",
          command: "a2 service install",
        },
        {
          description: "或:在一个终端里前台起常驻进程(调试用,Ctrl-C 结束)",
          command: "a2 daemon run",
        },
      ],
      context: {
        socketPath: paths.socketPath,
        home: paths.home,
      },
    },
  });
}

/**
 * 向 daemon 发一次请求,**恒返回**一个响应包封:
 *   * daemon 应答 → 原样透传(成功或它自己的失败);
 *   * 连不上/超时 → `daemon_unreachable` + 指引;
 *   * 对面不守协议 → `bad_request` 级别的失败包封(细节进 detail)。
 */
export async function callKernel(
  paths: KernelPaths,
  op: Op,
  params?: Record<string, JsonValue>,
): Promise<ResponseEnvelope> {
  const message = request(op, params);
  try {
    return await requestOnce(paths.socketPath, message);
  } catch (error) {
    if (error instanceof DaemonUnreachableError) {
      return daemonUnreachableEnvelope(message.id, paths, error.detail);
    }
    if (error instanceof ProtocolViolationError) {
      return failureResponse(message.id, {
        code: ErrorCode.badRequest,
        message: "daemon 的响应不符合线协议。",
        detail: error.detail,
      });
    }
    return failureResponse(message.id, {
      code: ErrorCode.internalError,
      message: "调用 daemon 时发生未预期的错误。",
      detail: String(error),
    });
  }
}
