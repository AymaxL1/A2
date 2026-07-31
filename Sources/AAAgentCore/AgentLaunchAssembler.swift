// AAAgentCore —— 两家 agent 的**启动参数组装**(纯函数,零副作用,可逐条断言)。
// 依赖边:本文件 → Foundation(只为 JSONEncoder 拼那一行 stdin JSON);绝不 import 任何 Host* / SDK / PluginProxy。
//
// **为什么组装放在这里而不是 CLI 里**(07 票的关键设计判断):
//   参数组装是整条委托链上最容易悄悄错、错了后果最重的一段 ——「少了 `--permission-mode bypassPermissions`」
//   看起来只是少一个旗标,实际是 agent 什么都干不成(01 spike:CLI **同步自动拒绝**每一次工具调用);
//   「多了一个调用方塞进来的 `--permission-mode`」则是双层信任模型的地基被人从下面抽掉。
//   放进 CLI 就只能靠真拉起进程才验得了,而真拉起既烧用户配额、又在 bypass 下对文件系统无隔离(01 spike 第 7 题),
//   门禁里根本不能做。放进纯函数则整份 `AgentLaunchSpec` 可以在**不拉任何进程**的前提下逐条断言。
//
// ============ 实证依据(每一个旗标都能指到具体样本,不是照文档抄的)============
// Claude 侧(01 spike `spike-claude-headless/`,8 次真调,run.sh 与 *.meta.txt 里逐条留着当时的命令行):
//   * `-p` + `--output-format stream-json` + `--verbose`:**8 次全部这么跑的**。`--verbose` 不是可选装饰 ——
//     成功样本(01/02/07)的命令行里它一直在,去掉它是在拿一条从未被验证过的调用形状去跑真钱任务。
//   * `--input-format stream-json`:样本 06 实证 prompt 走 stdin 一行 JSON(见 `claudeStdinLine`);
//     且**写完不发 EOF 进程不会自退**(两次独立复现)→ stdin 处置必须是 `.writeThenKeepOpen`,收尾由适配层显式管。
//   * `--permission-mode bypassPermissions`:样本 02/03 对照实证。不加**不是**「挂起等审批」,而是 CLI
//     合成 `is_error:true` 的 tool_result **同步自动拒绝**,且默认档拒绝无差别(cwd 内的写也拒)——
//     没有「仅放行 cwd 内」的中间档。故这是「让被委托 agent 能干活」的开关,必须给,且**必须进 blocked-args**。
//   * `--model`:样本 05 实证透传生效(传了不存在的 model 名会 exit 1)。仅当非 nil 才出现。
//   * **不用 `--bare`**:findings 踩坑备忘明写它把认证限定为 `ANTHROPIC_API_KEY`/`apiKeyHelper`,
//     本机是订阅 OAuth,加了直接打不开认证。
// Codex 侧(02 spike `spike-codex-exec/`,8 次真调 + `samples/02-exec-help.txt` 是**真 `codex exec --help` 落盘**):
//   * `exec --json --skip-git-repo-check <prompt>`:8/8 样本的 argv 形状(见 `exec1-*.meta.json` 的 `cmd`)。
//   * stdin **必须** `.devNull`:findings 意外发现 1 —— exec 无条件尝试读 stdin,给一个「开着没人写也不关」的
//     管道会**静默挂起**(表现为「进程卡住不产任何 JSON 事件」,不报错),这是无头驱动最隐蔽的坑。
//   * `-s/--sandbox <mode>`:exec-help 落盘的三档 `read-only|workspace-write|danger-full-access`;
//     默认给**只读**档(findings §2:裸 CODEX_HOME + 不传 flag 时等效 read-only,我们显式写出来而不是靠默认)。
//   * `CODEX_HOME`:每任务独立目录(见 `AgentCodexHome`),findings §0 实证隔离可行且 fail-closed(无 auth → 401,
//     绝不静默回退到用户真身份)。
//   * 刻意**不加** `--ignore-user-config`:findings §2 把它记作「隔离目录可能被复用时的第二道保险」,
//     但**本次未做样本验证**;而我们的 CODEX_HOME 是每任务全新目录、压根没有 config.toml,它防的风险不存在。
//     宁可守住 8/8 验证过的 argv 形状,也不为一个用不上的旗标引入未验证行为。
//
// ============ 两处**未经本机二进制验证**的旗标(如实标注,不假装都验过)============
//   `--strict-mcp-config` 与 `--allowedTools` 是 01 spike findings「对适配层的直接影响」第 7 条要求的能力面收紧
//   (无头子进程默认继承宿主机全部插件/技能/自定义 agent 面:样本里 `tools` 含 `Task`/`SendMessage`/
//   `RemoteTrigger`/`CronCreate` 等本机项目工具,**不是 vanilla claude**),但那 8 次样本**没有一次**带过这两个旗标,
//   findings 里写的还是笼统的「`--tools`」。故:
//   * 拼写以 Claude Code CLI 参考手册为准(`--strict-mcp-config` / `--allowedTools`),
//   * 万一拼错,后果是 claude 立刻以用法错退出 —— **fail-fast 且可见**,不会静默地把能力面放开(方向是安全的那一侧),
//   * 拼写的真值化归 `Scripts/agent-smoke.sh` 的第 0 步(`claude --help` grep 这两个旗标),那是**手动、有人在场**才跑的。
//   * **但拼写对不等于收紧真生效(CR 记的一笔,别自我安慰)**:`--allowedTools` 的语义是「免询问放行清单」,
//     而我们同时给了 `--permission-mode bypassPermissions`(本来就全放行)——两者叠加时它很可能
//     **一个工具都没挡掉**,被委托 agent 照样能用 `Task` / `SendMessage` 派子代理。
//     门禁断言组 1i 的「能力面只能收紧不能放开」断的是 **argv 组得对**,不是**现实里真被挡住**。
//     真值化的做法与后手(改用 `--disallowedTools` 硬拒名单)写在 `Scripts/agent-smoke.sh` 末尾的
//     ready-for-human 清单里,需人在场跑一次才能结论化。

import Foundation

/// Codex 的沙箱档位(取值逐字照 `codex exec --help` 落盘的 `[possible values]`,不自造别名)。
public enum AgentCodexSandbox: String, Sendable, Equatable, CaseIterable {
    /// 只读(默认档)。02 spike:裸 CODEX_HOME 不传任何 sandbox flag 时等效于此档。
    case readOnly = "read-only"
    /// 可写工作区(边界严格锁定在 cwd;exec4 实证越界写被静默拦下,磁盘上确实没落地)。
    case workspaceWrite = "workspace-write"
    /// 完全放开。**只有调用方显式指定才会出现**,组装器绝不默认给。
    case dangerFullAccess = "danger-full-access"
}

/// 一次委托的输入(用户 / 插件给什么,组装器就吃什么;它自己不去读环境、不去猜路径)。
///
/// 刻意做成一个值类型而不是一串参数:组装是纯函数,输入是值、输出是值,门禁才能整份构造出来逐条断言。
public struct AgentDelegation: Sendable, Equatable {
    /// 被委托的 agent 家族。
    public let vendor: AgentVendor
    /// 委托原文(Claude 走 stdin 一行 JSON;Codex 走位置参数)。
    public let prompt: String
    /// 模型名;nil = 用 agent 自己的默认(此时**绝不**出现 `--model`)。
    public let model: String?
    /// agent 的工作目录(任务工作区的 `work/` 或委托指定的外部目录)。
    public let workingDirectory: String
    /// agent 可执行的绝对路径。
    public let executablePath: String
    /// Codex 专用:每任务独立的 `$CODEX_HOME`(见 `AgentCodexHome`)。Claude 侧恒忽略(传 nil)。
    ///
    /// **这个参数刻意没有默认值(CR 修正)**:它原本写作 `= nil`,于是「调用方漏传」是一次能编译通过的失误 ——
    ///   而漏传的后果不是少个变量,是 `environment(for:)` 静默不注 `CODEX_HOME`,子进程回落到用户**真实**的
    ///   `~/.codex`(白名单已把继承值滤掉,但 codex 自己有默认路径)。按 02 spike 意外发现 3,那个目录「用后即脏」——
    ///   一次委托就会往用户真配置目录里长 `sessions/` / `cache/` / sqlite,而那正是 `AgentCodexHome`
    ///   整个文件存在的理由要防的事。没有默认值 → 漏传变成**编译错误**,比任何运行时诊断都早、都硬。
    public let codexHome: String?
    /// Codex 专用:沙箱档位。默认只读 —— **要放开必须由调用方显式指定**。
    public let sandbox: AgentCodexSandbox
    /// Claude 专用:工具白名单;nil = 用 `AgentLaunchAssembler.claudeDefaultAllowedTools`。
    public let allowedTools: [String]?
    /// 宿主环境快照(生产侧传 `ProcessInfo.processInfo.environment`)。
    ///
    /// **为什么要显式传进来**:`SystemAgentPort.launch` 的环境**如实取自 spec、不隐式继承宿主环境**
    ///   (见其 ④ 段注释)。故「子进程能看到哪些环境变量」是 07 票必须显式作答的设计题,
    ///   而不是「反正会继承」。答案见 `inheritedEnvironmentKeys`:白名单透传。
    public let hostEnvironment: [String: String]
    /// 调用方追加的参数。**会先过 `blockedArguments` 的筛子**(见 `stripBlockedArguments`)。
    public let extraArguments: [String]

    public init(
        vendor: AgentVendor,
        prompt: String,
        model: String? = nil,
        workingDirectory: String,
        executablePath: String,
        codexHome: String?,                 // 刻意无默认值:漏传要在编译期就红(理由见字段文档)
        sandbox: AgentCodexSandbox = .readOnly,
        allowedTools: [String]? = nil,
        hostEnvironment: [String: String] = [:],
        extraArguments: [String] = []
    ) {
        self.vendor = vendor
        self.prompt = prompt
        self.model = model
        self.workingDirectory = workingDirectory
        self.executablePath = executablePath
        self.codexHome = codexHome
        self.sandbox = sandbox
        self.allowedTools = allowedTools
        self.hostEnvironment = hostEnvironment
        self.extraArguments = extraArguments
    }
}

/// 启动参数组装(全部是纯函数:同一份委托组出来的 `AgentLaunchSpec` 逐字节确定)。
public enum AgentLaunchAssembler {

    // MARK: - 常量(旗标字面量只在这里出现一次,别处一律引用)

    /// Claude:权限档旗标与它**唯一**被允许的取值。
    public static let claudePermissionModeFlag = "--permission-mode"
    public static let claudePermissionModeValue = "bypassPermissions"
    /// Claude:能力面收紧的两个旗标(依据与未验证风险见文件头)。
    public static let claudeStrictMCPFlag = "--strict-mcp-config"
    public static let claudeAllowedToolsFlag = "--allowedTools"
    /// Claude:默认工具白名单 —— 只留 vanilla 内置工具,把宿主机继承来的插件 / 技能 / 自定义 agent 面挡在外面。
    ///
    /// 01 spike 实证被委托的无头子进程默认能看到 `Task` / `SendMessage` / `RemoteTrigger` / `CronCreate`
    /// 这类**本机项目工具**——不收紧就等于把宿主的全部能力交给被委托 agent(它能再派子代理、能触发定时任务)。
    public static let claudeDefaultAllowedTools = ["Read", "Glob", "Grep", "Bash", "Write", "Edit"]

    /// 宿主环境的**透传白名单**(其余一律不带进子进程)。
    ///
    /// 为什么是白名单而不是黑名单:黑名单要穷举「不该漏的」,漏一个就是把凭据 / 代理配置 / 内部地址
    ///   顺手交给一个被委托的 agent;白名单漏一个只是子进程少一个变量,失败可见且可补。
    /// 逐条理由:
    /// - `HOME`:两家都要(Claude 的 OAuth 凭据在 `~/.claude`;Codex 的 auth 虽走 `$CODEX_HOME`,但 shell 要 HOME);
    /// - `PATH`:agent 跑 shell 工具要用(Codex 用绝对路径 `/bin/zsh -lc` 拉 shell,但 shell 里的命令仍靠 PATH);
    /// - `USER` / `LOGNAME` / `SHELL` / `TMPDIR` / `TZ`:登录 shell 与临时文件的基本面,缺了会有莫名其妙的失败;
    /// - `LANG` / `LC_ALL`:不给会让某些工具按 C locale 处理 UTF-8,中文 prompt 的输出会花;
    /// - `TERM`:不给时部分 CLI 会假设 dumb 终端(输出更干净,反而是我们要的),给了也无害,故保留;
    /// - `SSL_CERT_FILE` / `NODE_EXTRA_CA_CERTS`:企业 MITM 证书环境下不带就连不上 API。
    ///
    /// **刻意不在白名单里的**:`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` 等凭据类变量。
    ///   本机是订阅 OAuth(01 spike findings 踩坑备忘),把 API key 带进去会**静默改变计费主体**;
    ///   要用 key 计费应当是一次显式的产品决定,不该由「宿主碰巧 export 过」来决定。
    public static let inheritedEnvironmentKeys: Set<String> = [
        "HOME", "PATH", "USER", "LOGNAME", "SHELL", "TMPDIR", "TZ",
        "LANG", "LC_ALL", "TERM", "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS",
    ]

    // MARK: - blocked args(双层信任模型的地基)

    /// **不可被调用方覆盖的参数**(样板 = multica 的 blocked-args 设计)。
    ///
    /// 判据只有一条:**凡是组装器自己拥有的旋钮,调用方都不得从 `extraArguments` 里再拧一次**。
    ///   不是因为「怕别人乱传」,而是因为同名参数出现两次会让 CLI 的行为变得**不确定**
    ///   (谁赢取决于该 CLI 的解析实现,而那不是我们能担保的);更别说 `--permission-mode` 这种
    ///   被拧一下就把整个双层信任模型抽掉的。
    ///
    /// 逐个理由:
    /// - Claude:`--permission-mode` / `--dangerously-skip-permissions`(权限档只有一个来源);
    ///   `--output-format` / `--input-format` / `--verbose`(改了流的形状 = 归一化层直接失效);
    ///   `--strict-mcp-config` / `--allowedTools` / `--disallowedTools`(能力面收紧不许被放开);
    ///   **`--mcp-config` / `--settings`(CR 补:这两个是「借我们自己的收紧旗标把能力面重新放开」的杠杆 ——
    ///     `--strict-mcp-config` 的语义正是「只认经 `--mcp-config` 传入的那份配置」,于是调用方塞一个
    ///     `--mcp-config evil.json` 反而等于借我们的手接进任意 MCP 面;`--settings` 同理可注入 hooks 等配置面。
    ///     堵住 `--strict-mcp-config` 却漏掉它俩,等于把锁装好了再把钥匙插在门上)**;
    ///   `--model`(有类型化字段);`-p` / `--print`(单发形态);`--bare`(会打不开订阅 OAuth 认证)。
    /// - Codex:`exec` / `--json` / `--skip-git-repo-check`(argv 形状);`-s` / `--sandbox` / `-c` / `--config`
    ///   (沙箱档只有一个来源 —— `-c sandbox_mode=…` 是等价旁路,不堵它等于没堵);
    ///   `-C` / `--cd`(工作根目录由 spec 定,被它悄悄换掉 = agent 在别处干活);
    ///   `-m` / `--model`(有类型化字段);`--dangerously-bypass-approvals-and-sandbox`(名字已经说明一切)。
    public static func blockedArguments(for vendor: AgentVendor) -> [String] {
        switch vendor {
        case .claude:
            return [
                "-p", "--print",
                "--output-format", "--input-format", "--verbose",
                claudePermissionModeFlag, "--dangerously-skip-permissions",
                claudeStrictMCPFlag, claudeAllowedToolsFlag, "--disallowedTools",
                "--mcp-config", "--settings",
                "--model",
                "--bare",
            ]
        case .codex:
            return [
                "exec", "--json", "--skip-git-repo-check",
                "-s", "--sandbox", "-c", "--config",
                "-C", "--cd",
                "-m", "--model",
                "--dangerously-bypass-approvals-and-sandbox",
            ]
        }
    }

    /// 从调用方追加的参数里**剔除**全部 blocked args(连同它们的值)。
    ///
    /// 两种写法都要认(否则堵住 `--permission-mode x` 却漏掉 `--permission-mode=x` 等于没堵):
    /// - `--flag=value`:整个 token 丢掉;
    /// - `--flag value`:丢掉 flag,**并且**在下一个 token 不像旗标(不以 `-` 开头)时把它一并丢掉 ——
    ///   否则被剥掉旗标的那个裸值会漂成一个位置参数(Codex 侧就是第二个 prompt,Claude 侧是一个未知参数)。
    ///
    /// 第三种写法也要认(**CR 补的等价旁路**):clap(codex 的 CLI 框架)对带值短旗标接受**贴写形态** ——
    ///   `-sdanger-full-access` / `-csandbox_mode=danger-full-access` / `-C/` / `-mgpt-x`。
    ///   按 `=` 切出来的 name 是 `-sdanger-full-access` / `-csandbox_mode`,**不在** blocked 表里,
    ///   不特判就整条穿过去。上面那句「等价旁路不堵等于没堵」对这一形态同样成立,故按**前缀**再筛一遍。
    ///   贴写形态的值就在 token 自己身上,故只丢这一个 token、**绝不**再吞下一个。
    ///
    /// 已知边界(如实记下):`--flag` 后面若跟的是一个**以 `-` 开头的合法值**(如 `--model -weird`),
    ///   这里会把值留下来。这属于取舍的保守侧 —— 宁可留下一个会让 CLI 报用法错的孤儿 token(失败可见),
    ///   也不误吞掉调用方的下一个旗标。
    public static func stripBlockedArguments(_ args: [String], for vendor: AgentVendor) -> [String] {
        let blockedList = blockedArguments(for: vendor)
        let blocked = Set(blockedList)
        // 只有**单横杠双字符**的短旗标才有贴写形态(`--flag` 的贴写形态就是 `--flag=value`,上面已覆盖)。
        let shortFlags = blockedList.filter { $0.count == 2 && $0.hasPrefix("-") && !$0.hasPrefix("--") }
        var out: [String] = []
        var i = 0
        while i < args.count {
            let token = args[i]
            let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token
            if blocked.contains(name) {
                i += 1
                // `--flag value` 形态:把它的值一并丢掉(`--flag=value` 已经整个丢掉,不进这一支)。
                if !token.contains("="), i < args.count, !args[i].hasPrefix("-") { i += 1 }
                continue
            }
            // 贴写形态:值粘在 token 上,整个 token 丢掉,**不动下一个 token**。
            if shortFlags.contains(where: { token.hasPrefix($0) && token != $0 }) {
                i += 1
                continue
            }
            out.append(token)
            i += 1
        }
        return out
    }

    // MARK: - 组装

    /// 把一次委托组装成启动规格(纯函数、无副作用、可逐条断言)。
    public static func assemble(_ delegation: AgentDelegation) -> AgentLaunchSpec {
        switch delegation.vendor {
        case .claude: return assembleClaude(delegation)
        case .codex:  return assembleCodex(delegation)
        }
    }

    /// Claude:`-p` 单发 + stream-json 双向 + bypass 权限档 + 能力面收紧;prompt 走 stdin 一行 JSON。
    private static func assembleClaude(_ d: AgentDelegation) -> AgentLaunchSpec {
        var args: [String] = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",                                        // 8/8 样本都带;不是可选装饰
            claudePermissionModeFlag, claudePermissionModeValue, // 不给 = agent 什么都干不成(同步自动拒绝)
            claudeStrictMCPFlag,                                 // 不给 = 继承宿主全部 MCP 面
        ]
        let tools = d.allowedTools ?? claudeDefaultAllowedTools
        // 白名单用逗号连成一个 token:该旗标同时接受空格分隔与逗号分隔,逗号在 argv 里不需要再引一层,更不易出错。
        args += [claudeAllowedToolsFlag, tools.joined(separator: ",")]
        if let model = d.model { args += ["--model", model] }
        args += stripBlockedArguments(d.extraArguments, for: .claude)

        return AgentLaunchSpec(
            executablePath: d.executablePath,
            arguments: args,
            environment: environment(for: d),
            workingDirectory: d.workingDirectory,
            // 写一行 prompt 后**保持 stdin 打开**:01 spike 两次独立复现「不发 EOF 进程不自退」,
            // 收尾由适配层显式 closeStdin / terminate 管(见 SystemAgentPort.closeStdin)。
            stdin: .writeThenKeepOpen(claudeStdinLine(prompt: d.prompt))
        )
    }

    /// Codex:`exec --json` + 显式沙箱档 + 每任务独立 CODEX_HOME;prompt 走**位置参数**,stdin 接 /dev/null。
    private static func assembleCodex(_ d: AgentDelegation) -> AgentLaunchSpec {
        var args: [String] = ["exec", "--json", "--skip-git-repo-check"]
        args += ["--sandbox", d.sandbox.rawValue]               // 默认只读;放开由调用方显式指定
        if let model = d.model { args += ["--model", model] }
        args += stripBlockedArguments(d.extraArguments, for: .codex)
        // prompt 必须是**最后一个**位置参数。以 `-` 开头的 prompt 会被 clap 当成旗标,
        // 故此时(且仅此时)先塞一个 `--` 终止符 —— 正常 prompt 保持 8/8 样本验证过的裸形状。
        if d.prompt.hasPrefix("-") { args.append("--") }
        args.append(d.prompt)

        return AgentLaunchSpec(
            executablePath: d.executablePath,
            arguments: args,
            environment: environment(for: d),
            workingDirectory: d.workingDirectory,
            // 不给 stdin 会**静默挂起**(02 spike 意外发现 1)——这是强制项,不是可选优化。
            stdin: .devNull
        )
    }

    /// 子进程环境:宿主环境按白名单过一遍,再叠加本次委托自己的变量。
    ///
    /// 次序是承重的:**我们自己的 `CODEX_HOME` 最后写,压过任何继承来的同名值** ——
    ///   宿主若碰巧 export 过 `CODEX_HOME`,继承进去就等于让被委托任务去读用户的真配置
    ///   (那里面躺着 `sandbox_mode = "danger-full-access"`)。这一条有断言钉死。
    static func environment(for d: AgentDelegation) -> [String: String] {
        var env = d.hostEnvironment.filter { inheritedEnvironmentKeys.contains($0.key) }
        if d.vendor == .codex, let home = d.codexHome, !home.isEmpty {
            env["CODEX_HOME"] = home
        }
        return env
    }

    // MARK: - Claude 的 stdin 一行 JSON

    /// stream-json 输入模式下 prompt 的那一行 JSON。
    ///
    /// 形状**逐字照 01 spike 样本 06 实测跑通的那一行**(见 `06-stdin-keepopen.meta.txt`):
    ///   `{"type":"user","message":{"role":"user","content":"<prompt>"}}`
    /// —— `content` 是**纯字符串**,不是内容块数组。这里不自由发挥:样本证明这个形状能跑出正常 `result`,
    ///   换成别的形状就是拿一份没验过的协议去烧真钱。
    ///
    /// 用 JSONEncoder 而不是手拼:prompt 里的引号 / 反斜杠 / 换行 / 中文都要正确转义,手拼迟早出事。
    /// 输出**保证是单行**(JSONEncoder 不 prettyPrinted 时不产换行);编码理论上不会失败,
    ///   真失败时退回一个语法合法的最小载荷,绝不交回半截 JSON(那会让 CLI 读到坏行)。
    public static func claudeStdinLine(prompt: String) -> String {
        struct Message: Encodable { let role: String; let content: String }
        struct Envelope: Encodable { let type: String; let message: Message }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let envelope = Envelope(type: "user", message: Message(role: "user", content: prompt))
        guard let data = try? encoder.encode(envelope), let line = String(data: data, encoding: .utf8) else {
            return #"{"message":{"content":"","role":"user"},"type":"user"}"#
        }
        return line
    }
}
