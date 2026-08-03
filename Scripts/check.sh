#!/bin/bash
# 保留一个稳定门禁入口；具体实现按职责拆到 Scripts/check/。
#
# 接口契约(11 票换引擎前后不变,也是 11 票要守的那条):
#   一条命令跑完、任一步失败即非零退出;终端有清楚的 PASS/FAIL 输出。
#
# 引擎(11 票起):`swift build` + `swift test` —— Package.swift 是依赖图的唯一真值来源。
#   bootstrap.sh 现场探测一个 **SPM 可用**的 swift(判据:`swift package dump-package` rc=0);
#   build.sh 用它构建两档(AA_TESTING / AA_E2E);swift-test.sh 跑 swift-testing 用例;
#   其余脚本是搬不进 swift test 的那部分断言(进程级 / UDS 级 / 真内核 E2E,靠 shell 起真进程)。
set -uo pipefail

CHECK_DIR="$(cd "$(dirname "$0")/check" && pwd)"

source "$CHECK_DIR/bootstrap.sh"
source "$CHECK_DIR/build.sh"
source "$CHECK_DIR/test-support.sh"
# swift-test.sh 须在 build.sh 之后(用它探到的 $SWIFT_BIN),也在 test-support.sh 之后(用它建的 PASS/FAIL)。
source "$CHECK_DIR/swift-test.sh"
source "$CHECK_DIR/unit-and-domain.sh"
source "$CHECK_DIR/agent-e2e.sh"
source "$CHECK_DIR/capabilities-e2e.sh"
source "$CHECK_DIR/proxy-e2e.sh"
source "$CHECK_DIR/subscriptions-e2e.sh"
source "$CHECK_DIR/architecture-and-cli.sh"
# app-bundle.sh 排在这里有讲究:它要用 architecture-and-cli.sh 之前建立的一切(assert 助手、$BIN、宿主生命周期助手),
#   又必须排在 mihomo-real-e2e.sh **之前** —— 两者都会起真 mihomo 内核并争同一个 UDS socket,
#   而 mihomo-real-e2e 开头就 teardown_hosts,天然替本组兜一层底。
source "$CHECK_DIR/app-bundle.sh"
source "$CHECK_DIR/mihomo-real-e2e.sh"
source "$CHECK_DIR/finalize.sh"
