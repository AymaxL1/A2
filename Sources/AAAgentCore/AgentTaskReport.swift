// AAAgentCore —— HTML 报告(提案 §6 的落地)。
// 依赖边:本文件 → Foundation(只为 `replacingOccurrences`);绝不 import 任何 Host* / SDK / PluginProxy。
//
// 两条路径,主次分明:
//   * **主路径**:委托 prompt 模板里约定 agent 直接产出**自包含**的 `report.html`(内联样式、无外链)。
//     工作区里已经有这个文件时 —— **原样保留,绝不覆盖**。agent 写的报告比我们拼的强得多,
//     兜底模板把它盖掉是纯粹的信息损失。
//   * **兜底**:终态时发现没有 `report.html`,才把 `AgentTerminalStatus.finalText`(02 票已落地:
//     Claude 的 `result.result`;Codex 恒 nil 时由上层退回「最后一条 text 消息」)HTML-escape 后
//     套下面这个极简内置模板,并在页脚**显式标注**「由文本兜底生成」——读的人一眼能分辨这不是 agent 写的报告。
//
// **不做 md→HTML 渲染器**:那会给零依赖的 AAAgentCore 拖进一个解析器(或一个第三方包)。
//   兜底只是字符串拼接 + 一个 `<pre>`,原文什么样就什么样。
//
// escape 的**顺序是承重的**:必须先转 `&`。若先转 `<` 成 `&lt;`,再转 `&` 就会把刚生成的 `&lt;`
//   二次转义成 `&amp;lt;`,页面上显示的就是字面的 `&lt;` 而不是 `<`。这条有专门断言钉死。

import Foundation

/// HTML 报告的生成(纯字符串拼接,无副作用;落盘由 `AgentTaskWorkspace` 负责)。
public enum AgentTaskReport {
    /// 兜底页脚的固定标记串。上层(与测试)据它判断「这份报告是兜底生成的、不是 agent 写的」。
    public static let fallbackMarker = "由文本兜底生成"

    /// HTML 转义。覆盖 `&` `<` `>` `"` `'` 五个字符,**`&` 必须第一个转**(否则二次转义,见文件头)。
    public static func escapeHTML(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "&", with: "&amp;")   // ← 必须最先,顺序承重
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }

    /// 生成兜底报告页(自包含:内联样式、零外链、零脚本)。
    ///
    /// - `finalText` 为 nil / 全空白时不硬造内容,如实写「没有留下最终文本」并指向 `logs/raw.ndjson`
    ///   —— 排障真相源在那儿,报告没内容不等于什么都没发生。
    public static func fallbackHTML(
        taskID: String,
        state: AgentTaskState,
        finalText: String?,
        generatedAt: String
    ) -> String {
        let body: String
        if let text = finalText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = "<pre class=\"final-text\">\(escapeHTML(text))</pre>"
        } else {
            body = "<p class=\"empty\">本次任务没有留下最终文本。排障请看 logs/raw.ndjson。</p>"
        }
        return """
        <!DOCTYPE html>
        <html lang="zh-Hans">
        <head>
        <meta charset="utf-8">
        <title>\(escapeHTML(taskID))</title>
        <style>
        body { font: 15px/1.7 -apple-system, sans-serif; margin: 2rem auto; max-width: 46rem; color: #222; }
        h1 { font-size: 1.15rem; font-family: ui-monospace, monospace; word-break: break-all; }
        .state { color: #555; }
        .final-text { white-space: pre-wrap; word-break: break-word; background: #f6f6f6;
                      padding: 1rem; border-radius: 6px; }
        .empty { color: #777; }
        footer { margin-top: 2rem; padding-top: 0.8rem; border-top: 1px solid #ddd;
                 color: #777; font-size: 0.85rem; }
        </style>
        </head>
        <body>
        <h1>\(escapeHTML(taskID))</h1>
        <p class="state">状态:\(escapeHTML(state.rawValue))</p>
        \(body)
        <footer>本报告\(fallbackMarker)(agent 未产出 report.html);生成时刻 \(escapeHTML(generatedAt))。</footer>
        </body>
        </html>
        """
    }
}
