#!/bin/bash
# PROTOTYPE — S2 capability 纵切 spike。不经 SPM，直接 swiftc 构建两个二进制。
# 原因：本机 CLT 的 libPackageDescription 坏库，swift build 不可用（见 S1 README）。
# -vfsoverlay 遮掉 CLT 里重复定义 SwiftBridging 的旧 module.modulemap（只读复用 S1 的那份，不复制不修改）。
# 实测：即便纯 Foundation/Darwin 的 aa（不 import AppKit）也报同一 SwiftBridging 重定义错，
#       故两个二进制都要加 overlay——这是 CLT 层面的坏 modulemap，与是否用 AppKit 无关。
# -module-cache-path 用 S2 自己的缓存目录。首次编译 S2Host 约 1–4 分钟（AppKit），后续秒级。
# 2026-08-04：本机 CLT 已修（旧 module.modulemap 已改名 .disabled），overlay 在此机上已成冗余——
#   保留不删，好让本 spike 在 CLT 仍坏的机器上照样能跑。门禁走自动探测，见 Scripts/check/bootstrap.sh。
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build

OVERLAY="/Users/Shared/Workspaces/PROJECT_AA/Spikes/S1PetOverlay/toolchain-workaround/overlay.yaml"

echo "== 编译 S2Host（import AppKit，需 overlay）=="
swiftc -swift-version 5 -vfsoverlay "$OVERLAY" -module-cache-path .build/mcache \
  -o .build/S2Host Sources/S2Host/*.swift

echo "== 编译 aa（纯 Foundation/Darwin；overlay 仍必需，见文件头注释）=="
swiftc -swift-version 5 -vfsoverlay "$OVERLAY" -module-cache-path .build/mcache \
  -o .build/aa Sources/aa/main.swift

echo "== 构建完成: .build/S2Host, .build/aa =="
