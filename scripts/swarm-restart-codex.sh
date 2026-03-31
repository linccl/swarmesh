#!/usr/bin/env bash
#
# swarm-restart-codex.sh - 顺序重启当前蜂群里的所有在线 Codex 实例

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"${SCRIPT_DIR}/swarm-cli.sh" restart-codex "$@"
