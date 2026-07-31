// AAAgentCore —— 归一化用到的 `AAContracts.JSONValue` 取值便利(模块内共用)。
// 依赖边:本文件 → AAContracts(纯值类型访问,连 Foundation 都用不上)。
//
// 为什么是 `internal` 而不是各 adapter 各留一份 fileprivate:
//   `member(_:)` 的语义**承重**——它把「键缺失」与「值是显式 JSON null」一视同仁,而这条恰是两家 adapter
//   各自正确性的前提(见下面的两个实证例子)。两家各留一份的话,将来有人只改一份(比如某个新字段需要
//   区分 null 与缺键),两个孪生 adapter 就会**静默分叉**——这正是最难发现的一类 bug。
//   一处共用声明比两段平行注释的防护强得多。
//
// 为什么不提到 `AAContracts`:那会扩张三方共用契约的公共面。这几个访问器只服务 AAAgentCore 的归一化,
//   `internal` 恰好够用 —— AAContracts 的公共面纹丝不动。

import AAContracts

extension JSONValue {
    /// 取对象成员:非对象 / 键缺失 / 值为 JSON null 一律 nil。
    ///
    /// **把「缺键」与「显式 null」一视同仁是刻意的**,两家 adapter 各有一个实证依据:
    /// - Claude 的 `result.api_error_status` 正常时是**显式 null**(不是缺键)。若只判缺键,
    ///   终态判定里的「`api_error_status` 非空 → failed」会把每一次正常完成都误判成失败。
    /// - Codex 的 `item.started` 里 `exit_code` 也是**显式 null**(命令还在跑)。若只判缺键,
    ///   下游就得再分辨一次「有键但是 null」,平白多一层心智负担。
    func member(_ key: String) -> JSONValue? {
        guard case let .object(object) = self, let value = object[key], value != .null else { return nil }
        return value
    }

    /// 若是布尔则返回其值,否则 nil(Claude 的 `is_error` 用)。
    var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    /// 若是数组则返回其元素,否则 nil(Claude 的 `content[]` / `permission_denials[]` 用)。
    var arrayValue: [JSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    /// 若是数字则返回其值,否则 nil(Codex 的 `exit_code` 用;JSONValue 统一以 Double 承载数字)。
    var numberValue: Double? {
        if case let .number(n) = self { return n }
        return nil
    }
}
