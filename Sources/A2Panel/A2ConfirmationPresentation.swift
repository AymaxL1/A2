// A2Panel —— 确认器**呈现模型**(10 票)。纯数据,零 AppKit。
//
// ============================================================================
// 这一层为什么必须存在,而不是让 NSAlert 自己从 `A2ConfirmationRequest` 里取字段
// ============================================================================
// 「`input` 必须原样呈现」是 spec 的壳红线(防「agent 替用户点确认」的社工话术:
//   agent 说「我只是改个名字」,实际入参把订阅源换成了它自己的服务器)。
// 这条红线要**可断言**,就不能藏在 AppKit 的字符串拼接里 —— 那种代码只有人眼能审。
// 拆出本层之后,「弹出来的东西逐字等于协议报文里的 input」就是一条纯逻辑断言。
//
// ⚠️ **绝不截断、绝不省略、绝不重排语义**:
//   * 每个入参一行,`键: 值`,键按字典序(确定性,便于断言与人眼扫读);
//   * 值用 `A2MenuModel.describe` 渲染 —— 与菜单同一套 JSON → 文本规则,长值**不截断**。
//     宁可弹窗很长,也不能让被截掉的那一半正好是恶意的那一半。
//   * 空 input 如实写成「(无入参)」,不留空白让人以为「没什么可看的」。

import A2Contract

/// 一条待人拍板的确认请求的**可呈现形态**。
public struct A2ConfirmationPresentation: Sendable, Equatable {
    /// 协议里的确认 id —— 回决定时要原样带回去。
    public let confirmation: String
    /// 窗口标题。
    public let title: String
    /// 能力 id(机读坐标,人也要看得见:它是「这到底在调什么」的唯一权威名字)。
    public let capability: String
    /// 能力自述(来自 descriptor,**内核给的**,壳不自带副本)。
    public let summary: String
    /// 风险档(恒为 dangerous —— 只有这一档进仲裁)。
    public let risk: A2RiskLevel
    /// 入参逐行原样(见文件头红线)。
    public let inputLines: [String]
    /// 超时时刻(内核算好的绝对时刻,壳不再自己加余量)。
    public let expiresAt: String
    /// 批准按钮标题。
    public let approveTitle: String
    /// 拒绝按钮标题(**默认按钮**:沉默不是同意,手滑回车也不该放行)。
    public let denyTitle: String

    public init(request: A2ConfirmationRequest) {
        self.confirmation = request.id
        self.title = "A2 需要你确认一次 dangerous 操作"
        self.capability = request.capability
        self.summary = request.descriptor.summary
        self.risk = request.descriptor.risk
        self.expiresAt = request.expiresAt
        self.inputLines = request.input.isEmpty
            ? ["(无入参)"]
            : request.input.keys.sorted().map { "\($0): \(A2MenuModel.describe(request.input[$0]!))" }
        self.approveTitle = "批准"
        self.denyTitle = "拒绝"
    }

    /// 弹窗正文(确定性文本 —— 纯逻辑断言与快照都比它)。
    public var body: String {
        var lines: [String] = []
        lines.append("能力:\(capability)(\(risk.rawValue))")
        lines.append(summary)
        lines.append("")
        lines.append("本次入参(原样):")
        lines.append(contentsOf: inputLines)
        lines.append("")
        lines.append("超时前未决定即视为拒绝(\(expiresAt))")
        return lines.joined(separator: "\n")
    }
}
