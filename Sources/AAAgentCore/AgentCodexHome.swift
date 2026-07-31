// AAAgentCore —— 每任务独立 `$CODEX_HOME` 的准备与清理(经 `AgentFileSystemPort`,故可在 FakeFileSystem 上纯逻辑测)。
// 依赖边:本文件零 import(只用同模块的端口协议 + stdlib)。模块级红线同 AgentPort.swift。
//
// ============ 这个文件存在的唯一理由:别把用户的真配置带进被委托任务 ============
// 用户真实的 `~/.codex/config.toml` 里写着 `sandbox_mode = "danger-full-access"`(本机现状)。
//   要是「隔离」时顺手把整个目录拷过去,等于我们一边在 argv 里显式写 `--sandbox read-only`、
//   一边把一份把沙箱关掉的配置塞进 `$CODEX_HOME` —— 隔离变成了摆设,而且是**看起来做了**的那种摆设。
// 故本类型只做一件事:**从源 CODEX_HOME 只拷 `auth.json`,别的一个字节都不碰**。
//
// 实证依据(02 spike `spike-codex-exec/findings.md` §0 与「对适配层设计的直接影响」第 1 条):
//   * 8/8 次真调证明鉴权**只认** `$CODEX_HOME/auth.json`,不依赖 `~/.codex` 下任何其它文件;
//   * 反向验证:CODEX_HOME 指向一个连 auth.json 都没有的空目录时,请求带不上 bearer token,
//     服务端直接 401,**没有**静默回退到用户真身份 —— 即「隔离失败」这一档是 **fail-closed** 的;
//   * 意外发现 3:`$CODEX_HOME` 是「用后即脏」的运行时状态盘(跑几次会自己长出 config.toml / sessions/ /
//     cache/ / 多个 sqlite),故它必须是**每任务全新目录 + 用完即弃**,绝不是「建一次反复复用」的配置目录。
//
// **源目录只读**:本类型对 `source` 只发生一次 `read`,零 `write` / `createDirectory` / `removeDirectory`。
//   这条有断言钉死(FakeFileSystem 逐路径查写入次数),因为它是「绝不碰用户真 `~/.codex`」的可验证形式。

/// 每任务 CODEX_HOME 准备 / 清理过程中可能抛出的错误。
public enum AgentCodexHomeError: Error, Equatable, Sendable {
    /// 目标目录与源目录是同一个 —— 拒绝执行。
    ///
    /// **这是本文件最要紧的一道闸**:若两者相同,后面的「写 auth.json 到目标」就是往用户真目录里写,
    ///   而 `discard` 更是会把用户的 `~/.codex` **整个删掉**。这种调用一定是接线错了,让它响,不要「顺手照做」。
    case destinationEqualsSource(String)
    /// 目标目录路径为空(拼路径会拼出一个诡异的相对路径,一律拒绝)。
    case emptyDestination
    /// 源目录里没有 `auth.json`。**目标目录此时已经建好且为空** —— 调用方可以选择照常跑
    /// (02 spike 实证:无 auth 即 401 fail-closed,不会误用真实身份),但必须是它**显式**做的决定。
    case authFileMissing(String)
}

/// 每任务独立 `$CODEX_HOME` 的准备与清理。
public enum AgentCodexHome {
    /// 鉴权文件名 —— **唯一**会被拷贝的文件。
    public static let authFileName = "auth.json"
    /// 明确**不拷**的文件(名字写在这里是为了让「为什么不拷」有个可指的落点,见文件头)。
    public static let neverCopiedFileName = "config.toml"

    /// 拼一段路径(与 `AgentTaskWorkspace.join` 同款:去掉 base 末尾多余的 `/` 再接一段)。
    static func join(_ base: String, _ component: String) -> String {
        var b = base
        while b.count > 1 && b.hasSuffix("/") { b.removeLast() }
        return b + "/" + component
    }

    /// 去掉末尾多余的 `/`(`/a/b/` 与 `/a/b` 是同一个目录)——只用于「源与目标是不是同一个」的判定。
    static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// 准备任务私有的 CODEX_HOME:建目录 → 从 `source` **只**拷 `auth.json` 过去。
    ///
    /// 次序是刻意的:**先建目录,再拷 auth**。于是「源里没有 auth.json」这一支抛错时,
    ///   目标目录**已经存在且为空** —— 调用方可以据此选择「照常跑,让它 401 fail-closed」
    ///   (02 spike 实证的安全档),而不是被迫中止。反过来先拷再建目录做不到这一点。
    ///
    /// 只读源目录:全过程对 `source` 只有一次 `read`(且只读 auth.json 这一个路径)。
    public static func prepare(from source: String, to destination: String, fs: AgentFileSystemPort) throws {
        guard !destination.isEmpty else { throw AgentCodexHomeError.emptyDestination }
        guard normalize(source) != normalize(destination) else {
            throw AgentCodexHomeError.destinationEqualsSource(normalize(source))
        }
        try fs.createDirectory(at: destination)

        let sourceAuth = join(source, authFileName)
        guard fs.exists(at: sourceAuth) else {
            throw AgentCodexHomeError.authFileMissing(sourceAuth)
        }
        let contents = try fs.read(at: sourceAuth)
        // **走凭据通道(0600),不是普通 write**:这份内容是用户的 OAuth token 副本。
        //   普通 write 在默认 umask 下落成 0644 —— 一份人人可读的 token 拷贝,躺在会被 tar 走 / 被同步 /
        //   被误分享的任务目录里。源文件本身通常是 0600,副本没有理由比它松。
        try fs.writePrivate(contents, to: join(destination, authFileName))
        // 到此为止。config.toml 与源目录里的其它一切(sessions/ / cache/ / sqlite / pets/ …)一律不看不碰。
    }

    /// 用完即弃:删掉任务私有的 CODEX_HOME。
    ///
    /// 幂等(目录不存在为 no-op):清理路径会在多条出口上被调用(正常收尾 / 失败收尾 / 取消收尾),
    ///   为「已经删过一次」抛错只会让收尾逻辑长出一堆 try?。
    /// **绝不接受空路径**(空串拼出来的路径会指向意想不到的地方)。
    public static func discard(_ destination: String, fs: AgentFileSystemPort) throws {
        guard !destination.isEmpty else { throw AgentCodexHomeError.emptyDestination }
        guard fs.exists(at: destination) else { return }
        try fs.removeDirectory(at: destination)
    }
}
