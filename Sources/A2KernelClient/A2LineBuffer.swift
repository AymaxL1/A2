// A2KernelClient —— NDJSON 拆行缓冲(**字节级**)。
//
// 传输形态:一帧 = 一行 UTF-8 JSON,以 `\n` 收尾。听起来平淡,却有一个真会咬人的坑:
//
//   **必须先按字节切行、再解码成字符串** —— 反过来(先把每个 chunk 转成 String 再拼)会在
//   多字节字符正好被 chunk 边界劈开时把它切碎:一个中文字 3 个字节,前 2 个在这个 chunk、
//   第 3 个在下一个 chunk,各自 `String(decoding:as:)` 出来就是两个替换字符 `�`,拼起来的
//   JSON 再也解不动。而内核的报文里**全是中文**(指引文案、审计 detail、能力 summary),
//   十几 KB 的快照几乎必定跨多个 chunk —— 这不是理论风险,是必然发生。
//   TS 侧刚在 08 票修过同款洞(`socket.write` 半写 + 按字符切),Swift 侧不重犯。
//
// 所以本类型的输入输出**一律是字节**:`append` 收字节,`nextLine` 吐一整行的字节;
// 解码成字符串是**调用方拿到完整一行之后**的事。

import Foundation

/// 按 `\n` 切行的字节缓冲。**不认 `\r\n`**(线协议是 NDJSON,`\r` 属于内容,不是行尾)。
public struct A2LineBuffer: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    /// 尚未凑成完整一行的字节数(诊断用:连接断了却还剩半行,说明报文被截断了)。
    public var pendingByteCount: Int { pending.count }

    /// 收下一段字节。
    public mutating func append<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        pending.append(contentsOf: bytes)
    }

    /// 取出下一整行(不含行尾 `\n`);还没凑齐则返回 nil。
    ///
    /// **空行直接跳过**:内核不会发空行,但真发了也不该让调用方去解一个空字符串。
    public mutating func nextLine() -> [UInt8]? {
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            let line = Array(pending[pending.startIndex..<newlineIndex])
            pending.removeSubrange(pending.startIndex...newlineIndex)
            if !line.isEmpty { return line }
        }
        return nil
    }
}
