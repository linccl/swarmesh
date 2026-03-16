#!/usr/bin/env bash
# swarm-send.sh - 向指定角色派发任务
# 解析角色别名,创建任务记录,并通过 tmux send-keys 发送到对应 pane
#
# 用法: swarm-send.sh <role> <task>
#   role: 角色名称、别名或索引 (如 frontend, fe, 0)
#   task: 任务内容

set -euo pipefail

# =============================================================================
# 配置参数 (可通过环境变量覆盖)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/swarm-lib.sh"

# 获取 Unix 时间戳（swarm-lib.sh 未提供此函数）
get_unix_timestamp() {
    date +%s
}

# =============================================================================
# 参数解析
# =============================================================================

if [[ $# -lt 2 ]]; then
    cat <<EOF
用法: $(basename "$0") <role> <task>

参数:
  role  角色名称、别名或索引
        - 角色名: frontend, backend, reviewer
        - 别名:   fe, be, rv
        - 索引:   0, 1, 2

  task  任务内容 (建议用引号包裹)

示例:
  $(basename "$0") frontend "实现登录页面"
  $(basename "$0") fe "添加表单验证"
  $(basename "$0") 0 "修复 Bug #123"

环境变量:
  SWARM_ROOT    Swarm 根目录 (默认: 脚本所在目录的父目录)
  SESSION_NAME  Tmux session 名称 (默认: swarm)
EOF
    exit 1
fi

ROLE_INPUT="$1"
TASK_CONTENT="$2"

# =============================================================================
# 前置检查
# =============================================================================

log_info "准备派发任务..."

# 检查必需工具
check_command tmux
check_command jq

# 检查 session 是否存在
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    die "Session '$SESSION_NAME' 不存在,请先启动 swarm (swarm-start.sh)"
fi

# 检查状态文件是否存在
[[ -f "$STATE_FILE" ]] || die "状态文件不存在: $STATE_FILE"

# =============================================================================
# 读取状态并解析角色映射
# =============================================================================

log_info "读取运行状态: $STATE_FILE"

STATE_JSON=$(cat "$STATE_FILE")

# 检查 panes 数组
PANES_JSON=$(echo "$STATE_JSON" | jq -c '.panes // []')
PANES_COUNT=$(echo "$PANES_JSON" | jq 'length')

[[ $PANES_COUNT -eq 0 ]] && die "状态文件中没有 pane 信息"

log_info "当前活动角色数: $PANES_COUNT"

# =============================================================================
# 解析角色到 Pane 的映射
# =============================================================================

log_info "解析角色: $ROLE_INPUT"

TARGET_ROLE=""
TARGET_PANE=""
TARGET_CLI=""
TARGET_INSTANCE=""

# 尝试匹配角色/实例
for ((i=0; i<PANES_COUNT; i++)); do
    ROLE=$(echo "$PANES_JSON" | jq -r ".[$i].role")
    INSTANCE=$(echo "$PANES_JSON" | jq -r ".[$i].instance // .[$i].role")
    PANE=$(echo "$PANES_JSON" | jq -r ".[$i].pane")
    CLI=$(echo "$PANES_JSON" | jq -r ".[$i].cli")
    ALIAS=$(echo "$PANES_JSON" | jq -r ".[$i].alias // \"\"")

    # 匹配规则:
    # 1. 实例名完全匹配
    # 2. 角色名完全匹配
    # 3. 别名匹配
    # 4. 索引匹配

    if [[ "$ROLE_INPUT" == "$INSTANCE" ]] || \
       [[ "$ROLE_INPUT" == "$ROLE" ]] || \
       [[ -n "$ALIAS" && "$ROLE_INPUT" == "$ALIAS" ]] || \
       [[ "$ROLE_INPUT" == "$i" ]]; then
        TARGET_ROLE="$ROLE"
        TARGET_PANE="$PANE"
        TARGET_CLI="$CLI"
        TARGET_INSTANCE="$INSTANCE"
        log_success "匹配成功: $INSTANCE (角色: $ROLE, pane: $TARGET_PANE)"
        break
    fi
done

# 检查是否找到匹配
if [[ -z "$TARGET_ROLE" ]]; then
    log_error "无法匹配角色/实例: $ROLE_INPUT"
    echo ""
    echo "可用实例:"
    for ((i=0; i<PANES_COUNT; i++)); do
        ROLE=$(echo "$PANES_JSON" | jq -r ".[$i].role")
        INSTANCE=$(echo "$PANES_JSON" | jq -r ".[$i].instance // .[$i].role")
        PANE=$(echo "$PANES_JSON" | jq -r ".[$i].pane")
        ALIAS=$(echo "$PANES_JSON" | jq -r ".[$i].alias // \"\"")
        if [[ -n "$ALIAS" ]]; then
            echo "  [$i] $INSTANCE (角色: $ROLE, 别名: $ALIAS) -> $PANE"
        else
            echo "  [$i] $INSTANCE (角色: $ROLE) -> $PANE"
        fi
    done
    exit 1
fi

# =============================================================================
# 创建任务记录
# =============================================================================

log_info "创建任务记录..."

# 生成任务 ID
TASK_ID="task-$(get_unix_timestamp)-$$-${RANDOM}"

# 加载项目配置以获取 TASK_MAX_RETRIES
load_project_config 2>/dev/null || log_warn "load_project_config 失败，使用默认配置"
# 确保 TASK_MAX_RETRIES 是整数
TASK_MAX_RETRIES=$(( ${TASK_MAX_RETRIES:-3} + 0 )) 2>/dev/null || TASK_MAX_RETRIES=3

# 创建任务 JSON（与 cmd_publish 结构对齐，确保看门狗可监管）
TASK_JSON=$(jq -n \
    --arg id "$TASK_ID" \
    --arg type "direct" \
    --arg from "human" \
    --arg role "$TARGET_ROLE" \
    --arg instance "$TARGET_INSTANCE" \
    --arg pane "$TARGET_PANE" \
    --arg title "$TASK_CONTENT" \
    --arg description "$TASK_CONTENT" \
    --arg created_at "$(get_timestamp)" \
    --arg status "pending" \
    --argjson max_retries "${TASK_MAX_RETRIES:-3}" \
    '{
        id: $id,
        type: $type,
        from: $from,
        role: $role,
        pane: $pane,
        title: $title,
        description: $description,
        assigned_to: $instance,
        created_at: $created_at,
        status: $status,
        claimed_by: null,
        claimed_at: null,
        completed_at: null,
        result: null,
        priority: "normal",
        group_id: "",
        depends_on: [],
        blocked: false,
        verify: null,
        retry_count: 0,
        max_retries: $max_retries,
        failed_at: null,
        fail_reason: null,
        retry_history: [],
        parent_task: null,
        subtasks: [],
        split_status: null,
        depth: 0
    }')

# 保存任务到 pending 目录
PENDING_FILE="$TASKS_DIR/pending/$TASK_ID.json"
echo "$TASK_JSON" | jq '.' > "$PENDING_FILE"

log_success "任务记录创建: $PENDING_FILE"

# =============================================================================
# 发送任务到 Pane
# =============================================================================

log_info "发送任务到 pane: $SESSION_NAME:$TARGET_PANE"

# 使用原子发送（flock + 命名 buffer + paste-buffer + Enter）
# 原因: send-keys 逐字符发送时，某些 CLI TUI（如 Claude Code）
#        无法正确处理后续的 Enter 键提交。paste-buffer 一次性粘贴可避免此问题。
# flock 防止并发发送同一 pane 时消息交错。
SEND_TMP=$(mktemp "${RUNTIME_DIR}/.send-XXXXXX")
printf '%s' "$TASK_CONTENT" > "$SEND_TMP"
if ! _pane_locked_paste_enter "$TARGET_PANE" "$SEND_TMP"; then
    rm -f "$SEND_TMP"
    die "任务发送失败: pane=$TARGET_PANE role=$TARGET_ROLE"
fi
rm -f "$SEND_TMP"

# 等 pipe-pane 将输入文本刷入日志，确保偏移量跳过输入
sleep 0.5

# 记录日志偏移量（此时偏移量在输入之后、响应之前）
TARGET_LOG="$RUNTIME_DIR/logs/$TARGET_ROLE.log"
LOG_OFFSET=0
[[ -f "$TARGET_LOG" ]] && LOG_OFFSET=$(wc -c < "$TARGET_LOG" | tr -d ' ')

log_success "任务已发送"

# 发射任务发送事件
emit_event "task.sent" "$TARGET_ROLE" "task_id=$TASK_ID" "pane=$TARGET_PANE" "log_offset=$LOG_OFFSET"

# =============================================================================
# 更新任务状态
# =============================================================================

log_info "更新任务状态: pending -> processing"

# 移动任务文件
PROCESSING_FILE="$TASKS_DIR/processing/$TASK_ID.json"

# 更新状态字段（补齐 claimed_by/claimed_at 供看门狗监管）
UPDATED_TASK_JSON=$(echo "$TASK_JSON" | jq \
    --arg status "processing" \
    --arg sent_at "$(get_timestamp)" \
    --arg claimed_by "$TARGET_INSTANCE" \
    --arg claimed_at "$(get_timestamp)" \
    '. + {status: $status, sent_at: $sent_at, claimed_by: $claimed_by, claimed_at: $claimed_at}')

echo "$UPDATED_TASK_JSON" | jq '.' > "$PROCESSING_FILE"
rm -f "$PENDING_FILE"

log_success "任务状态已更新"

# =============================================================================
# 输出任务信息
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "任务派发成功!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "任务 ID:    $TASK_ID"
echo "目标角色:   $TARGET_ROLE"
echo "目标 Pane:  $TARGET_PANE"
echo "CLI:        $TARGET_CLI"
echo "发送时间:   $(get_timestamp)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "任务内容:"
echo "$TASK_CONTENT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "跟踪任务:"
echo "  查看输出:   swarm-read.sh $TARGET_ROLE"
echo "  查看日志:   tail -f $RUNTIME_DIR/logs/$TARGET_ROLE.log"
echo "  查看状态:   cat $PROCESSING_FILE | jq"
echo ""
