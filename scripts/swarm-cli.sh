#!/usr/bin/env bash
################################################################################
# swarm-cli.sh - 蜂群通用主控入口
#
# 让任何终端/CLI 都能操控蜂群，整合所有 slash command 的功能。
# 始终以 human 身份操作。
#
# 用法:
#   swarm-cli.sh <子命令> [参数...]
#
# 子命令:
#   start   <project> [profile]       启动蜂群
#   stop    [--clean]                 停止蜂群
#   status                            查看蜂群状态
#   task    [内容]                    派发任务 / 查看收件箱
#   restart-codex                     顺序重启在线 Codex 实例
#   restart-watchdog                  仅重启任务看门狗
#   join    [role] [选项]             动态添加角色
#   leave   [role] [选项]             移除角色
#   msg     <子命令> ...              透传消息系统命令
#   help                              显示帮助信息
################################################################################

set -euo pipefail

# =============================================================================
# 配置
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/swarm-lib.sh"
PROFILES_DIR="${PROFILES_DIR:-$CONFIG_DIR/profiles}"
ROLES_DIR="${ROLES_DIR:-$CONFIG_DIR/roles}"

# 始终以 human 身份操作
export SWARM_ROLE=human

# =============================================================================
# 颜色
# =============================================================================

if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
else
    C_RESET='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi

# =============================================================================
# 工具函数
# =============================================================================

log_info()  { echo -e "${C_CYAN}[INFO]${C_RESET} $*" >&2; }
log_ok()    { echo -e "${C_GREEN}[OK]${C_RESET} $*" >&2; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
log_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
die()       { log_error "$*"; exit 1; }

# 获取在线角色列表
get_online_roles() {
    if [[ -f "$STATE_FILE" ]]; then
        jq -r '.panes[].role' "$STATE_FILE" 2>/dev/null
    fi
}

# 检查蜂群是否在运行
check_swarm_running() {
    tmux has-session -t "${SWARM_SESSION:-swarm}" 2>/dev/null
}

# 交互式选择（用 select 菜单）
interactive_select() {
    local prompt="$1"
    shift
    local options=("$@")

    if [[ ${#options[@]} -eq 0 ]]; then
        die "没有可选项"
    fi

    echo -e "${C_BOLD}${prompt}${C_RESET}" >&2
    local i=1
    for opt in "${options[@]}"; do
        echo -e "  ${C_CYAN}${i})${C_RESET} ${opt}" >&2
        ((i++))
    done

    local choice
    while true; do
        echo -n "请选择 [1-${#options[@]}]: " >&2
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "${options[$((choice-1))]}"
            return 0
        fi
        echo "无效选择，请重试" >&2
    done
}

# =============================================================================
# 子命令: start
# =============================================================================

cmd_start() {
    local project="" profile="" hidden="--hidden"

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                echo "用法: swarm-cli.sh start <project> [profile] [选项]"
                echo ""
                echo "参数:"
                echo "  <project>       目标项目路径（必需）"
                echo "  [profile]       团队配置预设（可选）"
                echo ""
                echo "选项:"
                echo "  --attach        启动后 attach 到 tmux session"
                echo "  --panes N       每窗口 pane 数（默认 2）"
                echo ""
                echo "可用 profile:"
                ls "$PROFILES_DIR" 2>/dev/null | sed 's/\.json$//'
                return 0
                ;;
            --attach)
                hidden=""
                shift
                ;;
            --panes)
                shift
                EXTRA_ARGS+=("--panes-per-window" "$1")
                shift
                ;;
            --*)
                die "未知选项: $1"
                ;;
            *)
                if [[ -z "$project" ]]; then
                    project="$1"
                elif [[ -z "$profile" ]]; then
                    profile="$1"
                else
                    die "多余参数: $1"
                fi
                shift
                ;;
        esac
    done

    # 项目路径必需
    if [[ -z "$project" ]]; then
        die "缺少项目路径。用法: swarm-cli.sh start <project> [profile]"
    fi

    # 展开 ~
    project="${project/#\~/$HOME}"

    # 如果未指定 profile，交互选择
    if [[ -z "$profile" ]]; then
        local profiles=()
        while IFS= read -r f; do
            profiles+=("$(basename "$f" .json)")
        done < <(ls "$PROFILES_DIR"/*.json 2>/dev/null)

        if [[ ${#profiles[@]} -eq 0 ]]; then
            die "没有找到 profile 配置文件"
        fi

        profile=$(interactive_select "选择团队 profile:" "${profiles[@]}")
    fi

    log_info "启动蜂群: project=$project, profile=$profile"

    local cmd=("$SCRIPTS_DIR/swarm-start.sh" --project "$project" --profile "$profile")
    [[ -n "$hidden" ]] && cmd+=("$hidden")
    [[ ${#EXTRA_ARGS[@]} -gt 0 ]] && cmd+=("${EXTRA_ARGS[@]}")

    "${cmd[@]}"

    # 显示状态
    echo ""
    log_ok "蜂群已启动"
    "$SCRIPTS_DIR/swarm-status.sh"
}

# =============================================================================
# 子命令: stop
# =============================================================================

cmd_stop() {
    local force="--force" clean=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                echo "用法: swarm-cli.sh stop [选项]"
                echo ""
                echo "选项:"
                echo "  --clean   停止后清理运行时数据（messages/tasks/state/events）"
                echo "  --help    显示帮助"
                return 0
                ;;
            --clean)
                clean="--clean"
                shift
                ;;
            *)
                die "未知选项: $1"
                ;;
        esac
    done

    # 先显示状态
    if check_swarm_running; then
        log_info "当前蜂群状态:"
        "$SCRIPTS_DIR/swarm-status.sh" 2>/dev/null || true
        echo ""
    fi

    local cmd=("$SCRIPTS_DIR/swarm-stop.sh" "$force")
    [[ -n "$clean" ]] && cmd+=("$clean")

    "${cmd[@]}"

    # 确认停止
    if check_swarm_running; then
        log_warn "蜂群仍在运行"
    else
        log_ok "蜂群已停止"
    fi
}

# =============================================================================
# 子命令: status
# =============================================================================

cmd_status() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        echo "用法: swarm-cli.sh status"
        echo ""
        echo "显示蜂群运行状态、在线角色、收件箱消息、任务队列和最近事件。"
        return 0
    fi

    # 1. 整体状态
    "$SCRIPTS_DIR/swarm-status.sh" 2>/dev/null || true
    echo ""

    # 2. 在线角色
    echo -e "${C_BOLD}=== 在线角色 ===${C_RESET}"
    "$SCRIPTS_DIR/swarm-msg.sh" list-roles 2>/dev/null || echo "  (无法获取角色列表)"
    echo ""

    # 3. human 收件箱
    echo -e "${C_BOLD}=== 收件箱（未读消息）===${C_RESET}"
    local inbox
    inbox=$("$SCRIPTS_DIR/swarm-msg.sh" read 2>/dev/null) || true
    if [[ -z "$inbox" || "$inbox" == *"没有新消息"* ]]; then
        echo "  (没有未读消息)"
    else
        echo "$inbox"
    fi
    echo ""

    # 4. 任务队列
    echo -e "${C_BOLD}=== 任务队列 ===${C_RESET}"
    "$SCRIPTS_DIR/swarm-msg.sh" list-tasks --all 2>/dev/null || echo "  (没有任务)"
    echo ""

    # 5. 最近事件
    echo -e "${C_BOLD}=== 最近事件 ===${C_RESET}"
    local events_file="$RUNTIME_DIR/events.jsonl"
    if [[ -f "$events_file" ]]; then
        tail -20 "$events_file" 2>/dev/null \
            | jq -r '[.ts, .type, .role, (.data | tostring)] | join(" | ")' 2>/dev/null \
            || echo "  (无法解析事件日志)"
    else
        echo "  (没有事件记录)"
    fi
}

# =============================================================================
# 子命令: task
# =============================================================================

cmd_task() {
    local target="" content="" wait_timeout=6000 poll_interval=15

    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        echo "用法: swarm-cli.sh task [选项] [任务描述]"
        echo ""
        echo "不带参数: 读取 human 收件箱和任务队列"
        echo "带参数:   发送任务给蜂群（默认 supervisor）"
        echo ""
        echo "格式:"
        echo "  swarm-cli.sh task <任务描述>               → 发给 supervisor"
        echo "  swarm-cli.sh task <角色名> <任务描述>      → 发给指定角色"
        echo ""
        echo "选项:"
        echo "  --no-wait           发送后不等待结果"
        echo "  --timeout <秒>      等待超时（默认 6000）"
        echo "  --poll <秒>         轮询间隔（默认 15）"
        return 0
    fi

    local no_wait=false

    # 提取选项
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-wait)
                no_wait=true
                shift
                ;;
            --timeout)
                shift
                wait_timeout="${1:-6000}"
                shift
                ;;
            --poll)
                shift
                poll_interval="${1:-15}"
                shift
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    # 无参数：读取收件箱
    if [[ ${#args[@]} -eq 0 ]]; then
        echo -e "${C_BOLD}=== 收件箱 ===${C_RESET}"
        "$SCRIPTS_DIR/swarm-msg.sh" read 2>/dev/null || echo "  (没有新消息)"
        echo ""
        echo -e "${C_BOLD}=== 任务队列 ===${C_RESET}"
        "$SCRIPTS_DIR/swarm-msg.sh" list-tasks --all 2>/dev/null || echo "  (没有任务)"
        return 0
    fi

    # 判断第一个词是否是角色名
    local first_word="${args[0]}"
    local online_roles
    online_roles=$(get_online_roles)

    if echo "$online_roles" | grep -qx "$first_word" 2>/dev/null; then
        # 指定角色 → 直接发送（不变）
        target="$first_word"
        content="${args[*]:1}"
        if [[ -z "$content" ]]; then
            die "缺少任务内容"
        fi
        log_info "发送任务给 $target: $content"
        "$SCRIPTS_DIR/swarm-msg.sh" send "$target" "$content"
    else
        # 未指定角色 → 发布到队列，所有 supervisor 竞争认领
        content="${args[*]}"
        if [[ -z "$content" ]]; then
            die "缺少任务内容"
        fi
        log_info "发布编排任务到队列: $content"
        "$SCRIPTS_DIR/swarm-msg.sh" publish orchestrate "$content" \
            --assign supervisor \
            --priority high
    fi

    if $no_wait; then
        log_ok "任务已发送（不等待结果）"
        return 0
    fi

    # 轮询等待结果
    local max_polls=$(( wait_timeout / poll_interval ))
    log_info "等待蜂群回报（最多 ${wait_timeout}s，每 ${poll_interval}s 检查一次）..."

    local i result
    for i in $(seq 1 "$max_polls"); do
        result=$("$SCRIPTS_DIR/swarm-msg.sh" read 2>/dev/null) || true
        if [[ -n "$result" && "$result" != *"没有新消息"* ]]; then
            echo ""
            echo -e "${C_BOLD}=== 收到蜂群回报 ===${C_RESET}"
            echo "$result"
            return 0
        fi
        sleep "$poll_interval"
    done

    echo ""
    log_warn "等待超时（${wait_timeout}s），蜂群仍在工作中。"
    echo "你可以："
    echo "  swarm-cli.sh task          # 查看最新消息"
    echo "  swarm-cli.sh status        # 查看蜂群状态"
}

# =============================================================================
# 子命令: restart-codex
# =============================================================================

cmd_restart_codex() {
    local continue_msg="继续当前任务（如果未完成）。如果当前任务已经完成，请检查是否还有未处理的 swarm 消息或待认领任务，再继续协作。"
    local state_session=""

    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        echo "用法: swarm-cli.sh restart-codex [选项]"
        echo ""
        echo "顺序重启当前蜂群里所有在线 Codex 实例。默认允许中断忙碌实例。"
        echo "重启后会用 codex resume 恢复会话，并发送继续任务提示。"
        echo ""
        echo "选项:"
        echo "  --continue-msg <text>   自定义恢复后发送给每个实例的提示语"
        return 0
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --continue-msg)
                shift; continue_msg="${1:-$continue_msg}"; shift
                ;;
            *)
                die "restart-codex: 未知参数 $1"
                ;;
        esac
    done

    [[ -f "$STATE_FILE" ]] || die "state.json 不存在，蜂群未启动？"
    state_session=$(jq -r '.session // empty' "$STATE_FILE" 2>/dev/null || true)
    [[ -n "$state_session" ]] && SESSION_NAME="$state_session"
    tmux has-session -t "$SESSION_NAME" 2>/dev/null || die "Session '$SESSION_NAME' 不存在"

    local instances=()
    while IFS= read -r inst; do
        [[ -n "$inst" ]] && instances+=("$inst")
    done < <(jq -r '.panes[] | select((.cli // "") | test("codex")) | .instance' "$STATE_FILE" 2>/dev/null)

    if [[ ${#instances[@]} -eq 0 ]]; then
        log_warn "当前没有在线 Codex 实例"
        return 0
    fi

    log_info "准备顺序重启 ${#instances[@]} 个 Codex 实例"
    local inst
    for inst in "${instances[@]}"; do
        restart_codex_instance "$inst" "$continue_msg"
    done

    echo ""
    log_ok "所有在线 Codex 实例已顺序重启完成"
}

# =============================================================================
# 子命令: restart-watchdog
# =============================================================================

cmd_restart_watchdog() {
    local state_session="" old_pid="" new_pid="" wait_deadline="" old_cmd=""

    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        echo "用法: swarm-cli.sh restart-watchdog"
        echo ""
        echo "仅重启任务看门狗，不触碰 tmux pane、角色实例或 Codex 会话。"
        return 0
    fi

    [[ $# -eq 0 ]] || die "restart-watchdog: 不接受额外参数"
    [[ -f "$STATE_FILE" ]] || die "state.json 不存在，蜂群未启动？"

    state_session=$(jq -r '.session // empty' "$STATE_FILE" 2>/dev/null || true)
    [[ -n "$state_session" ]] && SESSION_NAME="$state_session"
    tmux has-session -t "$SESSION_NAME" 2>/dev/null || die "Session '$SESSION_NAME' 不存在"

    old_pid=$(jq -r '.watchdog_pid // empty' "$STATE_FILE" 2>/dev/null || true)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        old_cmd=$(ps -p "$old_pid" -o args= 2>/dev/null || true)
        log_info "停止旧 watchdog: pid=$old_pid ${old_cmd:+cmd=$old_cmd}"
        kill "$old_pid" 2>/dev/null || true

        wait_deadline=$((SECONDS + 5))
        while kill -0 "$old_pid" 2>/dev/null; do
            if (( SECONDS >= wait_deadline )); then
                log_warn "旧 watchdog 在 5 秒内未退出，发送 SIGKILL: pid=$old_pid"
                kill -9 "$old_pid" 2>/dev/null || true
                break
            fi
            sleep 0.2
        done
    elif [[ -n "$old_pid" ]]; then
        log_info "旧 watchdog PID 不存在，直接重启: pid=$old_pid"
    else
        log_info "state.json 未记录 watchdog_pid，直接启动新的 watchdog"
    fi

    source "${SCRIPTS_DIR}/lib/msg-task-watchdog.sh"
    start_task_watchdog_detached
    new_pid="${WATCHDOG_PID_LAST:-}"
    [[ -n "$new_pid" ]] || die "启动 watchdog 失败：未返回 PID"
    sleep 0.2
    kill -0 "$new_pid" 2>/dev/null || die "启动 watchdog 失败：PID $new_pid 不存在"

    state_json_update '.watchdog_pid = $pid' --argjson pid "$new_pid"
    emit_event "watchdog.restarted" "" "session=$SESSION_NAME" "old_pid=${old_pid:-none}" "new_pid=$new_pid"

    log_ok "watchdog 已重启: ${old_pid:-none} -> $new_pid"
}

# =============================================================================
# 子命令: join
# =============================================================================

cmd_join() {
    local role="" cli="claude code" config="" extra_args=()

    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        echo "用法: swarm-cli.sh join [role] [选项]"
        echo ""
        echo "向运行中的蜂群添加新角色。不指定角色时交互式选择。"
        echo ""
        echo "选项:"
        echo "  --cli <cmd>       CLI 命令（默认: claude code）"
        echo "  --config <path>   角色配置文件相对路径"
        echo "  --alias <names>   角色别名，逗号分隔"
        echo "  --window <name>   指定窗口名"
        echo "  --task <desc>     加入后立即分配任务"
        echo ""
        echo "可用角色配置:"
        find "$ROLES_DIR" -name "*.md" -exec basename {} .md \; 2>/dev/null | sort
        return 0
    fi

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cli)
                shift; cli="${1:-claude code}"; shift
                ;;
            --config)
                shift; config="${1:-}"; shift
                ;;
            --alias|--window|--task)
                extra_args+=("$1" "$2"); shift 2
                ;;
            --force)
                extra_args+=("--force"); shift
                ;;
            --*)
                die "未知选项: $1"
                ;;
            *)
                if [[ -z "$role" ]]; then
                    role="$1"
                else
                    die "多余参数: $1"
                fi
                shift
                ;;
        esac
    done

    # 无角色名：交互选择
    if [[ -z "$role" ]]; then
        local available=()
        while IFS= read -r f; do
            available+=("$(basename "$f" .md)")
        done < <(find "$ROLES_DIR" -name "*.md" 2>/dev/null | sort)

        if [[ ${#available[@]} -eq 0 ]]; then
            die "没有找到角色配置文件"
        fi

        role=$(interactive_select "选择要加入的角色:" "${available[@]}")
    fi

    # 自动查找配置文件
    if [[ -z "$config" ]]; then
        local found
        found=$(find "$ROLES_DIR" -name "${role}.md" 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            # 转为相对于 roles/ 的路径
            config="${found#"$ROLES_DIR/"}"
        fi
    fi

    log_info "加入角色: $role (cli=$cli)"

    local cmd=("$SCRIPTS_DIR/swarm-join.sh" "$role" --cli "$cli" --force)
    [[ -n "$config" ]] && cmd+=(--config "$config")
    [[ ${#extra_args[@]} -gt 0 ]] && cmd+=("${extra_args[@]}")

    "${cmd[@]}"

    # 确认
    echo ""
    log_ok "角色 $role 已加入"
    "$SCRIPTS_DIR/swarm-msg.sh" list-roles 2>/dev/null || true
}

# =============================================================================
# 子命令: leave
# =============================================================================

cmd_leave() {
    local role="" reason="手动移除" force="--force"

    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        echo "用法: swarm-cli.sh leave [role] [选项]"
        echo ""
        echo "从蜂群移除角色。不指定角色时交互式选择。"
        echo ""
        echo "选项:"
        echo "  --reason <text>   移除原因"
        return 0
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reason)
                shift; reason="${1:-手动移除}"; shift
                ;;
            --*)
                die "未知选项: $1"
                ;;
            *)
                if [[ -z "$role" ]]; then
                    role="$1"
                else
                    die "多余参数: $1"
                fi
                shift
                ;;
        esac
    done

    # 无角色名：交互选择
    if [[ -z "$role" ]]; then
        local online=()
        while IFS= read -r r; do
            [[ -n "$r" ]] && online+=("$r")
        done < <(get_online_roles)

        if [[ ${#online[@]} -eq 0 ]]; then
            die "没有在线角色"
        fi

        role=$(interactive_select "选择要移除的角色:" "${online[@]}")
    fi

    log_info "移除角色: $role (原因: $reason)"
    "$SCRIPTS_DIR/swarm-leave.sh" "$role" "$force" --reason "$reason"

    echo ""
    log_ok "角色 $role 已移除"
    "$SCRIPTS_DIR/swarm-msg.sh" list-roles 2>/dev/null || true
}

# =============================================================================
# 子命令: msg（透传）
# =============================================================================

cmd_msg() {
    if [[ $# -eq 0 || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        echo "用法: swarm-cli.sh msg <子命令> [参数...]"
        echo ""
        echo "透传给 swarm-msg.sh，暴露全部消息/任务能力。"
        echo ""
        echo "常用子命令:"
        echo "  send <to> \"<content>\"        发送消息"
        echo "  reply <msg-id> \"<content>\"   回复消息"
        echo "  read                          读取收件箱"
        echo "  broadcast \"<content>\"        广播消息"
        echo "  list-roles                    列出在线角色"
        echo "  mark-read [msg-id|--all]      标记已读"
        echo "  publish <type> \"<title>\"     发布任务"
        echo "  list-tasks [选项]              列出任务"
        echo "  claim <task-id>               认领任务"
        echo "  complete-task <id> \"<result>\" 完成任务"
        echo "  pause-task <id> [reason]      暂停任务"
        echo "  resume-task <id>              恢复任务"
        echo "  cancel-task <id> [reason]     取消任务"
        echo "  group-report <group-id>       任务组汇总报告"
        echo "  set-limit [limit]             查看/设置 CLI 预算"
        echo "  wait [--from <role>]          等待消息"
        return 0
    fi

    "$SCRIPTS_DIR/swarm-msg.sh" "$@"
}

# =============================================================================
# 子命令: dag (任务依赖 DAG 可视化)
# =============================================================================

cmd_dag() {
    local workflow_file="" group_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                echo "用法: swarm-cli.sh dag [选项]"
                echo ""
                echo "生成任务依赖的 Mermaid DAG 图。"
                echo ""
                echo "选项:"
                echo "  --workflow <file>    从工作流 JSON 静态生成"
                echo "  --group <group-id>   按任务组过滤"
                echo ""
                echo "默认从 runtime/tasks/ 运行时数据生成。"
                return 0
                ;;
            --workflow)
                shift; workflow_file="${1:-}"; shift
                ;;
            --group)
                shift; group_filter="${1:-}"; shift
                ;;
            *)
                die "dag: 未知参数 $1"
                ;;
        esac
    done

    if [[ -n "$workflow_file" ]]; then
        _dag_from_workflow "$workflow_file"
    else
        _dag_from_runtime "$group_filter"
    fi
}

# 从工作流 JSON 生成 DAG
_dag_from_workflow() {
    local wf_file="$1"
    [[ -f "$wf_file" ]] || die "工作流文件不存在: $wf_file"

    echo "graph TD"

    # 样式类定义
    echo "    classDef default fill:#f9f9f9,stroke:#333,stroke-width:1px"

    # 遍历所有阶段和任务
    jq -r '
        .stages[] | .tasks[] |
        "    " + (.id | gsub("-";"_")) + "[\"" + .title + "\"]"
    ' "$wf_file"

    # 遍历依赖关系
    jq -r '
        .stages[] | .tasks[] |
        select(.depends_on != null and (.depends_on | length) > 0) |
        .id as $tid |
        .depends_on[] |
        "    " + (. | gsub("-";"_")) + " --> " + ($tid | gsub("-";"_"))
    ' "$wf_file"
}

# 从运行时数据生成 DAG
_dag_from_runtime() {
    local group_filter="$1"
    local tasks_dir="${RUNTIME_DIR}/tasks"

    echo "graph TD"

    # 样式类定义
    echo "    classDef pending fill:#f9f9f9,stroke:#999,stroke-dasharray:5 5"
    echo "    classDef processing fill:#e3f2fd,stroke:#1976d2,stroke-width:3px"
    echo "    classDef completed fill:#e8f5e9,stroke:#388e3c,stroke-width:2px"
    echo "    classDef failed fill:#ffebee,stroke:#d32f2f,stroke-width:2px"
    echo "    classDef blocked fill:#fff8e1,stroke:#f9a825,stroke-width:2px"
    echo "    classDef paused fill:#f3e5f5,stroke:#7b1fa2,stroke-dasharray:5 5"
    echo "    classDef pending_review fill:#fff3e0,stroke:#e65100,stroke-width:2px"

    local found=false

    for status_dir in pending processing completed failed blocked paused pending_review; do
        local dir="$tasks_dir/$status_dir"
        [[ -d "$dir" ]] || continue
        for f in "$dir"/task-*.json; do
            [[ -f "$f" ]] || continue

            # 按组过滤
            if [[ -n "$group_filter" ]]; then
                local gid
                gid=$(jq -r '.group_id // ""' "$f" 2>/dev/null)
                [[ "$gid" == "$group_filter" ]] || continue
            fi

            found=true
            local tid title status
            tid=$(jq -r '.id' "$f" 2>/dev/null)
            title=$(jq -r '.title // .id' "$f" 2>/dev/null)
            status=$(jq -r '.status // "pending"' "$f" 2>/dev/null)

            local safe_id="${tid//-/_}"
            echo "    ${safe_id}[\"${title}\"]"
            echo "    class ${safe_id} ${status}"

            # 输出依赖关系
            local deps
            deps=$(jq -r '.depends_on // [] | .[]' "$f" 2>/dev/null)
            if [[ -n "$deps" ]]; then
                while IFS= read -r dep; do
                    [[ -n "$dep" ]] || continue
                    local safe_dep="${dep//-/_}"
                    echo "    ${safe_dep} --> ${safe_id}"
                done <<< "$deps"
            fi
        done
    done

    if [[ "$found" == false ]]; then
        log_warn "没有找到任务数据${group_filter:+ (group: $group_filter)}"
    fi
}

# =============================================================================
# 帮助信息
# =============================================================================

show_help() {
    cat <<'HEADER'
swarm-cli.sh - 蜂群通用主控入口

HEADER
    echo -e "${C_BOLD}用法:${C_RESET} swarm-cli.sh <子命令> [参数...]"
    echo ""
    echo -e "${C_BOLD}子命令:${C_RESET}"
    echo -e "  ${C_GREEN}start${C_RESET}   <project> [profile]       启动蜂群"
    echo -e "  ${C_GREEN}stop${C_RESET}    [--clean]                 停止蜂群"
    echo -e "  ${C_GREEN}status${C_RESET}                            查看蜂群状态"
    echo -e "  ${C_GREEN}task${C_RESET}    [任务描述]                 派发任务 / 查看收件箱"
    echo -e "  ${C_GREEN}restart-codex${C_RESET}                     顺序重启在线 Codex 实例"
    echo -e "  ${C_GREEN}restart-watchdog${C_RESET}                  仅重启任务看门狗"
    echo -e "  ${C_GREEN}join${C_RESET}    [role] [选项]              动态添加角色"
    echo -e "  ${C_GREEN}leave${C_RESET}   [role] [选项]              移除角色"
    echo -e "  ${C_GREEN}msg${C_RESET}     <子命令> ...               透传消息系统命令"
    echo -e "  ${C_GREEN}dag${C_RESET}     [选项]                     任务依赖 DAG 可视化 (Mermaid)"
    echo -e "  ${C_GREEN}help${C_RESET}                               显示此帮助"
    echo ""
    echo -e "${C_BOLD}示例:${C_RESET}"
    echo "  swarm-cli.sh start ~/my-app minimal"
    echo "  swarm-cli.sh task 实现用户注册功能"
    echo "  swarm-cli.sh task backend 实现登录 API"
    echo "  swarm-cli.sh status"
    echo "  swarm-cli.sh restart-codex"
    echo "  swarm-cli.sh restart-watchdog"
    echo "  swarm-cli.sh join database --cli \"gemini\""
    echo "  swarm-cli.sh leave database --reason \"设计完成\""
    echo "  swarm-cli.sh msg send reviewer \"请 review PR #42\""
    echo "  swarm-cli.sh stop --clean"
    echo ""
    echo "每个子命令支持 --help 查看详细用法。"
}

# =============================================================================
# 主入口
# =============================================================================

EXTRA_ARGS=()

case "${1:-}" in
    start)
        shift; cmd_start "$@"
        ;;
    stop)
        shift; cmd_stop "$@"
        ;;
    status)
        shift; cmd_status "$@"
        ;;
    task)
        shift; cmd_task "$@"
        ;;
    restart-codex)
        shift; cmd_restart_codex "$@"
        ;;
    restart-watchdog)
        shift; cmd_restart_watchdog "$@"
        ;;
    join)
        shift; cmd_join "$@"
        ;;
    leave)
        shift; cmd_leave "$@"
        ;;
    msg)
        shift; cmd_msg "$@"
        ;;
    dag)
        shift; cmd_dag "$@"
        ;;
    help|--help|-h)
        show_help
        ;;
    "")
        show_help
        ;;
    *)
        die "未知子命令: $1（运行 swarm-cli.sh help 查看用法）"
        ;;
esac
