// A2Contract —— 在 `A2JSON` 与镜像类型之间转换。
//
// 用途:响应包封的 `result` 是任意 JSON(`A2JSON`),而调用方要的是具体类型(如 `A2RoleRegisterResult`)。
// 两者之间只差一次编解码 —— 这里给它一个名字,免得每个调用方各写一遍。

import Foundation

extension A2JSON {
    /// 把这份 JSON 值按某个镜像类型解开。形状不符即抛(**不做兜底猜测**)。
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }

    /// 把一个可编码的值转成 JSON 值(拼 `params` 用)。
    public static func encoding<T: Encodable>(_ value: T) throws -> A2JSON {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(A2JSON.self, from: data)
    }
}
