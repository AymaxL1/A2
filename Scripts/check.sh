#!/bin/bash
# 保留一个稳定门禁入口；具体实现按职责拆到 Scripts/check/。
set -uo pipefail

CHECK_DIR="$(cd "$(dirname "$0")/check" && pwd)"

source "$CHECK_DIR/bootstrap.sh"
source "$CHECK_DIR/build.sh"
source "$CHECK_DIR/test-support.sh"
source "$CHECK_DIR/unit-and-domain.sh"
source "$CHECK_DIR/agent-e2e.sh"
source "$CHECK_DIR/capabilities-e2e.sh"
source "$CHECK_DIR/proxy-e2e.sh"
source "$CHECK_DIR/subscriptions-e2e.sh"
source "$CHECK_DIR/architecture-and-cli.sh"
source "$CHECK_DIR/mihomo-real-e2e.sh"
source "$CHECK_DIR/finalize.sh"
