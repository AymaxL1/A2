// aa —— 面向 Agent/人 的双层命令面 CLI 可执行(V1 骨架占位)。
// 依赖边:aa → AAContracts。
//
// 两个已固化的 Swift 语言坑(见 spike 先例,必须照抄):
//   1) 入口用 `@main @MainActor struct`——顶层代码非 MainActor 会挂;故文件名不叫 main.swift,编译加 -parse-as-library。
//   2) 任何 print 之后要 fflush(stdout)——stdout 被重定向时是块缓冲,不 flush 断言脚本可能读不到输出。

import Foundation
import AAContracts

@main
@MainActor
struct AAMain {
    static func main() {
        // 骨架期占位命令面:仅演示契约连通。取第一个参数作为待解析的风险档,缺省 "dangerous"。
        // 契约真值化后,这里会换成正式的 `aa capabilities call …` 解析→UDS→注册表路由链路。
        let raw = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dangerous"
        let parsed = RiskLevel.parse(raw)?.rawValue ?? "unknown"

        // 一行 JSON 占位输出。
        print("{\"tool\":\"aa\",\"status\":\"skeleton\",\"riskInput\":\"\(raw)\",\"riskParsed\":\"\(parsed)\"}")
        fflush(stdout)
    }
}
