# --- 断言组 1:Registry 纯逻辑(经 AAHostTestKit 假件,不起真宿主 / 不碰 UDS)---
echo "--- 断言组 1:Registry 纯逻辑(AAHostTestKit.RegistryConformanceTests)---"
OUT="$("$TESTRUNNER" 2>&1)"; RC=$?
printf '%s\n' "$OUT" | sed 's/^/    /'
assert_exit 0 $RC "registry-tests 全绿退出码"
assert_contains "$OUT" "demo.echo" "纯逻辑测试覆盖 demo.echo"
# 04 票安全核三分支(纯逻辑,假件驱动,不起宿主):
assert_contains "$OUT" "假 confirm=true 时 handler 恰执行一次" "纯逻辑:dangerous+confirm=true → 执行 handler"
assert_contains "$OUT" "假 confirm=false → denied" "纯逻辑:dangerous+confirm=false → denied"
assert_contains "$OUT" "handler 绝不执行(fail-closed 保底)" "纯逻辑:confirm=nil → fail-closed 绝不执行(安全保底)"
assert_contains "$OUT" "failed=0" "纯逻辑测试无失败项"

# 06 票纯逻辑断言(同一 runner 输出;ProxyConformanceTests:Port 假件 / RESTClient / proxy.status 域逻辑)
echo "--- 断言组 1b:06 票插件域逻辑纯逻辑(ProxyConformanceTests)---"
assert_contains "$OUT" "PROXY_TESTS passed=" "06 纯逻辑套件已运行(ProxyConformanceTests)"
assert_contains "$OUT" "假 ProcessPort:拉起后探活为真" "①ProcessPort 假件:拉起→探活为真"
assert_contains "$OUT" "假 ProcessPort:终止后探活为假" "①ProcessPort 假件:终止→探活为假"
assert_contains "$OUT" "假 ProcessPort:回收调用被记录(反孤儿可核验)" "①ProcessPort 假件:回收调用被记录"
assert_contains "$OUT" "假 ProcessPort:外部死亡后探活为假(健康检查基石)" "①ProcessPort 假件:外部死亡可检测"
assert_contains "$OUT" "REST 客户端:解析 /configs → mode=rule" "②REST 解析:mode"
assert_contains "$OUT" "REST 客户端:解析 /configs → mixed-port=7890" "②REST 解析:监听端口"
assert_contains "$OUT" "REST 客户端:解析 /proxies → 当前节点 STUB-NODE" "②REST 解析:当前节点"
assert_contains "$OUT" "status 域逻辑:内核存活 → running=true" "③status 域逻辑:内核存活→反映真实"
assert_contains "$OUT" "内核死亡 → running=false(如实未运行,不报错)" "③status 域逻辑:内核死亡→如实未运行(退出码 0)"
assert_contains "$OUT" "无内核句柄 → running=false" "③status 域逻辑:无内核句柄→如实未运行"

# 07 票纯逻辑断言(同一 runner 输出;SystemProxyConformanceTests:快照/接管/还原,注入内存假 NetworkConfigPort)
echo "--- 断言组 1c:07 票系统代理快照/接管/还原纯逻辑(SystemProxyConformanceTests)---"
assert_contains "$OUT" "07 快照:capture 捕获全部服务" "①快照:capture 捕获各服务代理原状态"
assert_contains "$OUT" "07 快照:capture 记录 Ethernet 原第三方 HTTP 代理" "①快照:记录原第三方代理(开关+host+port)"
assert_contains "$OUT" "均指向内核端口 127.0.0.1:7890" "②接管:各服务 HTTP/HTTPS/SOCKS 指向内核端口"
assert_contains "$OUT" "原本第三方代理→精确还原成第三方 203.0.113.9:8080(不是一律关闭)" "③还原:原本第三方代理→还原成第三方(非关闭)"
assert_contains "$OUT" "原本关闭的 SOCKS → 还原成关闭" "③还原:原本关闭→还原关闭"
assert_contains "$OUT" "还原后再次快照 == 接管前快照(终态精确复原)" "③还原:终态==接管前快照"
assert_contains "$OUT" "重复 enable 不覆盖首次快照" "④幂等:重复 enable 不覆盖首次快照"
assert_contains "$OUT" "内核端口未就绪时 enable 报 capability_failed(退出码5,不崩)" "⑤内核端口未就绪→enable 报业务失败(不崩)"
assert_contains "$OUT" "还原覆盖接管后新增的服务→回到接管前第三方代理(不残留指向内核死端口)" "④'重放漏洞修复:接管后新增服务也进快照、能被还原(不残留死端口)"

# 08 票纯逻辑 + 执行编排断言(同一 runner 输出;CrashRecoveryConformanceTests:判定五分支 + reap 孤儿 + 不变式,注入假件)
echo "--- 断言组 1d:08 票崩溃自愈判定/执行纯逻辑(CrashRecoveryConformanceTests)---"
# 判定五分支(纯函数 SelfHealDecision.decide):
assert_contains "$OUT" "08 自愈判定:无持久化标记 → clean(无操作)" "①判定:无标记→clean"
assert_contains "$OUT" "08 自愈判定:有标记但代理已不指向我方端口 → 用户手动改过(不覆盖,只清标记)" "②判定:用户手动改过代理→不覆盖只清标记"
assert_contains "$OUT" "08 自愈判定:残留接管 + 内核可健康重启 → 恢复接管(重指存活端口)" "③a 判定:残留+可重启→恢复接管"
assert_contains "$OUT" "08 自愈判定:残留接管 + 内核不可健康重启 → 还原快照(降级直连)" "③b 判定:残留+不可重启→还原快照"
assert_contains "$OUT" "08 自愈判定:代理指向我方端口且端口仍活 → 校正标记(视为正常)" "④判定:指向且端口活→校正标记"
# 执行编排(经 ProxyPlugin.selfHeal + 假件):恢复/还原/用户改过/无标记 + 孤儿先 reap。
assert_contains "$OUT" "08 孤儿清理:上世代残留内核 pid 4242 被先 reap(恢复前清孤儿)" "⑤孤儿 pid→自愈前先 reap(还 06 反孤儿债)"
assert_contains "$OUT" "08 恢复接管:系统代理指向存活端口 127.0.0.1:7890(内核已重启)" "执行:恢复接管→代理指向存活端口"
assert_contains "$OUT" "08 还原快照:精确还原成接管前第三方代理 203.0.113.9:8080(非一律关闭)" "执行:还原快照→精确复原第三方代理"
assert_contains "$OUT" "08 用户改过:绝不覆盖用户设置(用户的第三方代理 198.51.100.5:1080 原封不动)" "执行:用户改过→不覆盖用户设置"
assert_contains "$OUT" "08 clean:无标记时不写系统代理(提前返回,避免无谓触达真 networksetup)" "执行:无标记→不触达 networksetup"
# 核心不变式:任一自愈路径后系统代理都不指向死端口(恢复→存活端口 / 还原→直连-第三方 / 用户改过→尊重用户)。
assert_contains "$OUT" "08 不变式(恢复):恢复接管后有存活受管内核" "核心不变式(恢复路径):不指向死端口"
assert_contains "$OUT" "08 不变式(还原):还原后系统代理不再指向死端口 127.0.0.1:7890" "核心不变式(还原路径):不指向死端口"
assert_contains "$OUT" "08 不变式(用户改过):终态不指向我方死端口 7890" "核心不变式(用户改过路径):不指向死端口"
# code-review 修复:pid 身份核验(修盲杀)+ 还原失败保留标记(修清标记)+ 读代理失败 deferred(修误判)。
assert_contains "$OUT" "08 身份核验:路径不符(pid 已复用为无辜进程)→ 判为非我方 → 不 reap" "修盲杀·纯逻辑:pid 路径不符→不 reap"
assert_contains "$OUT" "08 身份核验:读不到当前路径(pid 已死 / EPERM 非本用户进程)→ 不 reap" "修盲杀·纯逻辑:读不到路径/EPERM→不 reap"
assert_contains "$OUT" "08 修盲杀:持久化 pid 身份不符(路径≠记录内核路径)→ 绝不 reap(不杀无辜进程)" "修盲杀·执行:身份不符 pid 绝不被 SIGKILL"
assert_contains "$OUT" "08 修盲杀:自愈后系统代理不再指向死端口(网络照常复原)" "修盲杀·执行:不杀之余网络仍自愈(不指向死端口)"
assert_contains "$OUT" "08 修清标记 bug:还原失败 → 保留持久化标记(clearCount=0),下次启动重试" "修清标记:还原失败→保留标记待重试(不留死端口后清标记)"
assert_contains "$OUT" "08 修误判:读当前系统代理失败 → deferred(保守中止,不误判用户改过)" "修误判:读代理失败→deferred 保留标记,不误判 userChanged"

# 09 票纯逻辑断言(同一 runner 输出;ProxyConformanceTests 09 子测 + RegistryConformanceTests allowedValues):
#   控制面 REST 写/读(mode.set/node.select 构造对的 PUT;groups.list 解析;latency 逐节点 + 超时标注)+ 四能力风险级/别名/allowedValues。
echo "--- 断言组 1e:09 控制面能力包纯逻辑(REST 写读 + 能力暴露 + allowedValues 校验)---"
assert_contains "$OUT" "09 groups.list:解析出分组 PROXY(含候选节点 STUB-NODE/NODE-B/SLOW-NODE)" "09 纯逻辑:groups.list 解析组/候选"
assert_contains "$OUT" "09 groups.list:PROXY 当前选中 now=STUB-NODE" "09 纯逻辑:groups.list 解析 now"
assert_contains "$OUT" "09 mode.set:构造对的 PATCH /configs(body mode=global)" "09 纯逻辑:mode.set 构造对的 PATCH /configs(body;真核动词)"
assert_contains "$OUT" "09 node.select:构造对的 PUT /proxies/PROXY(body name=NODE-B)" "09 纯逻辑:node.select 构造对的 PUT /proxies/<g>(body)"
assert_contains "$OUT" "09 latency:逐节点延迟解析(STUB-NODE=120ms)" "09 纯逻辑:latency 逐节点延迟解析"
assert_contains "$OUT" "09 latency:超时节点如实标注(SLOW-NODE delayMs=nil, timeout=true)" "09 纯逻辑:latency 超时节点如实标注"
assert_contains "$OUT" "09 能力暴露:proxy.groups.list=safe cliAlias[proxy,groups] 无入参" "09 纯逻辑:groups.list=safe + cliAlias"
assert_contains "$OUT" "09 能力暴露:proxy.latency.test=safe cliAlias[proxy,ping]" "09 纯逻辑:latency.test=safe + cliAlias"
assert_contains "$OUT" "09 能力暴露:proxy.mode.set=normal cliAlias[proxy,mode]" "09 纯逻辑:mode.set=normal + cliAlias"
assert_contains "$OUT" "09 能力暴露:proxy.mode.set 的 mode 声明 allowedValues[rule,global,direct]" "09 纯逻辑:mode 参数带 allowedValues"
assert_contains "$OUT" "09 能力暴露:proxy.node.select=normal cliAlias[proxy,node]" "09 纯逻辑:node.select=normal + cliAlias"
assert_contains "$OUT" "09 allowedValues:非法取值(bogus)→ invalid_params(退出码6)" "09 纯逻辑:allowedValues 非法值→invalid_params"
assert_contains "$OUT" "09 allowedValues:合法取值(global)放行执行" "09 纯逻辑:allowedValues 合法值放行"
assert_contains "$OUT" "09 防呆:超大有限 timeout(1e300)→ invalid_params(不 Int(Double) 越界崩宿主)" "09 纯逻辑:latency timeout 越界防呆(不崩,invalid_params)"

# 10 票纯逻辑断言(同一 runner 输出;SubscriptionConformanceTests + RegistryConformanceTests 的 F2:id 生成/状态机/回滚/损坏/确认收到 input)
echo "--- 断言组 1f:10 订阅管理状态机纯逻辑(id 生成/list/activate/update+回滚/add/损坏/F2 确认收 input)---"
# F1 id 生成(确定性 + 抗碰撞 + 空名拒绝)
assert_contains "$OUT" "10 F1 id:同名(大小写不敏感)→ 同 id" "10 纯逻辑 F1:同名→同 id"
assert_contains "$OUT" "10 F1 id:两个不同非 ASCII 名 → 不同 id(消除碰撞)" "10 纯逻辑 F1:异名(非ASCII)→异 id(消碰撞)"
assert_contains "$OUT" "10 F1 add:空/纯空白名 → invalidParams(退出码6)" "10 纯逻辑 F1:空名→invalidParams(6)"
assert_contains "$OUT" "10 F1 add:空名先于任何 I/O 拒绝(未 fetch、未写 config/清单)" "10 纯逻辑 F1:空名不留痕"
# list / add
assert_contains "$OUT" "10 list:空清单 → active=null、subscriptions 为空" "10 纯逻辑:list 空清单"
assert_contains "$OUT" "10 add:新增订阅成功(added=true,id 带 slug 前缀 sub-a-)" "10 纯逻辑:add 新增(slug 前缀)"
assert_contains "$OUT" "10 add:add 后 active 仍为 null(不自动激活)" "10 纯逻辑:add 不自动激活"
assert_contains "$OUT" "10 add:同 name 再 add → 同 id(确定性)" "10 纯逻辑:add 同 name 同 id"
assert_contains "$OUT" "10 add:upsert 同 name 覆盖=替换源(仍 1 条)" "10 纯逻辑:add upsert 替换源"
assert_contains "$OUT" "10 add:拉取失败不留痕(未写 config、未写清单)" "10 纯逻辑:add 拉取失败不留痕"
assert_contains "$OUT" "10 add:空内容 → 业务失败" "10 纯逻辑:add 空内容业务失败"
# activate
assert_contains "$OUT" "10 activate:激活 A 成功(activated=true,active→idA)" "10 纯逻辑:activate 成功切换"
assert_contains "$OUT" "10 activate:已是 active 幂等成功且不重复重载(reload 计数不变)" "10 纯逻辑:activate 幂等不重载"
assert_contains "$OUT" "10 activate:切到 B 成功(active→idB)" "10 纯逻辑:activate 切换到 B"
assert_contains "$OUT" "10 activate:不存在 id → 业务失败且 active 不变" "10 纯逻辑:activate not-found 不改 active"
assert_contains "$OUT" "10 activate:重载失败后 active 不变(无半态,仍未激活)" "10 纯逻辑:activate 重载失败无半态"
# update + 回滚(含 F6 回滚自身失败)
assert_contains "$OUT" "10 update:激活项更新成功(updated=true,带 lastUpdatedAt)" "10 纯逻辑:update 激活项生效"
assert_contains "$OUT" "10 update:拉取失败什么都没改(未写 config,旧配置原封不动)" "10 纯逻辑:update 拉取失败什么都不改"
assert_contains "$OUT" "10 update:空内容什么都没改(未写 config)" "10 纯逻辑:update 空内容什么都不改"
assert_contains "$OUT" "10 update 回滚:配置回退为旧 OLD(内核带回已知 good)" "10 纯逻辑:update 回滚 config 回退旧"
assert_contains "$OUT" "10 update 回滚:saveConfig 序列 [新,旧] 且末次写回旧字节" "10 纯逻辑:update 回滚写序列[新,旧]"
assert_contains "$OUT" "10 update 回滚:尝试重载旧配置(reload 共 2 次:新失败 + 回滚旧)" "10 纯逻辑:update 回滚尝试重载旧"
assert_contains "$OUT" "10 F6 回滚自身失败:写回旧失败则不再发第二次 reload(reload 仅 1 次)" "10 纯逻辑 F6:回滚写失败不再发二次 reload"
# F5 损坏清单
assert_contains "$OUT" "10 F5 损坏清单:list → capabilityFailed(不臆造空清单)" "10 纯逻辑 F5:损坏清单 list 业务失败"
assert_contains "$OUT" "10 F5 损坏清单:未发生 saveCatalog 覆盖(不抹掉用户数据)" "10 纯逻辑 F5:损坏清单不覆盖(护用户数据)"
# F2 确认回调收到 input(不再盲批)
assert_contains "$OUT" "10 F2:dangerous 确认回调确实收到本次请求的 input(不再盲批)" "10 纯逻辑 F2:确认层收到 input(消除盲批)"
# 能力暴露
assert_contains "$OUT" "10 能力暴露:proxy.subscription.add=dangerous 需必填 name+source" "10 纯逻辑:add=dangerous+必填 name/source"
