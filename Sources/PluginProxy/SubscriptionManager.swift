// PluginProxy —— 订阅管理域逻辑(10 票):域模型 + 状态机(存储/激活/更新失败回滚/新增或替换源)。
// 依赖边:PluginProxy → AAPluginSDK(SubscriptionStore/SubscriptionSourcePort)、AAContracts(JSONValue/WireError)。
//   绝不 import 任何 Host*。真 I/O(文件/网络)压在注入的两个 Port 之后;注入假件即可纯逻辑单测。
//
// 设计要点(主会话锁定):
//   * **schema 归域层**:Subscription / SubscriptionCatalog 的 Codable 在这里;Port 只搬不透明字节。
//   * **磁盘为单一真源**:每次操作都在锁内 load-catalog→改→save-catalog,不做内存缓存,杜绝缓存一致性 bug。
//   * **风险分档**:list=safe;activate/update=normal(零确认);add=dangerous(确认由 Registry 路由层强制,本层不管)。
//   * **失败即无半态**:activate/update 内核重载失败 → 业务失败且不留半态(update 还额外把内核带回已知 good)。
//   * **id 抗碰撞**(F1):id = slug + 确定性哈希后缀,大小写不敏感同名→同 id(upsert 替换),异名→异 id(消除碰撞),永不空。
//   * **损坏清单=用户数据,拒绝读写**(F5):清单解码失败绝不当空清单覆盖(那会永久抹掉旧订阅),四操作一律业务失败。
//
// **`final class` + 内部 NSLock**(F9):订阅是「单一状态机 + 内部锁」,与两个 File*Store 同形;`@unchecked Sendable`(锁保护),
//   可被 `@Sendable` 的 capability handler 安全捕获并跨连接线程调用。

import Foundation
import AAContracts
import AAPluginSDK

/// 单条订阅(域模型;域层拥有 schema)。
public struct Subscription: Codable, Sendable, Equatable {
    /// 稳定 id = `makeID(name)`(slug + 确定性哈希后缀);大小写不敏感同名 → 同 id(支持「按 name upsert 替换源」)。
    public let id: String
    /// 展示名(用户可读;已 trim)。
    public let name: String
    /// 订阅源:`file://` 路径 / 裸绝对路径 / `http(s)://` URL。
    public let source: String
    /// 最近一次更新(拉取物化)的时间戳(`Date().timeIntervalSince1970`);从未更新过 → nil。
    public var lastUpdatedAt: TimeInterval?

    public init(id: String, name: String, source: String, lastUpdatedAt: TimeInterval? = nil) {
        self.id = id
        self.name = name
        self.source = source
        self.lastUpdatedAt = lastUpdatedAt
    }
}

/// 订阅清单(域模型):全部订阅 + 当前激活 id(至多一个)。
public struct SubscriptionCatalog: Codable, Sendable, Equatable {
    public var subscriptions: [Subscription]
    public var activeId: String?

    public init(subscriptions: [Subscription] = [], activeId: String? = nil) {
        self.subscriptions = subscriptions
        self.activeId = activeId
    }
}

/// 订阅状态机。持有 store/source/restClient + 一把 NSLock 串行化订阅操作。
///
/// 四个操作均返回 `Result<JSONValue, WireError>`,每次都在锁内 load-catalog→改→save-catalog(磁盘单一真源)。
/// `restClient` 复用 06 的 REST 客户端:activate/update 经 `reloadConfig(path:)` 让内核从物化配置路径重载。
public final class SubscriptionManager: @unchecked Sendable {
    private let store: any SubscriptionStore
    private let source: any SubscriptionSourcePort
    private let restClient: MihomoRESTClient
    /// 串行化订阅操作(同一时刻只一个 load→改→save 事务),杜绝并发交错。
    // 记债(D2):活操作在锁内做 source.fetch(慢源最长约拉取超时秒数),会阻塞并发的 safe list。移锁外需对 catalog 做
    //   read→fetch→re-check-under-lock 的乐观并发处理(fetch 期间清单可能被改),复杂度更高,V1 暂留锁内,记此债后续再拆。
    private let lock = NSLock()

    public init(store: any SubscriptionStore, source: any SubscriptionSourcePort, restClient: MihomoRESTClient) {
        self.store = store
        self.source = source
        self.restClient = restClient
    }

    // ============ id 生成(确定性 + 抗碰撞,F1)============

    /// FNV-1a 32-bit over UTF-8 字节(纯 Swift,**确定性**——不可用 `Hasher`(每进程随机)、不引 CryptoKit)。
    static func fnv1a32(_ s: String) -> UInt32 {
        var hash: UInt32 = 0x811c_9dc5
        for byte in s.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    /// name → 稳定 id;name 去空后为空 → **nil**(add 收敛为 invalidParams「订阅名不能为空」→ 退出码 6)。
    /// - slug:lowered 后 ASCII 字母数字保留、其余折 '-' 且**折叠连续 '-'**、去首尾 '-'。
    /// - 后缀:确定性 FNV-1a 哈希(8 位十六进制,over lowered)。`id = slug.isEmpty ? hash : "slug-hash"`。
    /// - 效果:同名(大小写不敏感)→ 同 id(upsert 替换语义);异名 → 异 id(纯非 ASCII 名如「机场甲/机场乙」不再塌成同 id);id 永不空。
    public static func makeID(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        var slug: [Character] = []
        var lastDash = false
        for ch in lowered {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                slug.append(ch); lastDash = false
            } else if !lastDash {
                slug.append("-"); lastDash = true
            }
        }
        while slug.first == "-" { slug.removeFirst() }
        while slug.last == "-" { slug.removeLast() }
        let slugStr = String(slug)
        let hash = String(format: "%08x", fnv1a32(lowered))
        return slugStr.isEmpty ? hash : "\(slugStr)-\(hash)"
    }

    // ============ 清单读写(锁内调用) ============

    /// 清单读取结果:区分「不存在(正常空清单)」与「有字节但解码失败(损坏,拒绝读写)」。
    private enum CatalogLoad {
        case ok(SubscriptionCatalog)
        case corrupt
    }

    /// 读清单:不存在 → 空清单(正常);**有字节但解码失败 → corrupt(F5:绝不当空清单,那会覆盖丢用户数据)**。
    private func loadCatalog() -> CatalogLoad {
        guard let data = store.loadCatalog() else { return .ok(SubscriptionCatalog()) }
        guard let cat = try? JSONDecoder().decode(SubscriptionCatalog.self, from: data) else {
            return .corrupt
        }
        return .ok(cat)
    }

    /// 编码并原子写清单;写失败抛错(由调用方收敛为业务失败)。
    private func saveCatalog(_ cat: SubscriptionCatalog) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try store.saveCatalog(encoder.encode(cat))
    }

    private static func failed(_ detail: String) -> Result<JSONValue, WireError> {
        .failure(WireError(code: WireErrorCode.capabilityFailed, detail: detail))
    }

    private static func invalid(_ detail: String) -> Result<JSONValue, WireError> {
        .failure(WireError(code: WireErrorCode.invalidParams, detail: detail))
    }

    /// F5:损坏清单统一失败(绝不读写覆盖)。
    private static func corruptFailure() -> Result<JSONValue, WireError> {
        failed("订阅清单文件损坏,已拒绝读写以免覆盖既有数据(请人工检查/移除后重试)")
    }

    private func log(_ msg: String) {
        FileHandle.standardError.write(Data("[PluginProxy][subscription] \(msg)\n".utf8))
    }

    // ============ list(safe) ============

    /// 列出全部订阅 + 当前激活。不碰内核。输出 `{ active: id?|null, subscriptions: [{id,name,source,lastUpdatedAt?}] }`。
    /// 损坏清单 → 业务失败(不臆造空清单,避免下游误以为「无订阅」)。
    public func list() -> Result<JSONValue, WireError> {
        lock.lock(); defer { lock.unlock() }
        let cat: SubscriptionCatalog
        switch loadCatalog() {
        case .corrupt: return Self.corruptFailure()
        case .ok(let c): cat = c
        }
        let subs: [JSONValue] = cat.subscriptions.map { sub in
            .object([
                "id": .string(sub.id),
                "name": .string(sub.name),
                "source": .string(sub.source),
                "lastUpdatedAt": sub.lastUpdatedAt.map { JSONValue.number($0) } ?? .null
            ])
        }
        return .success(.object([
            "active": cat.activeId.map { JSONValue.string($0) } ?? .null,
            "subscriptions": .array(subs)
        ]))
    }

    // ============ activate(normal) ============

    /// 激活指定订阅:让内核从该订阅物化配置重载。不存在 → 业务失败;已是 active → 幂等成功;
    /// 重载失败 → 业务失败且 activeId 不变(内核仍在旧配置,无半态)。
    public func activate(id: String) -> Result<JSONValue, WireError> {
        lock.lock(); defer { lock.unlock() }
        var cat: SubscriptionCatalog
        switch loadCatalog() {
        case .corrupt: return Self.corruptFailure()
        case .ok(let c): cat = c
        }
        guard cat.subscriptions.contains(where: { $0.id == id }) else {
            return Self.failed("订阅不存在: \(id)(先 add 或查 list)")
        }
        // 已是激活 → 幂等成功(不重复重载)。
        // 记债(D1):若刚 add 替换的正是当前激活订阅,这里的幂等短路会让「替换后的新字节」无法经 activate 生效——需改用 update 才重载生效。
        if cat.activeId == id {
            return .success(.object(["id": .string(id), "activated": .bool(true)]))
        }
        do {
            try restClient.reloadConfig(path: store.configPath(id: id))
        } catch {
            return Self.failed("激活失败:内核重载配置出错(内核未运行/控制面未就绪): \(error)")
        }
        cat.activeId = id
        do {
            try saveCatalog(cat)
        } catch {
            // 内核其实已切过去,只是清单没落盘;重试即自愈(下次 activate / 重启恢复会再对齐)。
            return Self.failed("激活后写清单失败(内核其实已切过去,重试即自愈): \(error)")
        }
        return .success(.object(["id": .string(id), "activated": .bool(true)]))
    }

    /// 重启后机械补齐(F3):若清单有 activeId 且该订阅仍在,**best-effort** 让内核从其物化配置重载(带有界就绪轮询)。
    /// 失败只记日志、返回 false,**绝不阻断启动**;损坏清单 → 记日志返回 false(不覆盖)。宿主在内核确认拉起之后调用。
    @discardableResult
    public func reloadActiveIfAny() -> Bool {
        // 只在锁内读清单;轮询重载放锁外(避免持锁 sleep 阻塞并发;启动期本无并发,亦更稳妥)。
        lock.lock()
        let load = loadCatalog()
        lock.unlock()
        let cat: SubscriptionCatalog
        switch load {
        case .corrupt:
            log("重启恢复:订阅清单损坏,跳过激活恢复(不覆盖)")
            return false
        case .ok(let c): cat = c
        }
        guard let active = cat.activeId, cat.subscriptions.contains(where: { $0.id == active }) else { return false }
        let path = store.configPath(id: active)
        // 有界就绪轮询(仿 pollForMixedPort):内核控制面刚起时 reload 可能尚不可达。
        for _ in 0..<25 {
            if (try? restClient.reloadConfig(path: path)) != nil {
                log("重启恢复:已让内核重载激活订阅 \(active) 的配置")
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        log("重启恢复:激活订阅 \(active) 的配置重载在时限内未成功(内核/控制面未就绪),跳过(不阻断启动)")
        return false
    }

    // ============ update(normal,零确认 + 失败回滚) ============

    /// 更新已有订阅源:重新拉取 → 物化新配置 →(若为激活中)重载生效;重载失败则回滚到旧配置并把内核带回已知 good。
    /// 拉取失败 / 空内容 → 业务失败且**什么都没改**。
    public func update(id: String) -> Result<JSONValue, WireError> {
        lock.lock(); defer { lock.unlock() }
        var cat: SubscriptionCatalog
        switch loadCatalog() {
        case .corrupt: return Self.corruptFailure()
        case .ok(let c): cat = c
        }
        guard let idx = cat.subscriptions.firstIndex(where: { $0.id == id }) else {
            return Self.failed("订阅不存在: \(id)(先 add 或查 list)")
        }
        let sub = cat.subscriptions[idx]

        // 回滚基线:旧配置字节(重载失败时把内核带回已知 good)。
        let oldData = store.loadConfig(id: id)

        // 拉取新配置——抛错 → 业务失败(什么都没改)。
        let newData: Data
        do {
            newData = try source.fetch(source: sub.source)
        } catch {
            return Self.failed("更新失败:拉取订阅源出错(\(sub.source)): \(error)")
        }
        guard !newData.isEmpty else {
            return Self.failed("更新失败:订阅源返回空内容(\(sub.source)),什么都没改")
        }

        // 物化新配置。
        do {
            try store.saveConfig(id: id, newData)
        } catch {
            return Self.failed("更新失败:写新配置出错: \(error)")
        }

        // 仅当该订阅正激活时才需重载生效;重载失败 → 回滚配置 + 把内核带回旧 good(F6:分三种结果如实措辞,不双吞错)。
        if cat.activeId == id {
            do {
                try restClient.reloadConfig(path: store.configPath(id: id))
            } catch {
                return rollbackAfterReloadFailure(id: id, oldData: oldData, reloadError: error)
            }
        }

        let now = Date().timeIntervalSince1970
        cat.subscriptions[idx].lastUpdatedAt = now
        do {
            try saveCatalog(cat)
        } catch {
            return Self.failed("更新后写清单失败: \(error)")
        }
        return .success(.object([
            "id": .string(id),
            "updated": .bool(true),
            "lastUpdatedAt": .number(now)
        ]))
    }

    /// update 激活项重载新配置失败后的回滚(F6):按实际结果措辞,绝不谎报「已回滚」。
    /// - 无旧配置可回滚 → 如实说明(物化停在新内容)。
    /// - 有旧配置:先写回旧字节;**写回失败就不再发第二次 reload**(免得把内核指到半新半旧),如实说明。
    /// - 写回成功再重载旧;重载旧成功/失败分别措辞。
    private func rollbackAfterReloadFailure(id: String, oldData: Data?, reloadError: Error) -> Result<JSONValue, WireError> {
        guard let oldData = oldData else {
            return Self.failed("更新失败:内核重载新配置出错,且无旧配置可回滚(物化配置停在新内容,内核可能仍在旧运行态): \(reloadError)")
        }
        do {
            try store.saveConfig(id: id, oldData)
        } catch {
            // 写回旧字节失败:不再发第二次 reload,如实说明(物化配置可能停在新内容)。
            return Self.failed("更新失败:内核重载新配置出错,且回滚写旧配置也失败(物化配置可能停在新内容): 重载错=\(reloadError) 回滚错=\(error)")
        }
        // 旧字节已写回,尝试把内核带回旧 good。
        if (try? restClient.reloadConfig(path: store.configPath(id: id))) != nil {
            return Self.failed("更新失败:内核重载新配置出错,已回滚到旧配置并重载生效: \(reloadError)")
        }
        return Self.failed("更新失败:内核重载新配置出错,配置已回退为旧但旧配置重载亦失败(内核可能仍在旧运行态,重试即自愈): \(reloadError)")
    }

    // ============ add(dangerous —— 确认由 Registry 路由层强制,本层不管) ============

    /// 新增或替换订阅源:拉取 → 物化 → upsert 进清单(同 id 覆盖 = 「替换源」)。**不自动激活、不重载**
    /// (激活/生效经 activate/update,dangerous 操作副作用最小化、可预测)。
    /// - 名字去空后为空 → invalidParams(退出码 6)。拉取失败 / 空内容 → 业务失败且不留痕。
    /// - 记债(D1):若替换的正是**当前激活**订阅,新字节不会自动生效(activate 幂等短路);需再 update 才生效。
    public func add(name rawName: String, source rawSource: String) -> Result<JSONValue, WireError> {
        // 名字先归一为 id;空名 → invalidParams(先于任何 I/O,拒绝不留痕)。
        guard let id = Self.makeID(rawName) else {
            return Self.invalid("订阅名不能为空(去除首尾空白后为空)")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)   // nit:存入 catalog 的 name 也 trim

        lock.lock(); defer { lock.unlock() }

        // 先探清单损坏(损坏时绝不写,免得覆盖)。
        if case .corrupt = loadCatalog() { return Self.corruptFailure() }

        // 拉取——抛错/空 → 业务失败(拒绝/失败不留痕:此前未写任何东西)。
        let data: Data
        do {
            data = try source.fetch(source: rawSource)
        } catch {
            return Self.failed("新增/替换订阅失败:拉取订阅源出错(\(rawSource)): \(error)")
        }
        guard !data.isEmpty else {
            return Self.failed("新增/替换订阅失败:订阅源返回空内容(\(rawSource)),未留痕")
        }

        // 物化配置。
        do {
            try store.saveConfig(id: id, data)
        } catch {
            return Self.failed("新增/替换订阅失败:写配置出错: \(error)")
        }

        // upsert 进清单(同 id 覆盖 = 替换源;保留既有 activeId 不动)。
        var cat: SubscriptionCatalog
        switch loadCatalog() {
        case .corrupt: return Self.corruptFailure()   // 极端并发/外部改动兜底
        case .ok(let c): cat = c
        }
        let isNew = !cat.subscriptions.contains(where: { $0.id == id })
        let now = Date().timeIntervalSince1970
        let entry = Subscription(id: id, name: name, source: rawSource, lastUpdatedAt: now)
        if let idx = cat.subscriptions.firstIndex(where: { $0.id == id }) {
            cat.subscriptions[idx] = entry
        } else {
            cat.subscriptions.append(entry)
        }
        do {
            try saveCatalog(cat)
        } catch {
            // F4:新 id 写清单失败 → 回收刚物化的孤儿配置(避免孤儿,并让 removeConfig 协议面有真实调用点)。
            //   替换既有 id 的失败无法完美清理(旧字节已被新字节覆盖)——此处不误删既有配置,注释点明。
            if isNew { store.removeConfig(id: id) }
            return Self.failed("新增/替换订阅后写清单失败\(isNew ? "(已回收本次物化的孤儿配置)" : "(替换既有 id:旧配置字节已被覆盖,无法完美回滚)"): \(error)")
        }
        return .success(.object([
            "id": .string(id),
            "name": .string(name),
            "added": .bool(true)
        ]))
    }
}
