#!/usr/bin/env bash
################################################################################
# swarm-events.sh - 事件监控/查询/等待脚本
#
# 三种模式:
#   --follow   实时监控事件流（格式化输出）
#   --wait     阻塞等待特定事件（可替代 detect 轮询）
#   --history  查看历史事件
#
# 用法:
#   swarm-events.sh --follow [--type TYPE] [--role ROLE]
#   swarm-events.sh --wait <type> [--role ROLE] [--timeout SECONDS]
#   swarm-events.sh --history [--last N] [--type TYPE] [--role ROLE]
#
# 示例:
#   swarm-events.sh --follow
#   swarm-events.sh --follow --type task.completed --role backend
#   swarm-events.sh --wait task.completed --role backend --timeout 300
#   swarm-events.sh --history --last 20
################################################################################

set -euo pipefail

# =============================================================================
# 配置
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_ROOT="${SWARM_ROOT:-$(dirname "$SCRIPT_DIR")}"
RUNTIME_DIR="${RUNTIME_DIR:-$SWARM_ROOT/runtime}"
EVENTS_LOG="${EVENTS_LOG:-$RUNTIME_DIR/events.jsonl}"

# 模式
MODE=""
FILTER_TYPE=""
FILTER_ROLE=""
TIMEOUT=0
LAST_N=0

# 颜色
readonly C_RESET='\033[0m'
readonly C_TIME='\033[0;90m'
readonly C_TYPE='\033[0;36m'
readonly C_ROLE='\033[0;33m'
readonly C_DATA='\033[0;37m'
readonly C_HEADER='\033[1;37m'

# =============================================================================
# 工具函数
# =============================================================================

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo -e "\033[0;34m[events]\033[0m $*" >&2; }

# 打印表头
print_header() {
    printf "${C_HEADER}%-19s  %-25s  %-12s  %s${C_RESET}\n" "时间" "事件类型" "角色" "数据"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# 格式化输出单条事件
format_event() {
    local line="$1"
    local ts type role data
    ts=$(echo "$line" | jq -r '.ts // ""')
    type=$(echo "$line" | jq -r '.type // ""')
    role=$(echo "$line" | jq -r '.role // ""')
    data=$(echo "$line" | jq -c '.data // {}')

    # data 为空对象时显示 -
    [[ "$data" == "{}" ]] && data="-"

    printf "${C_TIME}%-19s${C_RESET}  ${C_TYPE}%-25s${C_RESET}  ${C_ROLE}%-12s${C_RESET}  ${C_DATA}%s${C_RESET}\n" \
        "$ts" "$type" "${role:-"-"}" "$data"
}

# 检查事件是否匹配过滤条件
match_event() {
    local line="$1"

    if [[ -n "$FILTER_TYPE" ]]; then
        local type
        type=$(echo "$line" | jq -r '.type // ""')
        [[ "$type" == "$FILTER_TYPE" ]] || return 1
    fi

    if [[ -n "$FILTER_ROLE" ]]; then
        local role
        role=$(echo "$line" | jq -r '.role // ""')
        [[ "$role" == "$FILTER_ROLE" ]] || return 1
    fi

    return 0
}

# =============================================================================
# 模式实现
# =============================================================================

# --follow: 实时监控事件流
do_follow() {
    [[ -f "$EVENTS_LOG" ]] || touch "$EVENTS_LOG"

    print_header

    # 先输出已有事件
    if [[ -s "$EVENTS_LOG" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if match_event "$line"; then
                format_event "$line"
            fi
        done < "$EVENTS_LOG"
    fi

    info "实时监控中... (Ctrl+C 退出)"

    # 跟踪新事件
    tail -f "$EVENTS_LOG" 2>/dev/null | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if match_event "$line"; then
            format_event "$line"
        fi
    done
}

# --wait: 阻塞等待特定事件（零轮询，基于 tail -f kqueue/inotify 事件驱动）
do_wait() {
    [[ -f "$EVENTS_LOG" ]] || touch "$EVENTS_LOG"
    [[ -n "$FILTER_TYPE" ]] || die "--wait 需要指定事件类型"

    local start_time
    start_time=$(date +%s)
    local initial_lines
    initial_lines=$(wc -l < "$EVENTS_LOG" 2>/dev/null | tr -d ' ')

    local timeout_desc="无限制"
    [[ $TIMEOUT -gt 0 ]] && timeout_desc="${TIMEOUT}s"
    info "等待事件: $FILTER_TYPE (角色: ${FILTER_ROLE:-任意}, 超时: $timeout_desc)"

    # tail -f 事件驱动: macOS=kqueue, Linux=inotify，零轮询
    exec 3< <(tail -n +$((initial_lines + 1)) -f "$EVENTS_LOG" 2>/dev/null)
    local tail_pid=$!

    # 确保退出时清理 tail 进程和 fd
    trap "kill $tail_pid 2>/dev/null; exec 3<&-" RETURN

    while true; do
        # 计算剩余超时
        local read_timeout=""
        if [[ $TIMEOUT -gt 0 ]]; then
            local now elapsed remaining
            now=$(date +%s)
            elapsed=$((now - start_time))
            remaining=$((TIMEOUT - elapsed))
            if [[ $remaining -le 0 ]]; then
                info "等待超时 (${TIMEOUT}s)"
                return 1
            fi
            read_timeout="-t $remaining"
        fi

        # read 阻塞在 fd3 上，直到有新事件或超时 — 零轮询
        local line=""
        if IFS= read $read_timeout -r line <&3; then
            [[ -z "$line" ]] && continue
            if match_event "$line"; then
                format_event "$line"
                return 0
            fi
        else
            # read 返回非零: 超时或 EOF
            if [[ $TIMEOUT -gt 0 ]]; then
                info "等待超时 (${TIMEOUT}s)"
            fi
            return 1
        fi
    done
}

# --history: 查看历史事件
do_history() {
    [[ -f "$EVENTS_LOG" ]] || die "事件日志不存在: $EVENTS_LOG"

    print_header

    local input
    if [[ $LAST_N -gt 0 ]]; then
        input=$(tail -n "$LAST_N" "$EVENTS_LOG")
    else
        input=$(cat "$EVENTS_LOG")
    fi

    local count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if match_event "$line"; then
            format_event "$line"
            ((count++)) || true
        fi
    done <<< "$input"

    echo ""
    info "共 $count 条事件"
}

# =============================================================================
# 参数解析和主入口
# =============================================================================

show_help() {
    cat <<'EOF'
swarm-events - 事件监控/查询/等待

用法:
  swarm-events.sh --follow [--type TYPE] [--role ROLE]
  swarm-events.sh --wait <type> [--role ROLE] [--timeout SECONDS]
  swarm-events.sh --history [--last N] [--type TYPE] [--role ROLE]

模式:
  --follow      实时监控事件流
  --wait TYPE   阻塞等待指定类型的事件
  --history     查看历史事件

过滤选项:
  --type TYPE       过滤事件类型 (如 task.completed)
  --role ROLE       过滤角色 (如 backend)
  --timeout SECS    --wait 模式的超时时间
  --last N          --history 模式显示最近 N 条

示例:
  # 实时监控所有事件
  swarm-events.sh --follow

  # 只看后端完成事件
  swarm-events.sh --follow --type task.completed --role backend

  # 等待后端完成（最多 60 秒）
  swarm-events.sh --wait task.completed --role backend --timeout 60

  # 查看最近 20 条事件
  swarm-events.sh --history --last 20

  # 查看所有工作流事件
  swarm-events.sh --history --type workflow.completed
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --follow)   MODE="follow"; shift ;;
            --wait)     MODE="wait"; FILTER_TYPE="$2"; shift 2 ;;
            --history)  MODE="history"; shift ;;
            --type)     FILTER_TYPE="$2"; shift 2 ;;
            --role)     FILTER_ROLE="$2"; shift 2 ;;
            --timeout)  TIMEOUT="$2"; shift 2 ;;
            --last)     LAST_N="$2"; shift 2 ;;
            --help|-h)  show_help; exit 0 ;;
            -*)         die "未知选项: $1" ;;
            *)          die "未知参数: $1" ;;
        esac
    done

    [[ -n "$MODE" ]] || { show_help; exit 1; }

    case "$MODE" in
        follow)  do_follow ;;
        wait)    do_wait ;;
        history) do_history ;;
    esac
}

main "$@"
