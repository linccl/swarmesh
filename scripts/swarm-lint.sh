#!/usr/bin/env bash
################################################################################
# swarm-lint.sh - 角色配置完整性检查
#
# 检查 config/roles/ 下角色 .md 文件是否符合规范结构。
# 用法: swarm-lint.sh [角色目录] [--verbose]
# 默认: swarm-lint.sh config/roles/
#
# 检查项:
#   [ERROR] 必须段落: 角色定位, 核心职责, 工作方式, 成功指标, 权限边界
#   [WARN]  建议段落: 关键规则, 产出模板, 行为准则, 沟通风格
#   [WARN]  YAML frontmatter 完整性检查（name, title, category）
#   [WARN]  协作工具 boilerplate 残留检测
#   [WARN]  文件大小检查
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWARM_ROOT="${SWARM_ROOT:-$(dirname "$SCRIPT_DIR")}"

# 颜色定义
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 参数解析
ROLES_DIR="${SWARM_ROOT}/config/roles"
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=true; shift ;;
        --help|-h)
            echo "用法: swarm-lint.sh [角色目录] [--verbose]"
            echo "默认检查: config/roles/"
            exit 0
            ;;
        *) ROLES_DIR="$1"; shift ;;
    esac
done

# 统计
errors=0
warnings=0
passed=0

# 必须段落
REQUIRED_SECTIONS=("角色定位" "核心职责" "工作方式" "成功指标" "权限边界")
# 建议段落
RECOMMENDED_SECTIONS=("关键规则" "产出模板" "行为准则" "沟通风格")
# 豁免管理角色（结构特殊，不强制要求所有建议段落）
EXEMPT_ROLES=("supervisor" "prd" "inspector")
# 文件行数上限
WORKER_MAX_LINES=120
MANAGEMENT_MAX_LINES=500

log_error() {
    echo -e "  ${RED}[ERROR]${NC} $1"
    errors=$((errors + 1))
}

log_warn() {
    echo -e "  ${YELLOW}[WARN]${NC}  $1"
    warnings=$((warnings + 1))
}

log_pass() {
    if $VERBOSE; then
        echo -e "  ${GREEN}[PASS]${NC}  $1"
    fi
    passed=$((passed + 1))
}

# 检查单个文件
check_file() {
    local file="$1"
    local filename
    filename=$(basename "$file" .md)
    local rel_path="${file#"$SWARM_ROOT"/}"
    local category
    category=$(basename "$(dirname "$file")")

    echo -e "${CYAN}检查${NC} $rel_path"

    local content
    content=$(cat "$file")
    local line_count
    line_count=$(wc -l < "$file" | tr -d ' ')

    # 判断是否为豁免角色
    local is_exempt=false
    for exempt in "${EXEMPT_ROLES[@]}"; do
        if [[ "$filename" == "$exempt" ]]; then
            is_exempt=true
            break
        fi
    done

    # 0. 检查 YAML frontmatter
    local has_frontmatter=false
    if echo "$content" | head -1 | grep -q "^---$"; then
        has_frontmatter=true
        local frontmatter
        frontmatter=$(echo "$content" | sed -n '2,/^---$/p' | sed '$d')
        local fm_ok=true
        for field in name title category; do
            if ! echo "$frontmatter" | grep -q "^${field}:"; then
                log_warn "frontmatter 缺少必须字段: ${field}"
                fm_ok=false
            fi
        done
        if $fm_ok; then
            local cat_val
            cat_val=$(echo "$frontmatter" | grep "^category:" | sed 's/^category:[[:space:]]*//')
            if [[ "$cat_val" != "core" && "$cat_val" != "quality" && "$cat_val" != "management" ]]; then
                log_warn "frontmatter category 值非法: ${cat_val}（应为 core/quality/management）"
            else
                log_pass "YAML frontmatter 完整"
            fi
        fi
    else
        log_warn "缺少 YAML frontmatter 块"
    fi

    # 1. 检查一级标题存在
    if echo "$content" | head -15 | grep -q "^# "; then
        log_pass "一级标题存在"
    else
        log_error "缺少一级标题（# 角色名）"
    fi

    # 2. 检查必须段落（管理角色允许"工作方式"的变体名称）
    for section in "${REQUIRED_SECTIONS[@]}"; do
        if echo "$content" | grep -q "## ${section}"; then
            log_pass "包含必须段落: ## ${section}"
        elif [[ "${section}" == "工作方式" ]] && echo "$content" | grep -qE "## (编排工作流|验收工作流|工作流程)"; then
            log_pass "包含必须段落: ## ${section}（变体）"
        else
            log_error "缺少必须段落: ## ${section}"
        fi
    done

    # 3. 检查建议段落（豁免角色跳过）
    if ! $is_exempt; then
        for section in "${RECOMMENDED_SECTIONS[@]}"; do
            if echo "$content" | grep -qE "##+ ${section}"; then
                log_pass "包含建议段落: ${section}"
            else
                log_warn "缺少建议段落: $section"
            fi
        done
    fi

    # 4. 检查协作工具 boilerplate 残留
    if echo "$content" | grep -q "## Swarm 协作工具"; then
        if ! $is_exempt; then
            log_warn "仍包含 '## Swarm 协作工具' 段落，建议精简为 '## 协作规范' 引用"
        fi
    fi

    # 5. 检查 swarm-msg.sh send 出现次数（排除豁免角色和 inspector）
    local swarm_cmd_count
    swarm_cmd_count=$(echo "$content" | grep -c "swarm-msg\.sh send" || true)
    if ! $is_exempt && [[ "$filename" != "inspector" ]]; then
        if [[ $swarm_cmd_count -gt 3 ]]; then
            log_warn "swarm-msg.sh send 出现 ${swarm_cmd_count} 次，可能有协作工具 boilerplate 残留"
        fi
    fi

    # 6. 文件大小检查
    local max_lines=$WORKER_MAX_LINES
    [[ "$category" == "management" ]] && max_lines=$MANAGEMENT_MAX_LINES

    if [[ $line_count -gt $max_lines ]]; then
        log_warn "文件 ${line_count} 行，超过上限 ${max_lines} 行"
    else
        log_pass "文件大小: ${line_count} 行 (上限 ${max_lines})"
    fi

    echo ""
}

# 主流程
echo ""
echo -e "${BOLD}=====================================${NC}"
echo -e "${BOLD} Swarm 角色配置完整性检查${NC}"
echo -e "${BOLD}=====================================${NC}"
echo "检查目录: $ROLES_DIR"
echo ""

if [[ ! -d "$ROLES_DIR" ]]; then
    echo -e "${RED}错误: 目录不存在: $ROLES_DIR${NC}"
    exit 1
fi

file_count=0

# 遍历所有子目录中的 .md 文件
while IFS= read -r -d '' md_file; do
    check_file "$md_file"
    file_count=$((file_count + 1))
done < <(find "$ROLES_DIR" -name "*.md" -type f -print0 | sort -z)

if [[ $file_count -eq 0 ]]; then
    echo -e "${YELLOW}未找到 .md 角色文件${NC}"
    exit 1
fi

# 汇总
echo -e "${BOLD}=====================================${NC}"
echo -e " 检查完成: ${BOLD}${file_count}${NC} 个文件"
echo -e " ${GREEN}通过${NC}: $passed  ${RED}错误${NC}: $errors  ${YELLOW}警告${NC}: $warnings"
echo -e "${BOLD}=====================================${NC}"

if [[ $errors -gt 0 ]]; then
    exit 1
fi
exit 0
