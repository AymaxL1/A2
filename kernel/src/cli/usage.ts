// 帮助文本与用法错 —— CLI 的"可发现性"面。
//
// 用法错也照「拒绝即指引」办:错误报文里带的是**能直接敲的下一条命令**,而不是一句"请查看帮助"。

import { ExitCode } from "../contract/exit-codes.ts";
import { ErrorCode, failureResponse, successResponse } from "../contract/wire.ts";
// 帮助文本里的默认端口从常量插值 —— 帮助与实现是同一个数,改常量不会留下一句过时的散文。
import { A2_MIHOMO_CONTROLLER_PORT } from "../mihomo/paths.ts";
// 随包静态文本的文件名同理:帮助里写的名字与安装脚本/组装脚本落的是同一个常量。
import { GPL_LICENSE_FILE_NAME, NOTICE_FILE_NAME } from "../runtime/about.ts";
import { KERNEL_VERSION } from "../runtime/version.ts";
import { renderWireError, type CommandOutcome } from "./outcome.ts";

export const USAGE = `a2 ${KERNEL_VERSION} —— agent-first 的本机代理内核

用法:
  a2 [--json] <子命令> [参数]

子命令:
  status               查询 daemon 运行态(经 UDS 往返)
  capabilities …       能力面:list / describe <id> / call <id>(见 a2 capabilities --help)
  proxy …              代理控制面:on / off / status / mode / node / groups / ping / config /
                       subscription … / supervision(见 a2 proxy --help)
  arbitration status   dangerous 三层仲裁面:确认器在不在场、在途确认、审计事件(见 a2 arbitration --help)
  service …            常驻服务:install / uninstall / status(见 a2 service --help)
  mihomo …             mihomo 共存:status / install / uninstall / upgrade(见 a2 mihomo --help)
  plugin …             插件装载:add <路径> / list / remove <名字>(见 a2 plugin --help)
  daemon run           前台起常驻内核(调试用;开机自启请用 service 安装)
  about                版本、许可与外部程序声明(GPL 义务落点;不经 daemon)
  help                 打印本帮助
  version              打印版本

全局参数:
  --json               机读输出:stdout 上只有一条 JSON 包封(成功与失败同一形状)
  -h, --help           同 help
  -V, --version        同 version

环境变量:
  A2_HOME              覆写 ~/.a2(socket 落 <A2_HOME>/run/kernel.sock)

退出码:0 成功 / 1 用法错 / 2 denied / 3 超时 / 4 daemon 不可达 / 5 能力业务失败 / 6 协议·校验错`;

export const CAPABILITIES_USAGE = `a2 capabilities —— 能力面(内核的唯一调用面)

用法:
  a2 [--json] capabilities list
  a2 [--json] capabilities describe <id>
  a2 [--json] capabilities call <id> [--input '<JSON 对象>']

参数:
  --input <JSON>       调用入参,必须是一个 JSON 对象(按参数名取值);不带等价于 {}

风险三档:
  safe                 只读,直通
  normal               可逆写,直通(零确认打断)
  dangerous            需真人在场证明;无确认器在场时结构化默拒(confirmation_unavailable,退出码 2),
                       拒绝报文自带「人类如何完成」的精确命令。永不交互阻塞,无 --yes 旁路。

退出码:0 成功 / 2 dangerous 被拒 / 4 daemon 不可达 / 5 能力业务失败 / 6 能力或参数不合契约 / 1 用法错`;

export const SERVICE_USAGE = `a2 service —— 常驻服务的显式安装(系统托管,应用层不造看门狗)

用法:
  a2 [--json] service install [--copy-to-home]   装成系统托管的常驻服务并确保它跑着(幂等)
  a2 [--json] service uninstall [--purge]        停掉并干净移除(幂等);--purge 连数据一起清
  a2 [--json] service status                     查安装态与运行态(只读)

除 --copy-to-home / --purge 外不接受任何参数:unit 名恒为 com.a2.kernel 与 com.a2.mihomo,
内核只碰这两个 —— 你自己装的 mihomo(io.metacubex.mihomo 等)在任何路径下都不在射程内。
三条命令都可 --json(与走 daemon 的命令同一形状的包封)—— 面板的引导路径走的就是这条机读面。

--copy-to-home(面板自足,ADR 0012):
  先把**本 bin 自己**原子拷进 $A2_HOME/bin/a2(0755),再让 unit 指向那份拷贝 ——
  于是 .app 挪位/删除、macOS translocation 都不会让常驻服务指向一个不存在的路径。
  幂等按**内容**判:同一份 bin 复跑不报 bin_copied;内容变了而服务正跑着,则显式重启(升级永远显式)。
  **重启会掐断所有在途长连接**:已注册角色随连接消失,在途 dangerous 确认按「断线即默拒」收尾
  (08 票语义,不因升级而例外);面板/订阅者断后自行重连,重连即拿到新内核的全量快照。
  只有编译产物能这么装:源码态跑的 a2 没有可分发的"自身",会结构化拒绝(service_self_copy_unsupported)。
  卸载**不删**这份拷贝:它在数据同侧,清理是另一个显式动作 —— 就是下面这个 --purge。

--purge(卸载补全,17 票 / ADR 0012 第 6 条修订):
  在"拆内核 unit"之后**继续往下清**,顺序固定、每一步都可从 --json 里核对:
    ① 拆 com.a2.kernel(与不带旗标时逐字相同)
    ② 拆 com.a2.mihomo —— **a2 自管的那份** mihomo 服务;它不在则整条跳过、不报 action
    ③ 删掉整个 $A2_HOME(内核拷贝、订阅、插件、日志、a2 自己下的 mihomo 二进制与数据)
  机读面给的是**先看后删的账**:result.purge.removedUnits(label)与 result.purge.removedPaths(绝对路径)。
  **红线**:范围恒是 com.a2.* 与 $A2_HOME。你自己装的 mihomo、它的配置与数据,任何路径下都不动。
  动手之前有四道门,任何一道不过都**当场拒绝、一个字节都不删**:
    · 目标形状不成立(service_purge_unsafe_home,6):$A2_HOME 是 /、是家目录本身、是家目录的上级,
      或者**是一根符号链接** —— 符号链接上的 rm -rf 只删链不删树,报"删干净了"是假账。
    · 站错了 home(service_purge_home_mismatch,1):盘上那份 unit 记着的是**另一个** A2_HOME。
      label 每用户一个而 A2_HOME 每次调用一个,站错地方就会拆掉别的 home 的数据面。
    · **系统代理仍处接管态**(service_purge_blocked,1):接管快照 $A2_HOME/system-proxy.json 是
      还原的唯一依据,连它一起删就再也还原不回去了。先 a2 proxy off(或面板的「关闭系统代理(还原)」)
      再来 —— 还原永远是显式命令,卸载不替你做。
    · 两个 unit 里任何一个"卸下了但进程还在",也停在那一步(service_operation_failed,5),数据不删。
  从 $A2_HOME/bin/a2 那份拷贝上跑它是合法的:删掉正在执行的自身在 macOS/Linux 上没问题
  (inode 活到进程退出),命令照常跑完、退出码 0。

托管形态:
  macOS                launchd user 域 agent(~/Library/LaunchAgents),KeepAlive.Crashed 自愈 + RunAtLoad 自启
  Linux                systemd user 单元(~/.config/systemd/user),Restart=on-failure 自愈 + WantedBy=default.target 自启

status 的三态(机读字段 result.state):
  not_installed         unit 文件不在,supervisor 也不认识它
  installed_not_running 装了,但此刻没有进程
  running               supervisor 报了 pid(取 supervisor 视角;"daemon 应不应答"请用 a2 status)

三态都是**查询成功**(退出码 0),状态在 result.state 里 —— 想要"没跑就非零退出"的判据请用 a2 status(退出码 4)。

机读面(--json)里与面板有关的两个字段:
  result.status.binPath  unit 实际指向的可执行(读的是**盘上那份 unit**;未安装时给的是 install 会写的那个)
  result.actions         本次真改了什么;空数组 = 本来就是这样(bin_copied 只在拷贝内容真的变了时出现)
  result.purge           只有 --purge 才有:removedUnits(移除的 label)+ removedPaths(删掉的绝对路径)

环境变量:
  A2_HOME              覆写 ~/.a2;install 会把它写进 unit(supervisor 不读 shell 配置)
  A2_SERVICE_SUPERVISOR 覆写 supervisor 选择(launchd|systemd)。仅测试与诊断用
  A2_SELF_BIN          覆写 --copy-to-home 要拷的那份可分发单文件。仅测试与诊断用

退出码:0 成功
       1 用法错,以及「这会儿/这儿不该发」(service_purge_blocked、service_purge_home_mismatch ——
         命令没错,把状态弄对或换个 home 再原样重来)
       5 操作失败(supervisor 报错、装完没跑起来、卸下了但进程还在)
       6 这条请求在这台机器 / 这个 bin / 这个 $A2_HOME 上根本不成立(本平台无已支持的 supervisor;
         源码态的 a2 用了 --copy-to-home;--purge 的目标是 / 或家目录或一根符号链接)`;

export const MIHOMO_USAGE = `a2 mihomo —— mihomo 的获取与共存(数据面不随控制面起落)

用法:
  a2 [--json] mihomo status                检测本机现状与将采用的阶梯档位(只读)
  a2 [--json] mihomo install [--isolated]  按阶梯就位(幂等);--isolated = 不复用别人的,装 a2 自己那份
  a2 [--json] mihomo uninstall             卸掉 a2 自管的那份(unit + 进程;二进制/配置/数据保留)
  a2 [--json] mihomo upgrade               显式升级 a2 自管的二进制到锁定版

共存阶梯(检测并优先复用,复用到实例级):
  adopt_instance        有跑着的实例且 external-controller 可达 → 经 API 接管配置与存活监督;
                        **进程生死归原托管方** —— 内核绝不 stop/restart/kill 它,实例没了只报警 + 指引
  reuse_binary          只有二进制 → 只读复用它(落点上放一个符号链接,真身一个字节都不碰),
                        配置/数据目录与 com.a2.mihomo unit 全套自建
  managed_install       全无(或 --isolated)→ 按锁定版从官方渠道下载 + SHA-256 校验 + 落位,再挂 unit

兼容地板:被收编/被复用的那份不达地板时,内核**不擅自升级别人的东西** —— 收编档结构化拒绝并给两条明路,
复用档回退为隔离安装并在报文里说明原因(result.fallback)。

版本:锁定版由内核编译期常量固定;**任何路径都不静默换版本**,换版本只有 a2 mihomo upgrade 一条命令。

数据面不随控制面起落:com.a2.mihomo 与 com.a2.kernel 是两个独立 unit —— 卸内核不卸 mihomo,
内核崩了 mihomo 照跑,mihomo 崩了由系统按 KeepAlive.Crashed / Restart=on-failure 重拉。

环境变量:
  A2_HOME                  覆写 ~/.a2(自管 mihomo 落在 <A2_HOME>/mihomo/)
  A2_MIHOMO_CONTROLLER     直接指定要收编的 external-controller(host:port),跳过配置解析
  A2_MIHOMO_SECRET         配套上一条的 secret
  A2_MIHOMO_CONTROLLER_PORT 覆写 a2 自管实例的控制端口(默认 ${A2_MIHOMO_CONTROLLER_PORT},有意避开 mihomo 默认的 9090)
  A2_MIHOMO_RELEASE_BASE   覆写发布渠道根地址(镜像源)
  A2_MIHOMO_BIN_DIRS       覆写二进制搜索目录(冒号分隔)。仅测试与诊断用
  A2_MIHOMO_CONFIG_FILES   覆写配置搜索路径(冒号分隔)。仅测试与诊断用
  A2_MIHOMO_EXPECT_SHA256  覆写下载物的期望摘要。仅测试与诊断用
  A2_MIHOMO_ASSET_KEY      覆写本机资产键(如 linux-amd64,用于在别的平台上验这条路径)。仅测试与诊断用

内核只对回环地址上的 external-controller 发只读请求(GET /version、GET /configs),从不做端口扫描。

退出码:0 成功 / 1 用法错 / 5 事没办成(不可达、不达地板、不归 a2 管、下载校验失败)/ 6 本平台无已支持的 supervisor`;

export const PROXY_USAGE = `a2 proxy —— 代理控制面(域子命令 = 能力调用的另一种 argv 写法)

用法:
  a2 [--json] proxy status                        代理实况:实例在不在、控制面通不通、模式/端口/节点(safe)
  a2 [--json] proxy on                            接管系统代理,指向 mihomo 的混合入站端口(normal)
  a2 [--json] proxy off                           **还原**系统代理到接管前(normal;「退出即还原」废除后唯一的还原入口)
  a2 [--json] proxy system                        系统代理实况:逐服务逐类型的当前设置 + 有没有接管快照(safe)
  a2 [--json] proxy mode get                      读当前模式(safe)
  a2 [--json] proxy mode --mode rule|global|direct 切模式(normal)
  a2 [--json] proxy groups                        列分组与候选节点(safe)
  a2 [--json] proxy node --group G --node N       按组选节点(normal)
  a2 [--json] proxy ping --group G [--timeout ms] [--url URL]   按组测速(safe)
  a2 [--json] proxy config                        读自管配置的可调项(safe)
  a2 [--json] proxy config set [--mixedPort N] [--allowLan true|false]
                                [--logLevel …] [--mode …]        改可调项并重载(normal)
  a2 [--json] proxy subscription list             列订阅与激活项(safe)
  a2 [--json] proxy subscription add --name N --source S    新增/换源(**dangerous**,无确认器时默拒)
  a2 [--json] proxy subscription update --id ID   重新拉取(normal;激活项会重载,失败自动回滚)
  a2 [--json] proxy subscription activate --id ID 让它生效(normal)
  a2 [--json] proxy subscription remove --id ID   删除(**dangerous**:不可逆)
  a2 [--json] proxy supervision                   读 daemon 的存活观测与最近事件(safe)

同一件事的两种写法:
  a2 proxy on   ≡   a2 capabilities call proxy.system.enable
两者走的是**同一个** registry.invoke —— 仲裁、参数校验、dangerous 默拒完全一致(有断言把守)。

跟哪个 mihomo 说话:与 a2 mihomo status 报的 result.instance 是同一个答案(自管档 = a2 自己那份,
收编档 = 你自己那个实例)。**收编档的写面到配置为止**:改模式、选节点可以;换配置文件类的动作
(改可调项、激活/更新订阅)一律 mihomo_not_managed —— 别人的实例其配置归它的主人。

系统代理:接管与还原都是**显式命令**,不挂任何客户端的生命周期。接管前的完整状态(逐网络服务 ×
逐类型 × 逐字段)落在 <A2_HOME>/system-proxy.json;有它在,a2 proxy off 永远能精确还原
(含你原本就有的第三方代理),哪怕中间内核崩过、机器重启过。V1 只支持 macOS。

退出码:0 成功 / 1 用法错 / 2 dangerous 被拒 / 4 daemon 不可达 / 5 事没办成 / 6 参数或平台不成立`;

export const ARBITRATION_USAGE = `a2 arbitration —— dangerous 三层仲裁面(只读查询)

用法:
  a2 [--json] arbitration status   看确认器在不在场、有没有在途确认、最近的审计事件(safe)

三层仲裁(ADR 0005 修订后第 4 条):
  ① 无确认器在场    → confirmation_unavailable(fail-closed 默拒,退出码 2)
  ② 拒绝即指引      → 每条拒绝都带机器可读的「人类如何完成」精确命令(agent 只转告)
  ③ 有确认器在场    → 带外确认,三种收场:
                       批准     → 照常执行(退出码 0)
                       拒绝     → confirmation_denied(退出码 2)
                       无人应答 → confirmation_timeout(退出码 3;沉默不构成同意)

在场 = 长连接:确认器在 UDS 上注册 confirm-agent 角色并保持连接;**断线即离场**,
在途的 dangerous 请求立即降回 ①(confirmation_unavailable)。无心跳、无 TTL、无陈旧窗口。

永远没有的东西:--yes 类旁路、TTY 交互确认(isatty 不构成人类证明)、经 AI agent 之手的确认。

审计:每一次仲裁与每一次角色进出都落 <A2_HOME>/log/arbitration.log(NDJSON,一行一条),
同时推给在场的长连接;最近若干条经本命令可查。

环境变量:
  A2_CONFIRM_TIMEOUT_MS  覆写确认超时窗口(默认 120000)。仅测试与诊断用

退出码:0 成功 / 1 用法错 / 4 daemon 不可达 / 6 参数不合契约`;

/**
 * 插件面的帮助。**它同时是插件协议的规格书**:北极星是「agent 现场写插件」,
 * 而一个 agent 手上通常只有这台机器上的这个 bin —— 它必须能只读这一屏就写出一个能用的插件。
 * 所以下面那段例子是可以逐字抄走就跑的,不是示意。
 */
export const PLUGIN_USAGE = `a2 plugin —— 插件装载(单文件 .ts 现场写完当场可用;带依赖的交目录)

用法:
  a2 [--json] plugin add <路径> [--name <名字>]   登记一个插件(即时生效,无任何确认闸)
  a2 [--json] plugin list                        列出已登记插件与它们的能力 id
  a2 [--json] plugin remove <名字>                卸载(它的能力当场从注册表消失)

<路径> 收两种形态,**运行期没有区别**(都是登记区里的一个单文件工件):
  ① 零依赖单文件 .ts / .js —— 现场写完直接装,不需要任何构建步骤(北极星主形态);
  ② 带 npm 依赖的**目录** —— 入口(index.ts,或 package.json 的 main/module 指着的那个)
     + 可选 package.json。内核在 add 那一刻替你做完这些,你一步都不用自己跑:
       临时目录里 bun install --ignore-scripts  →  bun build --target=bun  →  单文件工件登记
     node_modules 用完即弃(**绝不进 ~/.a2**),源目录一个字节都不会被写。
     装完删掉源目录也照跑 —— 依赖已经内联进工件了。

装上之后**怎么调**:与内置能力同一个调用面 —— 没有 a2 plugin call 这回事。
  a2 capabilities call plugin.<插件名>.<工具名> --input '{"参数":"值"}' --json

命名:能力 id 恒为 plugin.<插件名>.<工具名>。插件名默认取文件名(去扩展名)或目录名,--name 可覆写;
名字与工具名的取值域都是 [a-z0-9][a-z0-9_-]*。同名再 add = 替换(工件换掉,id 不变)。

内核 → 插件的协议(exec 一次一调,一次调用一个进程):
  <内核> --no-install <工件> describe      stdout 一行 JSON:{"protocol":1,"tools":[…]}
  <内核> --no-install <工件> call          stdin 一行 {"tool":"…","input":{…}};stdout 一行结果
退出码即成败(词表封闭):
  0  成功           stdout 是 {"ok":true,"output":<任意 JSON>}
  2  报文读不懂     内核发来的调用报文不合协议(正常永不出现)
  3  业务失败       stdout 是 {"ok":false,"error":{"message":"…","detail":"…"}}
  4  未知工具       describe 说有、call 说没有(清单与实现漂了)
  其余非零 = 没跑成(未捕获异常会让运行时以 1 退出,栈在 stderr 里)。
stdout 只放那一行 JSON,调试信息一律写 stderr —— 内核两条流是分开收的。

工具声明(parameters 与内置能力同一套纯数据形):
  {"name":"…","summary":"…","dangerous":false,
   "parameters":[{"name":"…","type":"string|number|boolean|object|array",
                  "required":true,"description":"…","allowedValues":["…"]}]}
dangerous 是**声明**:声明为真的工具被调用时自动走三层仲裁(无确认器在场即默拒);
声明为假的按 normal 登记(内核无从知道你的工具是不是只读,所以不会替你降到 safe)。

一个可以逐字抄走的最小插件(存成 hello.ts,然后 a2 plugin add ./hello.ts):
  const TOOLS = [
    { name: "greet", summary: "打个招呼", dangerous: false,
      parameters: [{ name: "who", type: "string", required: true, description: "跟谁打招呼" }] },
  ];
  const mode = process.argv[2];
  if (mode === "describe") {
    console.log(JSON.stringify({ protocol: 1, tools: TOOLS }));
    process.exit(0);
  }
  if (mode === "call") {
    const req = JSON.parse(await Bun.stdin.text());
    if (req.tool === "greet") {
      console.log(JSON.stringify({ ok: true, output: { hello: req.input.who } }));
      process.exit(0);
    }
    console.log(JSON.stringify({ ok: false, error: { message: "未知工具" } }));
    process.exit(4);
  }
  process.exit(2);

打不进单文件的东西(add 时当场拒绝 + 指引,不做半吊子兼容):
  * native addon(.node)与任何被外置的资源 —— 判据是"打包产物不止一个文件";
  * 打包失败(包名拼错、依赖没声明、这台机器连不上 registry)—— 打包器原文进 detail;
  * 动态 require(变量)/ 拼出来的 import —— 打包期**看不见**,所以它活到调用时才发作:
    内核运行插件恒带 --no-install,于是那是一句 Cannot find package 硬错,而不是静默联网装包。
    报错的指引会告诉你改成静态 import 后重新 add。

供应链口径(与"装载零闸"配套):add 不执行你的插件代码 —— install 带 --ignore-scripts,
连**你自己** package.json 里的 preinstall/postinstall/prepare 一起拦(默认只拦依赖的,不拦根工程的)。
装了哪些依赖、拦下了哪些脚本,都写进 plugin_added 审计事件(a2 arbitration status 查得到)。

边界(V1 显式不做,不是遗漏):
  * 插件**没有事件面、没有常驻态** —— 不能主动推事件,也不能跨调用保存内存状态(要存就自己写文件);
  * 插件是**进程外子进程**,能力只经本协议进出;内核不把自己的坐标(A2_HOME 等)传给它;
  * 运行期**不联网装包**(内核固定带 --no-install)。import 了没打进来的包 = 调用时硬失败;
  * stdout/stderr 各有 4MiB 上限,一个插件最多声明 128 个工具 —— 撞上即结构化错误 + 杀掉;
  * 内核杀得掉插件进程本身,**杀不掉它派生的子孙**(没有进程组的口子)。插件自己 spawn 的进程
    请自己收尾:它继承着同一条 stdout,不退出就会把这次调用拖到超时。

环境变量:
  A2_PLUGIN_TIMEOUT_MS         describe/call 的超时窗口(默认 15000)。超时即杀,不等不猜
  A2_PLUGIN_BUILD_TIMEOUT_MS   目录插件 install+build 的窗口(默认 180000)。与上面那条**不是**同一个
                               旋钮:一次调用是毫秒级,冷缓存装一棵依赖树是秒级
  BUN_INSTALL_CACHE_DIR        装依赖时的包缓存(缺省 ~/.bun/install/cache)

退出码:0 成功 / 1 用法错 / 4 daemon 不可达 / 5 装载或调用没成 / 6 插件说的话不合协议`;

export const ABOUT_USAGE = `a2 about —— 版本、许可与外部程序声明(GPL 义务的必有落点)

用法:
  a2 [--json] about                打印版本、许可、外部程序声明与随包静态文本的落点

不接受任何参数,也**不经 daemon** —— 声明必须在 daemon 没装、没跑、装坏了的时候一样读得到
(ADR 0007 修订版:义务落点不依赖任何 UI,也不依赖任何常驻进程)。

它说了什么:
  * a2 本体的许可口径(不含也不链接任何 GPL 代码);
  * 调用的**外部**程序 mihomo:GPL-3.0、锁定版本、源码获取地址、发布渠道;
  * **不随包分发**:a2 的任何分发物都不含 mihomo 二进制,它由你的显式命令获取;
  * **独立子进程红线**的原文:只以独立子进程 + 本地 REST 控制面调用,永不进程内链接;
  * 随包静态文本(与 a2 同目录)在不在:${NOTICE_FILE_NAME} 与 ${GPL_LICENSE_FILE_NAME};
  * 升级口径:**没有静默更新**,升级永远是显式动作。

同一份声明的另外两个呈现面:发布包里的 ${NOTICE_FILE_NAME}(本命令的输出原样落盘)、
菜单栏壳「A2 Panel」的关于页(可选呈现面,不是义务落点)。

退出码:0 成功 / 1 用法错 / 6 输出不合契约(内部错,正常永不出现)`;

/** 域名 → 该域的用法文本。域子命令面统一从这里取(没登记的域退回顶层帮助)。 */
export const DOMAIN_USAGE: Record<string, string> = {
  proxy: PROXY_USAGE,
  arbitration: ARBITRATION_USAGE,
};

/** 帮助 = 一条成功包封(机读面无例外)+ 人类面原文。 */
export function helpOutcome(usage: string): CommandOutcome {
  return {
    envelope: successResponse(crypto.randomUUID(), { usage }),
    human: usage,
    exitCode: ExitCode.success,
  };
}

/**
 * 用法错。`steps` 给的是**这一层**的下一步命令(顶层给 `a2 help`,能力面给能力面的两条),
 * 人类面则把错误 + 对应的用法段落一起打到 stderr。
 */
export function usageOutcome(
  message: string,
  options: { usage?: string; steps?: { description: string; command?: string }[] } = {},
): CommandOutcome {
  const usage = options.usage ?? USAGE;
  const envelope = failureResponse(crypto.randomUUID(), {
    code: ErrorCode.usage,
    message,
    guidance: {
      summary: "查看可用子命令与参数后重试。",
      steps: options.steps ?? [{ description: "打印帮助", command: "a2 help" }],
    },
  });
  return {
    envelope,
    human: `${renderWireError(envelope.error)}\n\n${usage}`,
    exitCode: ExitCode.usage,
  };
}

/** 能力面的用法错:指引直接指向能力面自己的帮助与"看看有哪些能力"。 */
export function capabilitiesUsageOutcome(message: string): CommandOutcome {
  return usageOutcome(message, {
    usage: CAPABILITIES_USAGE,
    steps: [
      { description: "打印能力面用法", command: "a2 capabilities --help" },
      { description: "列出本内核实际提供的能力", command: "a2 capabilities list --json" },
    ],
  });
}

/** 服务面的用法错:指引指向服务面自己的帮助与"先看看现在装没装"。 */
export function serviceUsageOutcome(message: string): CommandOutcome {
  return usageOutcome(message, {
    usage: SERVICE_USAGE,
    steps: [
      { description: "打印服务面用法", command: "a2 service --help" },
      { description: "查当前安装态与运行态", command: "a2 service status --json" },
    ],
  });
}

/**
 * 域子命令面的用法错。指引里除了帮助之外,**把这个域实际有哪些写法逐条列出来** ——
 * 别名表是内核说了算的(插件也会往里加),所以这里给的是刚刚从 daemon 拿到的那一份,不是写死的散文。
 */
export function domainUsageOutcome(
  domain: string,
  message: string,
  hints: string[],
): CommandOutcome {
  const base = DOMAIN_USAGE[domain] ?? USAGE;
  return usageOutcome(message, {
    usage: hints.length > 0 ? `${base}\n\n本内核当前实际登记的写法:\n  ${hints.join("\n  ")}` : base,
    steps: [
      { description: `打印 ${domain} 面用法`, command: `a2 ${domain} --help` },
      { description: "列出本内核实际提供的能力(含风险档与参数)", command: "a2 capabilities list --json" },
    ],
  });
}

/** 插件面的用法错:指引指向协议规格(帮助)与"先看看现在装了什么"。 */
export function pluginUsageOutcome(message: string): CommandOutcome {
  return usageOutcome(message, {
    usage: PLUGIN_USAGE,
    steps: [
      { description: "打印插件协议与最小例子", command: "a2 plugin --help" },
      { description: "看看现在都装了什么", command: "a2 plugin list --json" },
    ],
  });
}

/** about 面的用法错:指引指向本面帮助与那条不带参数的正确写法。 */
export function aboutUsageOutcome(message: string): CommandOutcome {
  return usageOutcome(message, {
    usage: ABOUT_USAGE,
    steps: [
      { description: "打印版本、许可与外部程序声明", command: "a2 about" },
      { description: "同一份声明的机读形态", command: "a2 about --json" },
    ],
  });
}

/** mihomo 面的用法错:指引指向本面帮助与"先看看本机现在是什么现状"。 */
export function mihomoUsageOutcome(message: string): CommandOutcome {
  return usageOutcome(message, {
    usage: MIHOMO_USAGE,
    steps: [
      { description: "打印 mihomo 面用法", command: "a2 mihomo --help" },
      { description: "查本机现状与将采用的阶梯档位", command: "a2 mihomo status --json" },
    ],
  });
}
