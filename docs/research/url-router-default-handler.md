# URL 分流:macOS 默认 handler 注册/还原的 API 事实(01 票)

调研:2026-09-03,url-router 铺图 01 票。主源:本机 CLT SDK 头文件
(`MacOSX.sdk` AppKit `NSWorkspace.h`、LaunchServices `LSInfo.h`)+ 参考项目实证
(`/Users/Shared/Workspaces/claude-url-router-agent-kit`)。全程只读,未改动本机 handler。

## 结论先行

1. **API 选 NSWorkspace 新面**:`-[NSWorkspace setDefaultApplicationAtURL:toOpenURLsWithScheme:completionHandler:]`
   (macOS 12+,A2 min 13 满足)。旧 `LSSetDefaultHandlerForURLScheme` 已标
   `API_TO_BE_DEPRECATED` 且弃用说明就指向前者——仍可用,但不该给新代码。
2. **接管结果可感知,这是新旧 API 的本质差**。新 API 头注原文:"Some URL schemes require
   user consent … the system will ask the user asynchronously **before invoking the completion
   handler**" —— 弹框由系统(CoreServicesUIAgent)呈现,用户点完 completion 才回调,
   拒绝时 error 非空。旧 LS API 返回 OSStatus 即刻(noErr ≠ 用户已同意),发起方对
   用户取消**不可感知**——参考项目 `set-as-default.sh` 打出的三个 `0` 就是这个语义。
   **喂 04 票**:「系统弹框能不能当确认器」的技术前提成立,但仅限新 API 路线。
3. **候选列表条件(实证)**:参考项目 Info.plist 组合在真机上进过「默认网页浏览器」候选:
   `CFBundleURLTypes` 声明 http+https(`LSHandlerRank: Owner`)+ `CFBundleDocumentTypes`
   声明 `public.html/public.xhtml/public.url`(Role: Viewer)。**ad-hoc 签名、LSUIElement=true、
   无公证均不阻碍**注册与弹框(本机实证,分发到别机时 Gatekeeper 另论,与 handler 资格无关)。
   经验上 `CFBundleURLTypes` http/https 是硬条件,DocumentTypes 是稳妥项——A2 Panel 照抄全套。
4. **还原语义**:restore = 用同一 API 把 scheme handler 设回兜底浏览器,同样弹系统框。
   还原目标先经 `urlForApplication(withBundleIdentifier:)` 解析——返回 nil 即目标 .app 不存在,
   在任何 LS 调用前就能给结构化错误(**喂 05 票**:兜底浏览器被删的检测点)。
   handler 悬空(默认 .app 被拖废纸篓)时系统自动回落到其他已注册浏览器(通常 Safari),
   链接不会打不开——中置信度(通行经验,施工时一条断言实测钉死)。
5. **发起进程与 CLT**:第三方进程可替**另一个** bundle id 注册(参考项目 CLI 实证)。路线三选:
   - `xcrun swift -e` 内联编译(参考项目做法)——**依赖 CLT**,开发机成立,终端用户不可假设;
   - 预编译小工具随 .app 分发——免 CLT,多一个构建产物进签名链;
   - **壳当机械执行器**:内核经 UDS 下发「执行接管」指令,壳调 NSWorkspace(壳本来就要在场:
     它就是被注册的 .app;completion 结果经 UDS 回内核)——免 CLT、结果可感知、决策仍在内核。
   仅列取舍,裁定归 04/05 票。

## 待施工期实测(本次只读纪律不许验)

- 用户在系统弹框点「取消」时 completion 的具体 NSError domain/code;
- 悬空 handler 回落行为的断言化复现;
- `LSCopyDefaultHandlerForURLScheme`(读向,同标弃用)或 `URLForApplicationToOpenURL`
  作为 `a2 url-router status` 数据源的取舍(本机读当前 handler 实测:
  `urlForApplication(toOpen:)` 返回 Safari,可用)。

## 证据

- `NSWorkspace.h:125-132`(SDK 头注:consent 先于 completion;三个 setDefaultApplication 变体均 macOS 12+)。
- `LSInfo.h:368-370`(`LSSetDefaultHandlerForURLScheme` 弃用标注全文,指向 NSWorkspace 替代)。
- 参考项目 `Info.plist`(候选列表实证组合)、`set-as-default.sh`(CLI 发起实证)、
  `restore-default-browser.sh`(还原同 API 实证)。
- 本机只读探测:当前 http/https handler = `com.apple.Safari`。
