# 04 接管的确认体验:系统弹框 × dangerous 仲裁

Type: grilling
Status: resolved
Blocked by: 01

## Question

`a2 url-router takeover` 定为 dangerous(系统状态接管,与 proxy on 同构)。但 macOS 自己
会弹「是否将“A2 Panel”设为默认浏览器」确认框——真人在场证明自带。要裁:

- **双确认还是一道**:a2 的 dangerous 仲裁(确认器/默拒)与系统弹框叠加,是接受双弹框、
  还是把系统弹框认定为「该命令的确认器」(需要 01 回答弹框结果能否被感知);
- **headless 路径**:无壳、纯 CLI 场景下 takeover 的流程与拒绝报文形态(「拒绝即指引」:
  报文要不要直接给出人类可执行的精确命令);
- **restore 的分级**:还原(设回兜底浏览器)是不是同级 dangerous,还是降级(它是在
  「归还」系统状态)。

依赖 [01](01-default-handler-api-facts.md) 的弹框归属/结果感知事实。裁定并入
[06](06-spec-final.md)。

## Answer

裁定(2026-09-03,一轮 grilling,四问全清):

1. **一道确认,系统弹框 = 本命令的确认器**。ADR 写成可复用原则:「OS 强制呈现、agent 伪造
   不了、结果可被发起方感知的系统确认,可充当该命令的确认器」。前提绑死 01 的结论:必须走
   NSWorkspace 新 API(completion 在用户点完后回调);旧 LS API 结果不可感知,不满足原则。
2. **执行器 = 壳(机械执行器)**。内核经 UDS 下发「执行接管/还原」指令,壳调 NSWorkspace、
   completion 结果原样回传,决策全在内核。壳已装未跑时内核 `open -b com.a2.panel` 自动拉起
   ——takeover 是用户显式发起的变更,拉壳是其中一步,不违「永不隐式拉起」(那条管的是查询);
   壳未安装才结构化拒绝 + 指引(先装 A2 Panel.app)。免 CLT。
3. **有界等待 + 超时未决**:CLI 等 completion 最多 120s;超时回结构化 `confirmation_timeout`
   + 指引「稍后 `a2 url-router status` 核实」(用户晚点才点也算数)。无 GUI 会话(SSH 等)
   检测到弹不了框即刻结构化拒绝 + 指引(到 Mac 桌面会话执行,或系统设置手选)。等待的是
   OS 异步结果而非 stdin 交互,不违 ADR 0005「永不交互阻塞」。
4. **restore 同级 dangerous**:与 takeover 对称,契约最简单;确认模型下运行时行为无差别
   (系统框总会弹),不留「降级命令也能改系统体验」的类推口子。

连锁澄清(并入 06 spec 体验章):用户「退出 A2」会连带 service stop(ADR 0008 修订),
此后点链接 → LS 重新拉起壳 → 内核不可达 → 03 的兜底 + 节流通知。降级故事闭环,无需新票。

## Comments
