# 05 — `a2 service`:常驻服务显式安装、卸载与状态

**What to build:** 蓝图第②步的服务安装半边。用户一条 `a2 service install` 把内核 daemon 显式装成系统托管常驻:macOS 写 launchd user 域 plist 并 `launchctl bootstrap`,Linux 写 systemd user unit;开机自启与崩溃自愈(`KeepAlive.Crashed` / `Restart=on-failure`)全归系统 supervisor。`a2 service status` 机读呈现安装态与运行态;未安装/未运行时其他 CLI 命令给结构化指引、永不隐式拉起。

**Blocked by:** 03(契约骨架)。

**Status:** done — 328ca94 三条命令全收敛语义(幂等即 actions 为空)、macOS 活体冒烟 28/28 全绿、Linux 代码路径单测齐(实机顺延);顺带修掉一个"装完立刻 status 会不可达"的真 bug

- [x] `a2 service install` 幂等落 `com.a2.kernel` 单元(macOS launchd user 域 / Linux systemd user),unit 内容指向 `a2 daemon run`;`uninstall` 干净移除
  - 落点 `src/service/{unit,supervisor,manager}.ts`。**收敛语义**:算出目标 unit 内容 → 与磁盘逐字比较 → 只在有差时才写/重装;已收敛时不发任何改状态的命令,`actions` 返回空数组(幂等的可观察面,不必比对前后状态)。
  - macOS:`~/Library/LaunchAgents/com.a2.kernel.plist` + `launchctl bootstrap gui/$UID`;unit 内容漂了会**先 bootout 再 bootstrap**(已装载的 job 不会自己发现 plist 变了)。
  - Linux:`$XDG_CONFIG_HOME/systemd/user/com.a2.kernel.service` + `daemon-reload` → `enable` → `start`(systemd 的 enable 不含拉起,与 launchd 的 RunAtLoad 不同,编排因此分两套)。
  - ProgramArguments 指向**当前这个 a2**:编译产物 → `<bin> daemon run`;源码跑 → `<bun> run <入口> daemon run`(判据是 Bun 编译产物特有的 `/$bunfs/` 前缀,实测)。`A2_HOME` 写进 unit 的环境变量(supervisor 不读 shell 配置)。
  - uninstall 对称:bootout / stop+disable → 删 unit → (systemd)daemon-reload,并**确认进程真没了**才算成功;两条命令都幂等(活体冒烟 6/8、7/8 各有断言)。
- [x] 崩溃自愈由系统 supervisor 配置承担(杀掉 daemon 进程,系统按策略重拉),应用层无看门狗
  - plist:`KeepAlive={Crashed:true}` + `RunAtLoad` + `ThrottleInterval=10`;systemd:`Restart=on-failure` + `RestartSec=10`。代码里没有任何重启逻辑。
  - **活体实测(真 launchctl)**:SIGSEGV 与 SIGABRT 都会被重拉(各等约 9s = ThrottleInterval);**`kill -9`(SIGKILL)不会** —— launchd 把它当"有人存心弄死它",不算 crash(man page 原文只承诺 "SIGILL, SIGSEGV, etc.")。systemd 的 `Restart=on-failure` 在这格更宽(信号致死一律算 failure)。这处两端不对称已写进 `src/service/unit.ts` 注释与对等映射表;**未改成 `KeepAlive:true`**,因为 spec 锁定的就是 `Crashed`/`on-failure` 这对语义(改它等于重开决策)。
- [x] `a2 service status --json` 区分「未安装 / 已安装未运行 / 运行中」三态并机读输出
  - 契约 `ServiceStatusResult{state,supervisor,label,unitPath,unitInstalled,registered,pid?,home,socketPath}`,`state` 取值即契约(金标三份 + 一份非法样本守住"不许有第四态")。
  - 判据**一律取 supervisor 视角**,不掺 UDS 探活:"daemon 应不应答"是 `a2 status` 的问题。三态**都是查询成功(退出码 0)**——"没装"是合法答案不是失败;要"没跑就非零退出"请用 `a2 status`(4)。
- [x] daemon 不可达时,任意需要 daemon 的 CLI 命令返回含精确修复命令(如 `a2 service install` 原文)的结构化指引,非零退出码,绝不隐式拉起
  - 这条在 03/04 票已成立(`callKernel` 只 connect 从不 spawn,断言在 `cli-status.test.ts`);05 票让指引里那条命令**真的存在了**(此前是空头支票),命令名未变,金标 `response-daemon-unreachable.json` 无需改。
  - install 是**人类显式授权**的动作,由它把常驻交给系统 supervisor 不破这条红线;status 只读。
- [x] macOS 路径本机实测通过;Linux 路径以单元测试覆盖 unit 生成与命令编排(实机验收顺延,spec「Linux 口径」)
  - macOS:`kernel/scripts/service-live-smoke.sh` 用**真 launchctl** 跑完整生命周期,**PASS=28 FAIL=0**(未安装态 → install → launchd 认账 → UDS 往返 → SIGSEGV 自愈 → 幂等 → uninstall → 清残验证)。开跑前先确认 `com.a2.kernel` 不存在,存在就中止(不是我的就不动)。
  - Linux:`cli-service.test.ts` 里 `A2_SERVICE_SUPERVISOR=systemd` + 假 systemctl,unit 内容/路径/编排/幂等全有断言;**实机验收顺延**。

## 做完之后的实情(2026-08-05 凌晨)

**门禁**:`bun test` **79 pass / 0 fail**(6 个文件;源码入口与 `A2_TEST_BIN=dist/a2` 编译产物两种被测体跑同一批断言);`bun x tsc --noEmit` 干净;`bash Scripts/check.sh` → **PASS=429 FAIL=0**(日志 `/tmp/a2-check-05.log`,Swift 侧一行未动)。

**活体冒烟抓到的真 bug(已修)**:supervisor 一 `exec` 就报得出 pid,而内核还要几百毫秒才 bind socket(实测那一刻连 `<home>/run` 目录都还没建)。install 若在此时返回,agent 紧接着的一条 `a2 status` 会拿到 `daemon_unreachable`。现在 install 会等到内核**真的在 socket 上应答**(`DAEMON_READY_TIMEOUT_MS`,用的就是普通客户端那条路,不另造探针);CLI 缝上有对应断言,去掉这段等待即 2 红。

**清残验证(跑完后逐条查)**:`launchctl print gui/501/com.a2.kernel` → 113(不存在);`~/Library/LaunchAgents` 无 `com.a2.*`;用户真实 `~/.a2` **仍不存在**;无 a2 孤儿进程;`/tmp/a2live-*`、`/tmp/a2svc-*` 等临时目录全清;用户自己的 mihomo(`io.metacubex.mihomo` pid 553,127.0.0.1:33888)全程未被触碰。
