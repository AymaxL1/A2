// AAAgentCore —— task-id 的生成(纯函数)。提案 §1:`<YYYYMMDD-HHmm>-<slug>-<hex4>`,**目录名即 task-id**。
// 依赖边:本文件零 import(纯 stdlib 字符处理)。
//
// **刻意不引入随机数端口**:`hex4` 随机尾由**调用方**(07 票 CLI)生成后传进来,本类型只做纯函数拼装。
//   多一个端口就多一份真实现负担与一处「测试要编程随机」的心智负担;而随机尾的唯一职责是「防同分钟撞名」,
//   它是不是由域逻辑产生并不重要。于是这里连一次随机都不发生 —— 整个 task-id 生成是可逐字断言的纯函数。

/// task-id 生成(纯函数)。
public enum AgentTaskID {
    /// slug 长度上限(提案 §1:≤24 字符)。
    public static let maxSlugLength = 24
    /// slug 折不出任何字符时的回退值(提案 §1:空则 `task`)。
    public static let fallbackSlug = "task"

    /// 拼出 task-id:`<stamp>-<slug>-<suffix>`。
    ///
    /// - `stamp`:`AgentWallClock.stamp`(`YYYYMMDD-HHmm`),让 `ls` 天然按时间排序;
    /// - `prompt`:委托原文,取首句折成 slug(见 `slug(from:)`);
    /// - `suffix`:调用方给的随机尾(约定 hex4),本函数不校验其形状 —— 校验它等于把随机策略搬进域逻辑。
    public static func make(stamp: String, prompt: String, suffix: String) -> String {
        "\(stamp)-\(slug(from: prompt))-\(suffix)"
    }

    /// 由 prompt 折出 slug(提案 §1 的四条规则,逐条落地):
    /// 1. 取**首句**(遇 `.` `!` `?` `。` `!` `?` 或换行即止);
    /// 2. 小写;
    /// 3. 非 ASCII 字母数字一律折成**单个**连字符(连续的非法字符不产生连续连字符);
    /// 4. 去首尾连字符、截到 ≤24 字符;折完为空则回退 `task`。
    ///
    /// **中文 prompt 必然走回退**:第 3 条要求的是 ASCII 字母数字(目录名要在任何终端 / 任何 shell 下都好敲),
    ///   汉字全部被折掉 → 折完为空 → `task`。这不是缺陷:同分钟的多个中文委托靠 `hex4` 尾区分,
    ///   人要认哪个是哪个看 `prompt.md` 或 `aa agent list`,不靠目录名硬猜。
    public static func slug(from prompt: String) -> String {
        let terminators: Set<Character> = [".", "!", "?", "。", "！", "？", "\n", "\r"]
        let firstSentence = String(prompt.prefix { !terminators.contains($0) })

        var out = ""
        var pendingSeparator = false
        for ch in firstSentence.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                // 只有已经吐过字符、且中间隔过非法字符时才补连字符 —— 天然不产生首部连字符,也不产生连续连字符。
                if pendingSeparator && !out.isEmpty { out.append("-") }
                pendingSeparator = false
                out.append(ch)
            } else {
                pendingSeparator = true
            }
        }

        if out.count > maxSlugLength { out = String(out.prefix(maxSlugLength)) }
        // 截断可能正好断在连字符上(如 "a-bcdefghij…-x" 截到第 24 位恰是 '-'),再去一次尾。
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? fallbackSlug : out
    }
}
