// AAAgentTestKit —— 启动参数组装 + 每任务 CODEX_HOME 隔离的纯逻辑测试(agent-delegation 07)。
// 依赖边:AAAgentTestKit → AAAgentCore、AAContracts(+ 系统 Foundation)。
//
// **本套件绝不拉起任何进程,更绝不真跑 claude / codex**:真拉起会消耗用户真实配额与费用,
//   且 Claude 侧 bypass 对文件系统**无隔离**(01 spike 第 7 题:`../` 与 `/tmp/…` 越界写均成功)。
//   门禁要能验的恰恰是「拉起之前那一步组出来的东西对不对」—— 组装是纯函数,故整份 `AgentLaunchSpec`
//   在不碰任何进程的前提下逐条断言得出来,这正是 07 票把组装放进 AAAgentCore 而不是 CLI 的理由。
//
// CODEX_HOME 那一组同样是纯逻辑:全程跑在 `FakeFileSystem` 上,**一个字节都不碰用户真实的 `~/.codex/`**
//   (那是用户真配置,里面写着 `sandbox_mode = "danger-full-access"`)。
//
// 覆盖六件事(与 07 票面第 2、3 条 checkbox 对齐):
//   ① Claude argv:单发 + stream-json 双向 + bypass 权限档 + `--verbose`,model 条件透传,stdin 一行合法 JSON;
//   ② blocked-args 不可覆盖:调用方想把权限档拧成别的档 → 组出来仍是 bypassPermissions 且**只出现一次**;
//   ③ 能力面收紧:`--strict-mcp-config` + 工具白名单都在(不收紧 = 把宿主全部插件面交给被委托 agent);
//   ④ Codex argv:`exec --json --skip-git-repo-check` + 沙箱档 + prompt 位置参数在最后,stdin 是 devNull;
//   ⑤ 环境白名单:CODEX_HOME 指向任务私有目录且压过继承值;凭据类变量不带进子进程;
//   ⑥ CODEX_HOME 隔离:只拷 auth.json、绝不拷 config.toml,且对源目录**零写入**。
//
// 说明:本套件由 check.sh 动态生成的 runner 执行,打印 report.lines;各描述串是 check.sh 阶段 B
//   assert_contains 的定长子串目标,**不得随意改字**(改则同步改 check.sh 断言组 1i)。

import Foundation
import AAContracts
import AAAgentCore

/// 启动参数组装 + CODEX_HOME 隔离的纯逻辑测试。
public enum AgentLaunchAssemblerTests {

    public static func run() -> AgentTestReport {
        var report = AgentTestReport()
        testClaudeArguments(&report)
        testClaudeStdinLine(&report)
        testBlockedArgumentsCannotBeOverridden(&report)
        testCapabilitySurfaceIsNarrowed(&report)
        testCodexArguments(&report)
        testEnvironmentAllowlist(&report)
        testCodexHomeIsolation(&report)
        testCodexHomeGuardsAndDiscard(&report)
        return report
    }

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

    /// 相邻两个 token 是否恰好按此顺序出现(用于「`--output-format stream-json` 是一对」这种断言)。
    private static func hasPair(_ flag: String, _ expected: String, in args: [String]) -> Bool {
        value(after: flag, in: args) == expected
    }

    // MARK: - ① Claude argv(每一项都有 01 spike 的样本背书)

    private static func testClaudeArguments(_ report: inout AgentTestReport) {
        let spec = AgentLaunchAssembler.assemble(claudeDelegation())
        let args = spec.arguments

        report.check(args.contains("-p"),
                     "Claude 组装:含 -p 单发形态(01 spike 8/8 样本的调用形状)")
        report.check(hasPair("--output-format", "stream-json", in: args),
                     "Claude 组装:含 --output-format stream-json(归一化层消费的就是这个流)")
        report.check(hasPair("--input-format", "stream-json", in: args),
                     "Claude 组装:含 --input-format stream-json(prompt 走 stdin 一行 JSON,样本 06 实证)")
        report.check(args.contains("--verbose"),
                     "Claude 组装:含 --verbose(01 spike 8/8 成功样本都带,不是可选装饰)")
        report.check(hasPair(AgentLaunchAssembler.claudePermissionModeFlag,
                             AgentLaunchAssembler.claudePermissionModeValue, in: args),
                     "Claude 组装:含 --permission-mode bypassPermissions(不给不是挂起等审批,是 CLI 同步自动拒绝)")
        report.check(!args.contains("--bare"),
                     "Claude 组装:绝不出现 --bare(它把认证限定为 API key,本机订阅 OAuth 会直接打不开认证)")
        report.check(spec.executablePath == claudePath && spec.workingDirectory == workdir,
                     "Claude 组装:可执行路径与工作目录原样落进启动规格")

        // --model 条件出现:这两条必须成对断言 —— 只验「传了会出现」验不出「没传时悄悄塞了个默认 model」。
        report.check(count("--model", in: args) == 0,
                     "Claude 组装:未指定 model 时绝不出现 --model(用 agent 自己的默认,不替用户做主)")
        let withModel = AgentLaunchAssembler.assemble(claudeDelegation(model: "sonnet"))
        report.check(count("--model", in: withModel.arguments) == 1
                     && value(after: "--model", in: withModel.arguments) == "sonnet",
                     "Claude 组装:指定 model 时 --model 恰出现一次且值逐字透传")

        // stdin 处置(不是「随便哪种都行」:写完不发 EOF 进程不自退,是 01 spike 两次独立复现的行为)。
        if case let .writeThenKeepOpen(payload) = spec.stdin {
            report.check(!payload.contains("\n"),
                         "Claude 组装:stdin 是 writeThenKeepOpen 且载荷是单行(ndjson 每行一条记录)")
        } else {
            report.check(false,
                         "Claude 组装:stdin 是 writeThenKeepOpen 且载荷是单行(ndjson 每行一条记录)")
        }
    }

    /// stdin 那一行必须是**合法 JSON**,且形状逐字照样本 06 跑通过的那一份。
    private static func testClaudeStdinLine(_ report: inout AgentTestReport) {
        let prompt = "带\"引号\"、反斜杠 \\ 与换行\n的中文 prompt"
        let line = AgentLaunchAssembler.claudeStdinLine(prompt: prompt)

        report.check(!line.contains("\n") && !line.contains("\r"),
                     "Claude stdin:含引号与换行的 prompt 编码后仍是单行(手拼字符串必然在此翻车)")

        guard let data = line.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(root) = decoded else {
            report.check(false, "Claude stdin:那一行是可解析的合法 JSON(解一遍验,不靠肉眼)")
            report.check(false, "Claude stdin:形状是 type=user + message.role=user + message.content 为纯字符串(逐字照样本 06)")
            report.check(false, "Claude stdin:prompt 原文经 JSON 解码后逐字还原(转义正确)")
            return
        }
        report.check(true, "Claude stdin:那一行是可解析的合法 JSON(解一遍验,不靠肉眼)")

        var roleOK = false
        var contentText: String? = nil
        if case let .object(message)? = root["message"] {
            if case let .string(role)? = message["role"] { roleOK = (role == "user") }
            if case let .string(text)? = message["content"] { contentText = text }
        }
        var typeOK = false
        if case let .string(type)? = root["type"] { typeOK = (type == "user") }

        report.check(typeOK && roleOK && contentText != nil,
                     "Claude stdin:形状是 type=user + message.role=user + message.content 为纯字符串(逐字照样本 06)")
        report.check(contentText == prompt,
                     "Claude stdin:prompt 原文经 JSON 解码后逐字还原(转义正确)")
    }

    // MARK: - ② blocked-args 不可覆盖(双层信任模型的地基)

    private static func testBlockedArgumentsCannotBeOverridden(_ report: inout AgentTestReport) {
        // 调用方想把权限档拧成别的档 —— 三种写法都试:空格分隔、等号形态、以及顺手夹带的 skip-permissions。
        let hostile = claudeDelegation(extraArguments: [
            "--permission-mode", "acceptEdits",
            "--permission-mode=plan",
            "--dangerously-skip-permissions",
            "--output-format", "json",
            "--allowedTools", "Task,SendMessage,RemoteTrigger",
            "--bare",
            "--add-dir", "/",                       // 不在 blocked 表里 → 应当原样保留(只堵我们自己拥有的旋钮)
        ])
        let args = AgentLaunchAssembler.assemble(hostile).arguments

        report.check(count(AgentLaunchAssembler.claudePermissionModeFlag, in: args) == 1,
                     "blocked-args:调用方三次试图改权限档,--permission-mode 仍恰好出现一次(重复参数会让 CLI 行为不确定)")
        report.check(value(after: AgentLaunchAssembler.claudePermissionModeFlag, in: args)
                     == AgentLaunchAssembler.claudePermissionModeValue,
                     "blocked-args:权限档仍是 bypassPermissions,调用方覆盖不动(双层信任模型的地基)")
        report.check(!args.contains("acceptEdits") && !args.contains("--permission-mode=plan"),
                     "blocked-args:等号形态 --permission-mode=plan 与裸值 acceptEdits 都被剔干净(堵一半等于没堵)")
        report.check(!args.contains("--dangerously-skip-permissions"),
                     "blocked-args:--dangerously-skip-permissions 被剔除(权限档只留一个来源)")
        report.check(count("--output-format", in: args) == 1 && hasPair("--output-format", "stream-json", in: args),
                     "blocked-args:调用方改不动输出格式(改了归一化层直接失效)")
        report.check(count(AgentLaunchAssembler.claudeAllowedToolsFlag, in: args) == 1
                     && value(after: AgentLaunchAssembler.claudeAllowedToolsFlag, in: args)?.contains("SendMessage") != true,
                     "blocked-args:调用方塞进来的工具白名单(含 Task/SendMessage)被剔除,能力面只能收紧不能放开")
        report.check(!args.contains("--bare"),
                     "blocked-args:--bare 被剔除(它会把订阅 OAuth 认证打不开)")
        report.check(args.contains("--add-dir") && args.contains("/"),
                     "blocked-args:不在 blocked 表里的追加参数原样保留(只堵组装器自己拥有的旋钮,不当保姆)")

        // Codex 侧:`-c sandbox_mode=…` 是把沙箱档拧开的**等价旁路**,不堵它等于没堵 `-s`。
        let hostileCodex = codexDelegation(extraArguments: [
            "-c", "sandbox_mode=danger-full-access",
            "--sandbox", "danger-full-access",
            "-C", "/",
            "--dangerously-bypass-approvals-and-sandbox",
        ])
        let codexArgs = AgentLaunchAssembler.assemble(hostileCodex).arguments
        report.check(count("--sandbox", in: codexArgs) == 1
                     && value(after: "--sandbox", in: codexArgs) == AgentCodexSandbox.readOnly.rawValue,
                     "blocked-args:Codex 沙箱档仍是 read-only,调用方的 --sandbox danger-full-access 被剔除")
        report.check(!codexArgs.contains("-c") && !codexArgs.contains("sandbox_mode=danger-full-access"),
                     "blocked-args:Codex 的 -c sandbox_mode=… 旁路也被堵住(等价旁路不堵等于没堵 -s)")
        report.check(!codexArgs.contains("-C") && !codexArgs.contains("--dangerously-bypass-approvals-and-sandbox"),
                     "blocked-args:Codex 的 -C 换工作根与 --dangerously-bypass-approvals-and-sandbox 都被剔除")
        report.check(AgentLaunchAssembler.blockedArguments(for: .claude)
                        .contains(AgentLaunchAssembler.claudePermissionModeFlag)
                     && AgentLaunchAssembler.blockedArguments(for: .codex).contains("--sandbox"),
                     "blocked-args:两家的 blocked 表各自包含最要害的那一项(权限档 / 沙箱档)")

        // ---- CR 补:clap 的**短旗标贴写形态**(值粘在 token 上,按 `=` 切出来的 name 不在 blocked 表里)----
        // 这一组是「等价旁路不堵等于没堵」这句话对自己的兑现:只堵 `-s x` 与 `-s=x` 而漏掉 `-sx`,
        //   调用方一个 token 就能把沙箱拧到 danger-full-access,而 meta / prompt 快照仍记着 read-only。
        let attached = AgentLaunchAssembler.assemble(codexDelegation(extraArguments: [
            "-sdanger-full-access",                  // 贴写沙箱档
            "-csandbox_mode=danger-full-access",     // 贴写 -c 等价旁路
            "-C/",                                   // 贴写换工作根(我们的 argv 里本没有 -C,不会撞出重复参数报错)
            "-mgpt-nonexistent",                     // 贴写 model
            "--keep-me",                             // 不在 blocked 表里 → 必须原样留下
        ])).arguments
        report.check(!attached.contains(where: { $0.hasPrefix("-s") && $0 != "--sandbox" && $0 != "-s" }),
                     "blocked-args:贴写形态 -sdanger-full-access 被剔除(clap 短旗标可粘值,只堵分开写的等于没堵)")
        report.check(!attached.contains(where: { $0.hasPrefix("-c") && $0 != "-c" }),
                     "blocked-args:贴写形态 -csandbox_mode=… 被剔除(-c 的等价旁路同样有贴写写法)")
        report.check(!attached.contains(where: { $0.hasPrefix("-C") }),
                     "blocked-args:贴写形态 -C/ 被剔除(换工作根 = 让 agent 去别处干活,且不会撞出重复参数)")
        report.check(!attached.contains(where: { $0.hasPrefix("-m") && $0 != "-m" }),
                     "blocked-args:贴写形态 -mgpt-nonexistent 被剔除(model 有类型化字段)")
        report.check(attached.contains("--keep-me"),
                     "blocked-args:贴写形态过滤不误伤非 blocked 参数(前缀匹配只对 blocked 短旗标生效)")
        report.check(hasPair("--sandbox", "read-only", in: attached),
                     "blocked-args:贴写旁路全被剔除后,沙箱档仍是我们写的 read-only")

        // ---- CR 补:`--mcp-config` / `--settings` —— 借我们自己的收紧旗标把能力面重新放开的杠杆 ----
        let mcpArgs = AgentLaunchAssembler.assemble(claudeDelegation(extraArguments: [
            "--mcp-config", "/tmp/evil.json", "--settings", "/tmp/evil-settings.json",
        ])).arguments
        report.check(!mcpArgs.contains("--mcp-config") && !mcpArgs.contains("/tmp/evil.json"),
                     "blocked-args:--mcp-config 被剔除(--strict-mcp-config 的语义正是「只认它传进来的那份」,漏堵等于把钥匙插门上)")
        report.check(!mcpArgs.contains("--settings") && !mcpArgs.contains("/tmp/evil-settings.json"),
                     "blocked-args:--settings 被剔除(它能注入 hooks 等配置面)")
        report.check(mcpArgs.contains(AgentLaunchAssembler.claudeStrictMCPFlag),
                     "blocked-args:剔除杠杆之后我们自己的 --strict-mcp-config 仍在(收紧没被连坐删掉)")
    }

    // MARK: - ③ 能力面收紧(01 spike findings 第 7 条)

    private static func testCapabilitySurfaceIsNarrowed(_ report: inout AgentTestReport) {
        let args = AgentLaunchAssembler.assemble(claudeDelegation()).arguments
        report.check(args.contains(AgentLaunchAssembler.claudeStrictMCPFlag),
                     "能力面:含 --strict-mcp-config(无头子进程默认继承宿主全部 MCP 面,不收紧就是失控)")
        let whitelist = value(after: AgentLaunchAssembler.claudeAllowedToolsFlag, in: args)
        report.check(whitelist != nil && !whitelist!.isEmpty,
                     "能力面:含工具白名单参数且非空(01 spike:样本里 tools 含 Task/SendMessage/RemoteTrigger 等本机项目工具)")
        report.check(whitelist?.contains("Task") != true && whitelist?.contains("SendMessage") != true,
                     "能力面:默认白名单里没有 Task/SendMessage 这类宿主项目工具(被委托 agent 不该能再派子代理)")
        report.check(AgentLaunchAssembler.claudeDefaultAllowedTools.contains("Read")
                     && AgentLaunchAssembler.claudeDefaultAllowedTools.contains("Bash"),
                     "能力面:默认白名单保留 vanilla 内置工具(收紧不等于让 agent 什么都干不了)")

        // 白名单可覆盖为**更窄**的集合(只读诊断任务):这是收紧方向,允许。
        let readOnly = AgentLaunchAssembler.assemble(claudeDelegation(allowedTools: ["Read", "Glob", "Grep"])).arguments
        report.check(value(after: AgentLaunchAssembler.claudeAllowedToolsFlag, in: readOnly) == "Read,Glob,Grep",
                     "能力面:调用方可把白名单收得更窄(只读诊断任务),逐字生效")
    }

    // MARK: - ④ Codex argv(02 spike 8/8 样本形状 + exec --help 落盘的旗标名)

    private static func testCodexArguments(_ report: inout AgentTestReport) {
        let spec = AgentLaunchAssembler.assemble(codexDelegation())
        let args = spec.arguments

        report.check(args.first == "exec",
                     "Codex 组装:首个参数是 exec 子命令(02 spike 8/8 样本的 argv 形状)")
        report.check(args.contains("--json"),
                     "Codex 组装:含 --json(事件流是 JSONL,归一化层消费的就是它)")
        report.check(args.contains("--skip-git-repo-check"),
                     "Codex 组装:含 --skip-git-repo-check(任务工作区不是 git 仓库,不给会拒跑)")
        report.check(hasPair("--sandbox", AgentCodexSandbox.readOnly.rawValue, in: args),
                     "Codex 组装:默认沙箱档是 read-only(显式写出来,不靠 CLI 的默认值)")
        report.check(args.last == "List the files here",
                     "Codex 组装:prompt 是最后一个位置参数(exec [OPTIONS] [PROMPT] 的形状)")
        if case .devNull = spec.stdin {
            report.check(true, "Codex 组装:stdin 是 devNull(不给会静默挂起 —— 02 spike 意外发现 1,最隐蔽的坑)")
        } else {
            report.check(false, "Codex 组装:stdin 是 devNull(不给会静默挂起 —— 02 spike 意外发现 1,最隐蔽的坑)")
        }

        report.check(count("--model", in: args) == 0,
                     "Codex 组装:未指定 model 时绝不出现 --model")
        let withModel = AgentLaunchAssembler.assemble(codexDelegation(model: "gpt-5")).arguments
        report.check(count("--model", in: withModel) == 1 && value(after: "--model", in: withModel) == "gpt-5"
                     && withModel.last == "List the files here",
                     "Codex 组装:指定 model 时 --model 恰出现一次,且 prompt 仍在最后")

        // 放开沙箱必须是调用方**显式**的动作(默认档绝不是它)。
        let wide = AgentLaunchAssembler.assemble(codexDelegation(sandbox: .workspaceWrite)).arguments
        report.check(hasPair("--sandbox", "workspace-write", in: wide),
                     "Codex 组装:调用方显式指定 workspace-write 时如实放开(可写边界锁在 cwd,exec4 实证)")

        // 以 `-` 开头的 prompt 会被 clap 当旗标 —— 此时(且仅此时)补一个 `--` 终止符。
        let dashPrompt = AgentLaunchAssembler.assemble(codexDelegation(prompt: "--help me")).arguments
        report.check(dashPrompt.count >= 2 && dashPrompt[dashPrompt.count - 2] == "--" && dashPrompt.last == "--help me",
                     "Codex 组装:以减号开头的 prompt 前补 -- 终止符(否则会被当成旗标解析)")
        report.check(!AgentLaunchAssembler.assemble(codexDelegation()).arguments.contains("--"),
                     "Codex 组装:正常 prompt 不补 -- (保持 8/8 样本验证过的裸形状)")
    }

    // MARK: - ⑤ 环境白名单 + CODEX_HOME 指向任务私有目录

    private static func testEnvironmentAllowlist(_ report: inout AgentTestReport) {
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
            codexDelegation(codexHome: taskHome, hostEnvironment: hostEnv)
        ).environment

        report.check(env["CODEX_HOME"] == taskHome,
                     "Codex 环境:CODEX_HOME 指向任务私有目录(每任务独立,用完即弃)")
        report.check(env["CODEX_HOME"] != "/Users/fake/.codex",
                     "Codex 环境:宿主继承来的 CODEX_HOME 被我们的值压过(否则任务会去读用户真配置里的 danger-full-access)")
        report.check(env["HOME"] == "/Users/fake" && env["PATH"] == "/usr/bin:/bin",
                     "环境白名单:HOME 与 PATH 如实透传(子进程环境不隐式继承,要什么必须显式写明)")
        report.check(env["ANTHROPIC_API_KEY"] == nil && env["OPENAI_API_KEY"] == nil,
                     "环境白名单:凭据类变量不带进子进程(本机是订阅 OAuth,带 API key 会静默改变计费主体)")
        report.check(env["AA_SECRET_INTERNAL"] == nil,
                     "环境白名单:白名单之外的宿主变量一律不透传(白名单漏一个只是少个变量,黑名单漏一个就是泄密)")

        // Claude 侧不该长出 CODEX_HOME(哪怕委托里带了)。
        let claudeEnv = AgentLaunchAssembler.assemble(
            AgentDelegation(vendor: .claude, prompt: "hi", workingDirectory: workdir,
                            executablePath: claudePath, codexHome: taskHome, hostEnvironment: hostEnv)
        ).environment
        report.check(claudeEnv["CODEX_HOME"] == nil,
                     "环境白名单:Claude 侧不注入 CODEX_HOME(它是 Codex 专用,别互相污染)")
    }

    // MARK: - ⑥ CODEX_HOME 隔离:只拷 auth.json,对源目录零写入

    private static func testCodexHomeIsolation(_ report: inout AgentTestReport) {
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

        /// 源目录里全部路径的写入次数之和(造数据那几次也算在内)——`prepare` 前后取两次比对,
        /// 差值必须是 **0**。直接断言「等于某个具体数字」会把测试自己的造数据次数写死进断言,脆而无意义。
        func sourceWriteTally() -> Int {
            let paths = [source + "/auth.json", source + "/config.toml", source + "/sessions/s1.jsonl"]
            return paths.reduce(0) { $0 + fs.writeCount(at: $1) + fs.appendCount(at: $1) }
        }
        let writesBeforePrepare = sourceWriteTally()

        do {
            try AgentCodexHome.prepare(from: source, to: destination, fs: fs)
            report.check(true, "CODEX_HOME 隔离:prepare 正常完成(建目录 + 拷 auth.json)")
        } catch {
            report.check(false, "CODEX_HOME 隔离:prepare 正常完成(建目录 + 拷 auth.json)")
        }

        let inDestination = fs.allFilePaths().filter { $0.hasPrefix(destination + "/") }
        report.check(inDestination == [destination + "/auth.json"],
                     "CODEX_HOME 隔离:任务私有目录里**只有** auth.json 一个文件(别的一个字节都没拷)")
        report.check(!fs.exists(at: destination + "/config.toml"),
                     "CODEX_HOME 隔离:绝不拷 config.toml(用户真配置里是 danger-full-access,拷过去等于把沙箱关掉)")
        report.check(fs.contents(at: destination + "/auth.json") == #"{"tokens":{"access_token":"secret"}}"#,
                     "CODEX_HOME 隔离:auth.json 内容逐字拷贝(鉴权只认这一个文件,02 spike 8/8 实证)")
        // 副本走的必须是**凭据通道**(契约 0600),不能是普通 write —— 普通 write 在默认 umask 下落成 0644,
        // 等于把一份人人可读的 OAuth token 拷贝留在会被 tar 走 / 被同步 / 被误分享的任务目录里。
        report.check(fs.wasWrittenPrivately(at: destination + "/auth.json"),
                     "CODEX_HOME 隔离:auth.json 走的是凭据通道 writePrivate(0600),不是普通 write(0644 的 token 拷贝)")

        // **对源目录零写入**——这是「绝不碰用户真 ~/.codex」的可验证形式(逐路径查写入次数,前后差值必须为 0)。
        report.check(sourceWriteTally() == writesBeforePrepare,
                     "CODEX_HOME 隔离:prepare 全过程对源目录零写入(源目录只读,用户真 ~/.codex 一个字节不动)")
        report.check(fs.contents(at: source + "/config.toml") == "sandbox_mode = \"danger-full-access\"\n"
                     && fs.exists(at: source + "/sessions/s1.jsonl"),
                     "CODEX_HOME 隔离:源目录的 config.toml 与 sessions 原样健在(既不改也不删)")
    }

    private static func testCodexHomeGuardsAndDiscard(_ report: inout AgentTestReport) {
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
        report.check(refused,
                     "CODEX_HOME 守卫:目标目录与源目录相同时拒绝执行(放行的话 discard 会把用户真目录整个删掉)")
        report.check(fs.exists(at: source + "/config.toml"),
                     "CODEX_HOME 守卫:被拒绝那次没有对源目录产生任何副作用")

        // 源里没有 auth.json:抛 authFileMissing,但目标目录**已经建好且为空** ——
        // 调用方可据此选择「照常跑,让它 401 fail-closed」(02 spike 实证的安全档)。
        let emptySource = "/fake/home/.codex-empty"
        let destination = "/fake/tasks/t2/codex-home"
        try? fs.createDirectory(at: emptySource)
        try? fs.createDirectory(at: "/fake/tasks/t2")
        var missing = false
        do { try AgentCodexHome.prepare(from: emptySource, to: destination, fs: fs) }
        catch AgentCodexHomeError.authFileMissing { missing = true }
        catch { missing = false }
        report.check(missing,
                     "CODEX_HOME 守卫:源里没有 auth.json 时如实抛错(不静默给一个没鉴权的目录让人猜)")
        report.check(fs.exists(at: destination) && fs.allFilePaths().filter { $0.hasPrefix(destination + "/") }.isEmpty,
                     "CODEX_HOME 守卫:抛 authFileMissing 时目标目录已建好且为空(调用方可选择让它 401 fail-closed)")

        // discard:删干净 + 幂等。
        try? AgentCodexHome.prepare(from: source, to: "/fake/tasks/t3/codex-home", fs: fs)
        try? fs.createDirectory(at: "/fake/tasks/t3/codex-home/sessions")   // 模拟 codex 运行时自己长出来的状态
        try? fs.write("{}", to: "/fake/tasks/t3/codex-home/sessions/s.jsonl")
        var discarded = false
        do { try AgentCodexHome.discard("/fake/tasks/t3/codex-home", fs: fs); discarded = true } catch { discarded = false }
        report.check(discarded && !fs.exists(at: "/fake/tasks/t3/codex-home")
                     && !fs.exists(at: "/fake/tasks/t3/codex-home/sessions/s.jsonl"),
                     "CODEX_HOME 清理:discard 把任务私有目录连同运行时长出来的状态一并删净(用后即弃)")
        var again = false
        do { try AgentCodexHome.discard("/fake/tasks/t3/codex-home", fs: fs); again = true } catch { again = false }
        report.check(again,
                     "CODEX_HOME 清理:discard 幂等(收尾有多条出口,为已删过一次抛错只会逼出一堆 try?)")
        var emptyRefused = false
        do { try AgentCodexHome.discard("", fs: fs) } catch AgentCodexHomeError.emptyDestination { emptyRefused = true } catch {}
        report.check(emptyRefused,
                     "CODEX_HOME 清理:空路径一律拒绝(空串拼出来的路径会指向意想不到的地方)")
    }
}
