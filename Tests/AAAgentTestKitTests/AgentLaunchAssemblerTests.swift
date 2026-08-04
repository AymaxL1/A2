// 17 票:从 `AAAgentTestKit.AgentLaunchAssemblerTests` 迁到 swift-testing
//   (迁移口径见 Tests/AAHostTestKitTests/RegistryConformanceTests.swift 头注)。
//
// 启动参数组装 + 每任务 CODEX_HOME 隔离的纯逻辑测试(agent-delegation 07)。
//
// **本套件绝不拉起任何进程,更绝不真跑 claude / codex**:真拉起会消耗用户真实配额与费用。
// CODEX_HOME 那一组同样是纯逻辑:全程跑在 `FakeFileSystem` 上,**一个字节都不碰用户真实的 `~/.codex/`**。

import Foundation
import Testing
import AAContracts
import AAAgentCore
import AAAgentTestKit

@Suite("agent 07 启动参数与 CODEX_HOME 隔离 —— LAUNCHASM_TESTS passed=(逐条 @Test)")
struct AgentLaunchAssemblerTests {

    // MARK: - 助手

    private static let claudePath = "/usr/local/bin/claude"
    private static let codexPath = "/Users/fake/.codex/bin/codex"
    private static let workdir = "/fake/agent-tasks/20260730-0100-hi-ab12/work"

    private static func claudeDelegation(
        model: String? = nil,
        allowedTools: [String]? = nil,
        hostEnvironment: [String: String] = [:],
        extraArguments: [String] = []
    ) -> AgentDelegation {
        AgentDelegation(
            vendor: .claude,
            prompt: "Reply with the word OK",
            model: model,
            workingDirectory: workdir,
            executablePath: claudePath,
            codexHome: nil,                 // Claude 侧恒 nil(该参数刻意无默认值,漏传要编译期就红)
            allowedTools: allowedTools,
            hostEnvironment: hostEnvironment,
            extraArguments: extraArguments
        )
    }

    private static func codexDelegation(
        prompt: String = "List the files here",
        model: String? = nil,
        codexHome: String? = "/fake/agent-tasks/20260730-0100-hi-ab12/codex-home",
        sandbox: AgentCodexSandbox = .readOnly,
        hostEnvironment: [String: String] = [:],
        extraArguments: [String] = []
    ) -> AgentDelegation {
        AgentDelegation(
            vendor: .codex,
            prompt: prompt,
            model: model,
            workingDirectory: workdir,
            executablePath: codexPath,
            codexHome: codexHome,
            sandbox: sandbox,
            hostEnvironment: hostEnvironment,
            extraArguments: extraArguments
        )
    }

    /// argv 里 `flag` 出现的次数(重复出现会让 CLI 行为不确定,故次数本身就是被断言的对象)。
    private static func count(_ flag: String, in args: [String]) -> Int {
        args.filter { $0 == flag }.count
    }

    /// `flag` 紧随其后的那个值(不存在则 nil)。
    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// 相邻两个 token 是否恰好按此顺序出现。
    private static func hasPair(_ flag: String, _ expected: String, in args: [String]) -> Bool {
        value(after: flag, in: args) == expected
    }

    // MARK: - ① Claude argv(每一项都有 01 spike 的样本背书)

    @Test("Claude 组装:argv 逐项有 01 spike 样本背书(-p / stream-json 双向 / verbose / bypassPermissions / 无 --bare)")
    func claudeArguments() {
        let spec = AgentLaunchAssembler.assemble(Self.claudeDelegation())
        let args = spec.arguments

        #expect(args.contains("-p"),
                "Claude 组装:含 -p 单发形态(01 spike 8/8 样本的调用形状)")
        #expect(Self.hasPair("--output-format", "stream-json", in: args),
                "Claude 组装:含 --output-format stream-json(归一化层消费的就是这个流)")
        #expect(Self.hasPair("--input-format", "stream-json", in: args),
                "Claude 组装:含 --input-format stream-json(prompt 走 stdin 一行 JSON,样本 06 实证)")
        #expect(args.contains("--verbose"),
                "Claude 组装:含 --verbose(01 spike 8/8 成功样本都带,不是可选装饰)")
        #expect(Self.hasPair(AgentLaunchAssembler.claudePermissionModeFlag,
                             AgentLaunchAssembler.claudePermissionModeValue, in: args),
                "Claude 组装:含 --permission-mode bypassPermissions(不给不是挂起等审批,是 CLI 同步自动拒绝)")
        #expect(!args.contains("--bare"),
                "Claude 组装:绝不出现 --bare(它把认证限定为 API key,本机订阅 OAuth 会直接打不开认证)")
        #expect(spec.executablePath == Self.claudePath && spec.workingDirectory == Self.workdir,
                "Claude 组装:可执行路径与工作目录原样落进启动规格")

        // --model 条件出现:这两条必须成对断言。
        #expect(Self.count("--model", in: args) == 0,
                "Claude 组装:未指定 model 时绝不出现 --model(用 agent 自己的默认,不替用户做主)")
        let withModel = AgentLaunchAssembler.assemble(Self.claudeDelegation(model: "sonnet"))
        #expect(Self.count("--model", in: withModel.arguments) == 1
                && Self.value(after: "--model", in: withModel.arguments) == "sonnet",
                "Claude 组装:指定 model 时 --model 恰出现一次且值逐字透传")

        // stdin 处置(写完不发 EOF 进程不自退,是 01 spike 两次独立复现的行为)。
        if case let .writeThenKeepOpen(payload) = spec.stdin {
            #expect(!payload.contains("\n"),
                    "Claude 组装:stdin 是 writeThenKeepOpen 且载荷是单行(ndjson 每行一条记录)")
        } else {
            Issue.record("Claude 组装:stdin 是 writeThenKeepOpen 且载荷是单行(ndjson 每行一条记录)")
        }
    }

    @Test("Claude stdin:那一行是可解析的合法 JSON,形状与转义逐字照样本 06")
    func claudeStdinLine() {
        let prompt = "带\"引号\"、反斜杠 \\ 与换行\n的中文 prompt"
        let line = AgentLaunchAssembler.claudeStdinLine(prompt: prompt)

        #expect(!line.contains("\n") && !line.contains("\r"),
                "Claude stdin:含引号与换行的 prompt 编码后仍是单行(手拼字符串必然在此翻车)")

        guard let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(root) = decoded else {
            Issue.record("Claude stdin:那一行是可解析的合法 JSON(解一遍验,不靠肉眼)")
            Issue.record("Claude stdin:形状是 type=user + message.role=user + message.content 为纯字符串(逐字照样本 06)")
            Issue.record("Claude stdin:prompt 原文经 JSON 解码后逐字还原(转义正确)")
            return
        }
        #expect(Bool(true), "Claude stdin:那一行是可解析的合法 JSON(解一遍验,不靠肉眼)")

        var roleOK = false
        var contentText: String? = nil
        if case let .object(message)? = root["message"] {
            if case let .string(role)? = message["role"] { roleOK = (role == "user") }
            if case let .string(text)? = message["content"] { contentText = text }
        }
        var typeOK = false
        if case let .string(type)? = root["type"] { typeOK = (type == "user") }

        #expect(typeOK && roleOK && contentText != nil,
                "Claude stdin:形状是 type=user + message.role=user + message.content 为纯字符串(逐字照样本 06)")
        #expect(contentText == prompt,
                "Claude stdin:prompt 原文经 JSON 解码后逐字还原(转义正确)")
    }

    // MARK: - ② blocked-args 不可覆盖(双层信任模型的地基)

    @Test("blocked-args(Claude):调用方三种写法都改不动权限档/输出格式/白名单,非 blocked 参数原样保留")
    func blockedArgumentsClaude() {
        let hostile = Self.claudeDelegation(extraArguments: [
            "--permission-mode", "acceptEdits",
            "--permission-mode=plan",
            "--dangerously-skip-permissions",
            "--output-format", "json",
            "--allowedTools", "Task,SendMessage,RemoteTrigger",
            "--bare",
            "--add-dir", "/",                       // 不在 blocked 表里 → 应当原样保留
        ])
        let args = AgentLaunchAssembler.assemble(hostile).arguments

        #expect(Self.count(AgentLaunchAssembler.claudePermissionModeFlag, in: args) == 1,
                "blocked-args:调用方三次试图改权限档,--permission-mode 仍恰好出现一次(重复参数会让 CLI 行为不确定)")
        #expect(Self.value(after: AgentLaunchAssembler.claudePermissionModeFlag, in: args)
                == AgentLaunchAssembler.claudePermissionModeValue,
                "blocked-args:权限档仍是 bypassPermissions,调用方覆盖不动(双层信任模型的地基)")
        #expect(!args.contains("acceptEdits") && !args.contains("--permission-mode=plan"),
                "blocked-args:等号形态 --permission-mode=plan 与裸值 acceptEdits 都被剔干净(堵一半等于没堵)")
        #expect(!args.contains("--dangerously-skip-permissions"),
                "blocked-args:--dangerously-skip-permissions 被剔除(权限档只留一个来源)")
        #expect(Self.count("--output-format", in: args) == 1 && Self.hasPair("--output-format", "stream-json", in: args),
                "blocked-args:调用方改不动输出格式(改了归一化层直接失效)")
        #expect(Self.count(AgentLaunchAssembler.claudeAllowedToolsFlag, in: args) == 1
                && Self.value(after: AgentLaunchAssembler.claudeAllowedToolsFlag, in: args)?.contains("SendMessage") != true,
                "blocked-args:调用方塞进来的工具白名单(含 Task/SendMessage)被剔除,能力面只能收紧不能放开")
        #expect(!args.contains("--bare"),
                "blocked-args:--bare 被剔除(它会把订阅 OAuth 认证打不开)")
        #expect(args.contains("--add-dir") && args.contains("/"),
                "blocked-args:不在 blocked 表里的追加参数原样保留(只堵组装器自己拥有的旋钮,不当保姆)")
    }

    @Test("blocked-args(Codex):-s / -c sandbox_mode= / -C / --dangerously-bypass 等价旁路一并堵住")
    func blockedArgumentsCodex() {
        let hostileCodex = Self.codexDelegation(extraArguments: [
            "-c", "sandbox_mode=danger-full-access",
            "--sandbox", "danger-full-access",
            "-C", "/",
            "--dangerously-bypass-approvals-and-sandbox",
        ])
        let codexArgs = AgentLaunchAssembler.assemble(hostileCodex).arguments
        #expect(Self.count("--sandbox", in: codexArgs) == 1
                && Self.value(after: "--sandbox", in: codexArgs) == AgentCodexSandbox.readOnly.rawValue,
                "blocked-args:Codex 沙箱档仍是 read-only,调用方的 --sandbox danger-full-access 被剔除")
        #expect(!codexArgs.contains("-c") && !codexArgs.contains("sandbox_mode=danger-full-access"),
                "blocked-args:Codex 的 -c sandbox_mode=… 旁路也被堵住(等价旁路不堵等于没堵 -s)")
        #expect(!codexArgs.contains("-C") && !codexArgs.contains("--dangerously-bypass-approvals-and-sandbox"),
                "blocked-args:Codex 的 -C 换工作根与 --dangerously-bypass-approvals-and-sandbox 都被剔除")
        #expect(AgentLaunchAssembler.blockedArguments(for: .claude)
                    .contains(AgentLaunchAssembler.claudePermissionModeFlag)
                && AgentLaunchAssembler.blockedArguments(for: .codex).contains("--sandbox"),
                "blocked-args:两家的 blocked 表各自包含最要害的那一项(权限档 / 沙箱档)")
    }

    @Test("blocked-args:clap 短旗标**贴写形态**(-sx / -cx / -C/ / -mx)同样被剔除,非 blocked 不误伤")
    func blockedArgumentsAttachedShortFlags() {
        // 只堵 `-s x` 与 `-s=x` 而漏掉 `-sx`,调用方一个 token 就能把沙箱拧到 danger-full-access。
        let attached = AgentLaunchAssembler.assemble(Self.codexDelegation(extraArguments: [
            "-sdanger-full-access",                  // 贴写沙箱档
            "-csandbox_mode=danger-full-access",     // 贴写 -c 等价旁路
            "-C/",                                   // 贴写换工作根
            "-mgpt-nonexistent",                     // 贴写 model
            "--keep-me",                             // 不在 blocked 表里 → 必须原样留下
        ])).arguments
        #expect(!attached.contains(where: { $0.hasPrefix("-s") && $0 != "--sandbox" && $0 != "-s" }),
                "blocked-args:贴写形态 -sdanger-full-access 被剔除(clap 短旗标可粘值,只堵分开写的等于没堵)")
        #expect(!attached.contains(where: { $0.hasPrefix("-c") && $0 != "-c" }),
                "blocked-args:贴写形态 -csandbox_mode=… 被剔除(-c 的等价旁路同样有贴写写法)")
        #expect(!attached.contains(where: { $0.hasPrefix("-C") }),
                "blocked-args:贴写形态 -C/ 被剔除(换工作根 = 让 agent 去别处干活,且不会撞出重复参数)")
        #expect(!attached.contains(where: { $0.hasPrefix("-m") && $0 != "-m" }),
                "blocked-args:贴写形态 -mgpt-nonexistent 被剔除(model 有类型化字段)")
        #expect(attached.contains("--keep-me"),
                "blocked-args:贴写形态过滤不误伤非 blocked 参数(前缀匹配只对 blocked 短旗标生效)")
        #expect(Self.hasPair("--sandbox", "read-only", in: attached),
                "blocked-args:贴写旁路全被剔除后,沙箱档仍是我们写的 read-only")
    }

    @Test("blocked-args:--mcp-config / --settings 这两根能力面杠杆被剔除,--strict-mcp-config 仍在")
    func blockedArgumentsCapabilityLevers() {
        let mcpArgs = AgentLaunchAssembler.assemble(Self.claudeDelegation(extraArguments: [
            "--mcp-config", "/tmp/evil.json", "--settings", "/tmp/evil-settings.json",
        ])).arguments
        #expect(!mcpArgs.contains("--mcp-config") && !mcpArgs.contains("/tmp/evil.json"),
                "blocked-args:--mcp-config 被剔除(--strict-mcp-config 的语义正是「只认它传进来的那份」,漏堵等于把钥匙插门上)")
        #expect(!mcpArgs.contains("--settings") && !mcpArgs.contains("/tmp/evil-settings.json"),
                "blocked-args:--settings 被剔除(它能注入 hooks 等配置面)")
        #expect(mcpArgs.contains(AgentLaunchAssembler.claudeStrictMCPFlag),
                "blocked-args:剔除杠杆之后我们自己的 --strict-mcp-config 仍在(收紧没被连坐删掉)")
    }

    // MARK: - ③ 能力面收紧(01 spike findings 第 7 条)

    @Test("能力面:--strict-mcp-config + 默认工具白名单(无 Task/SendMessage),且可被收得更窄")
    func capabilitySurfaceIsNarrowed() {
        let args = AgentLaunchAssembler.assemble(Self.claudeDelegation()).arguments
        #expect(args.contains(AgentLaunchAssembler.claudeStrictMCPFlag),
                "能力面:含 --strict-mcp-config(无头子进程默认继承宿主全部 MCP 面,不收紧就是失控)")
        let whitelist = Self.value(after: AgentLaunchAssembler.claudeAllowedToolsFlag, in: args)
        #expect(whitelist != nil && !whitelist!.isEmpty,
                "能力面:含工具白名单参数且非空(01 spike:样本里 tools 含 Task/SendMessage/RemoteTrigger 等本机项目工具)")
        #expect(whitelist?.contains("Task") != true && whitelist?.contains("SendMessage") != true,
                "能力面:默认白名单里没有 Task/SendMessage 这类宿主项目工具(被委托 agent 不该能再派子代理)")
        #expect(AgentLaunchAssembler.claudeDefaultAllowedTools.contains("Read")
                && AgentLaunchAssembler.claudeDefaultAllowedTools.contains("Bash"),
                "能力面:默认白名单保留 vanilla 内置工具(收紧不等于让 agent 什么都干不了)")

        // 白名单可覆盖为**更窄**的集合(只读诊断任务):这是收紧方向,允许。
        let readOnly = AgentLaunchAssembler.assemble(Self.claudeDelegation(allowedTools: ["Read", "Glob", "Grep"])).arguments
        #expect(Self.value(after: AgentLaunchAssembler.claudeAllowedToolsFlag, in: readOnly) == "Read,Glob,Grep",
                "能力面:调用方可把白名单收得更窄(只读诊断任务),逐字生效")
    }

    // MARK: - ④ Codex argv

    @Test("Codex 组装:exec --json --skip-git-repo-check + 沙箱档 + prompt 位置参数在最后,stdin=devNull")
    func codexArguments() {
        let spec = AgentLaunchAssembler.assemble(Self.codexDelegation())
        let args = spec.arguments

        #expect(args.first == "exec",
                "Codex 组装:首个参数是 exec 子命令(02 spike 8/8 样本的 argv 形状)")
        #expect(args.contains("--json"),
                "Codex 组装:含 --json(事件流是 JSONL,归一化层消费的就是它)")
        #expect(args.contains("--skip-git-repo-check"),
                "Codex 组装:含 --skip-git-repo-check(任务工作区不是 git 仓库,不给会拒跑)")
        #expect(Self.hasPair("--sandbox", AgentCodexSandbox.readOnly.rawValue, in: args),
                "Codex 组装:默认沙箱档是 read-only(显式写出来,不靠 CLI 的默认值)")
        #expect(args.last == "List the files here",
                "Codex 组装:prompt 是最后一个位置参数(exec [OPTIONS] [PROMPT] 的形状)")
        if case .devNull = spec.stdin {
            #expect(Bool(true), "Codex 组装:stdin 是 devNull(不给会静默挂起 —— 02 spike 意外发现 1,最隐蔽的坑)")
        } else {
            Issue.record("Codex 组装:stdin 是 devNull(不给会静默挂起 —— 02 spike 意外发现 1,最隐蔽的坑)")
        }

        #expect(Self.count("--model", in: args) == 0,
                "Codex 组装:未指定 model 时绝不出现 --model")
        let withModel = AgentLaunchAssembler.assemble(Self.codexDelegation(model: "gpt-5")).arguments
        #expect(Self.count("--model", in: withModel) == 1 && Self.value(after: "--model", in: withModel) == "gpt-5"
                && withModel.last == "List the files here",
                "Codex 组装:指定 model 时 --model 恰出现一次,且 prompt 仍在最后")

        // 放开沙箱必须是调用方**显式**的动作(默认档绝不是它)。
        let wide = AgentLaunchAssembler.assemble(Self.codexDelegation(sandbox: .workspaceWrite)).arguments
        #expect(Self.hasPair("--sandbox", "workspace-write", in: wide),
                "Codex 组装:调用方显式指定 workspace-write 时如实放开(可写边界锁在 cwd,exec4 实证)")

        // 以 `-` 开头的 prompt 会被 clap 当旗标 —— 此时(且仅此时)补一个 `--` 终止符。
        let dashPrompt = AgentLaunchAssembler.assemble(Self.codexDelegation(prompt: "--help me")).arguments
        #expect(dashPrompt.count >= 2 && dashPrompt[dashPrompt.count - 2] == "--" && dashPrompt.last == "--help me",
                "Codex 组装:以减号开头的 prompt 前补 -- 终止符(否则会被当成旗标解析)")
        #expect(!AgentLaunchAssembler.assemble(Self.codexDelegation()).arguments.contains("--"),
                "Codex 组装:正常 prompt 不补 -- (保持 8/8 样本验证过的裸形状)")
    }

    // MARK: - ⑤ 环境白名单 + CODEX_HOME 指向任务私有目录

    @Test("环境白名单:CODEX_HOME 指向任务私有目录并压过继承值;凭据类与白名单外变量一律不透传")
    func environmentAllowlist() {
        let taskHome = "/fake/agent-tasks/20260730-0100-hi-ab12/codex-home"
        let hostEnv = [
            "HOME": "/Users/fake",
            "PATH": "/usr/bin:/bin",
            "ANTHROPIC_API_KEY": "sk-should-not-leak",
            "OPENAI_API_KEY": "sk-should-not-leak-either",
            "CODEX_HOME": "/Users/fake/.codex",          // 用户真目录:绝不能漏进子进程
            "AA_SECRET_INTERNAL": "internal-endpoint",
        ]
        let env = AgentLaunchAssembler.assemble(
            Self.codexDelegation(codexHome: taskHome, hostEnvironment: hostEnv)
        ).environment

        #expect(env["CODEX_HOME"] == taskHome,
                "Codex 环境:CODEX_HOME 指向任务私有目录(每任务独立,用完即弃)")
        #expect(env["CODEX_HOME"] != "/Users/fake/.codex",
                "Codex 环境:宿主继承来的 CODEX_HOME 被我们的值压过(否则任务会去读用户真配置里的 danger-full-access)")
        #expect(env["HOME"] == "/Users/fake" && env["PATH"] == "/usr/bin:/bin",
                "环境白名单:HOME 与 PATH 如实透传(子进程环境不隐式继承,要什么必须显式写明)")
        #expect(env["ANTHROPIC_API_KEY"] == nil && env["OPENAI_API_KEY"] == nil,
                "环境白名单:凭据类变量不带进子进程(本机是订阅 OAuth,带 API key 会静默改变计费主体)")
        #expect(env["AA_SECRET_INTERNAL"] == nil,
                "环境白名单:白名单之外的宿主变量一律不透传(白名单漏一个只是少个变量,黑名单漏一个就是泄密)")

        // Claude 侧不该长出 CODEX_HOME(哪怕委托里带了)。
        let claudeEnv = AgentLaunchAssembler.assemble(
            AgentDelegation(vendor: .claude, prompt: "hi", workingDirectory: Self.workdir,
                            executablePath: Self.claudePath, codexHome: taskHome, hostEnvironment: hostEnv)
        ).environment
        #expect(claudeEnv["CODEX_HOME"] == nil,
                "环境白名单:Claude 侧不注入 CODEX_HOME(它是 Codex 专用,别互相污染)")
    }

    // MARK: - ⑥ CODEX_HOME 隔离:只拷 auth.json,对源目录零写入

    @Test("CODEX_HOME 隔离:只拷 auth.json(走 0600 凭据通道),绝不拷 config.toml,对源目录零写入")
    func codexHomeIsolation() {
        let fs = FakeFileSystem()
        let source = "/fake/home/.codex"
        let destination = "/fake/agent-tasks/20260730-0100-hi-ab12/codex-home"

        // 造一个「和用户真目录同构」的源:auth + 那份把沙箱关掉的 config + 运行时状态。
        try? fs.createDirectory(at: source)
        try? fs.write(#"{"tokens":{"access_token":"secret"}}"#, to: source + "/auth.json")
        try? fs.write("sandbox_mode = \"danger-full-access\"\n", to: source + "/config.toml")
        try? fs.createDirectory(at: source + "/sessions")
        try? fs.write("{}", to: source + "/sessions/s1.jsonl")
        try? fs.createDirectory(at: "/fake/agent-tasks/20260730-0100-hi-ab12")

        /// 源目录里全部路径的写入次数之和 ——`prepare` 前后取两次比对,差值必须是 **0**。
        func sourceWriteTally() -> Int {
            let paths = [source + "/auth.json", source + "/config.toml", source + "/sessions/s1.jsonl"]
            return paths.reduce(0) { $0 + fs.writeCount(at: $1) + fs.appendCount(at: $1) }
        }
        let writesBeforePrepare = sourceWriteTally()

        do {
            try AgentCodexHome.prepare(from: source, to: destination, fs: fs)
            #expect(Bool(true), "CODEX_HOME 隔离:prepare 正常完成(建目录 + 拷 auth.json)")
        } catch {
            Issue.record("CODEX_HOME 隔离:prepare 正常完成(建目录 + 拷 auth.json)")
        }

        let inDestination = fs.allFilePaths().filter { $0.hasPrefix(destination + "/") }
        #expect(inDestination == [destination + "/auth.json"],
                "CODEX_HOME 隔离:任务私有目录里**只有** auth.json 一个文件(别的一个字节都没拷)")
        #expect(!fs.exists(at: destination + "/config.toml"),
                "CODEX_HOME 隔离:绝不拷 config.toml(用户真配置里是 danger-full-access,拷过去等于把沙箱关掉)")
        #expect(fs.contents(at: destination + "/auth.json") == #"{"tokens":{"access_token":"secret"}}"#,
                "CODEX_HOME 隔离:auth.json 内容逐字拷贝(鉴权只认这一个文件,02 spike 8/8 实证)")
        // 副本走的必须是**凭据通道**(契约 0600),不能是普通 write。
        #expect(fs.wasWrittenPrivately(at: destination + "/auth.json"),
                "CODEX_HOME 隔离:auth.json 走的是凭据通道 writePrivate(0600),不是普通 write(0644 的 token 拷贝)")

        // **对源目录零写入**——这是「绝不碰用户真 ~/.codex」的可验证形式。
        #expect(sourceWriteTally() == writesBeforePrepare,
                "CODEX_HOME 隔离:prepare 全过程对源目录零写入(源目录只读,用户真 ~/.codex 一个字节不动)")
        #expect(fs.contents(at: source + "/config.toml") == "sandbox_mode = \"danger-full-access\"\n"
                && fs.exists(at: source + "/sessions/s1.jsonl"),
                "CODEX_HOME 隔离:源目录的 config.toml 与 sessions 原样健在(既不改也不删)")
    }

    @Test("CODEX_HOME 守卫与清理:目标==源拒绝 / 缺 auth.json 如实抛错 / discard 删净且幂等 / 空路径拒绝")
    func codexHomeGuardsAndDiscard() {
        let fs = FakeFileSystem()
        let source = "/fake/home/.codex"
        try? fs.createDirectory(at: source)
        try? fs.write("{}", to: source + "/auth.json")
        try? fs.write("sandbox_mode = \"danger-full-access\"\n", to: source + "/config.toml")

        // 目标 == 源:必须拒绝。放行的话 discard 会把用户的 ~/.codex 整个删掉。
        var refused = false
        do { try AgentCodexHome.prepare(from: source, to: source + "/", fs: fs) }
        catch AgentCodexHomeError.destinationEqualsSource { refused = true }
        catch { refused = false }
        #expect(refused,
                "CODEX_HOME 守卫:目标目录与源目录相同时拒绝执行(放行的话 discard 会把用户真目录整个删掉)")
        #expect(fs.exists(at: source + "/config.toml"),
                "CODEX_HOME 守卫:被拒绝那次没有对源目录产生任何副作用")

        // 源里没有 auth.json:抛 authFileMissing,但目标目录**已经建好且为空**。
        let emptySource = "/fake/home/.codex-empty"
        let destination = "/fake/tasks/t2/codex-home"
        try? fs.createDirectory(at: emptySource)
        try? fs.createDirectory(at: "/fake/tasks/t2")
        var missing = false
        do { try AgentCodexHome.prepare(from: emptySource, to: destination, fs: fs) }
        catch AgentCodexHomeError.authFileMissing { missing = true }
        catch { missing = false }
        #expect(missing,
                "CODEX_HOME 守卫:源里没有 auth.json 时如实抛错(不静默给一个没鉴权的目录让人猜)")
        #expect(fs.exists(at: destination) && fs.allFilePaths().filter { $0.hasPrefix(destination + "/") }.isEmpty,
                "CODEX_HOME 守卫:抛 authFileMissing 时目标目录已建好且为空(调用方可选择让它 401 fail-closed)")

        // discard:删干净 + 幂等。
        try? AgentCodexHome.prepare(from: source, to: "/fake/tasks/t3/codex-home", fs: fs)
        try? fs.createDirectory(at: "/fake/tasks/t3/codex-home/sessions")   // 模拟 codex 运行时自己长出来的状态
        try? fs.write("{}", to: "/fake/tasks/t3/codex-home/sessions/s.jsonl")
        var discarded = false
        do { try AgentCodexHome.discard("/fake/tasks/t3/codex-home", fs: fs); discarded = true } catch { discarded = false }
        #expect(discarded && !fs.exists(at: "/fake/tasks/t3/codex-home")
                && !fs.exists(at: "/fake/tasks/t3/codex-home/sessions/s.jsonl"),
                "CODEX_HOME 清理:discard 把任务私有目录连同运行时长出来的状态一并删净(用后即弃)")
        var again = false
        do { try AgentCodexHome.discard("/fake/tasks/t3/codex-home", fs: fs); again = true } catch { again = false }
        #expect(again,
                "CODEX_HOME 清理:discard 幂等(收尾有多条出口,为已删过一次抛错只会逼出一堆 try?)")
        var emptyRefused = false
        do { try AgentCodexHome.discard("", fs: fs) } catch AgentCodexHomeError.emptyDestination { emptyRefused = true } catch {}
        #expect(emptyRefused,
                "CODEX_HOME 清理:空路径一律拒绝(空串拼出来的路径会指向意想不到的地方)")
    }
}
