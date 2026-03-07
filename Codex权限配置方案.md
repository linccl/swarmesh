# Codex 权限配置方案

## 背景

目标是让 Codex 在日常使用时尽量少打断，但又不要失控：

- 命令执行尽量自动化，不再频繁弹出命令审批。
- 写入范围保持可控，避免默认放开整台机器。
- 对任务方向、改动范围、潜在风险较高的事项，仍然先和用户确认。
- 所有 Codex 会话都能额外访问本项目 `swarmesh` 的路径。

## 已落地的全局配置

配置文件位置：`~/.codex/config.toml`

已写入的核心配置如下：

```toml
approval_policy = "never"
sandbox_mode = "workspace-write"
developer_instructions = """
- Execute routine shell and file operations without asking for approval when the active sandbox allows it.
- Before changing task direction or scope, stop and ask the user for confirmation in Chinese if the work introduces a new feature or module, is likely to touch more than 3 files, changes architecture, dependencies, build scripts, CI, database, auth, security, or production configuration, deletes files, performs a large refactor, or could be destructive or hard to roll back.
- For small, clearly scoped requests, proceed directly.
"""

[sandbox_workspace_write]
writable_roots = ["<swarmesh 项目绝对路径>"]
```

## 配置含义

### 1. 命令执行不再弹审批

`approval_policy = "never"` 的作用是：

- Codex 执行命令时默认不再弹出审批。
- 只要命令本身在当前沙箱权限内，就直接执行。

这解决的是“命令能不能直接跑”的问题。

## 2. 默认不放开整机，而是受控写入

`sandbox_mode = "workspace-write"` 的作用是：

- 当前工作区默认可写。
- 额外允许写入 `writable_roots` 中列出的目录。
- 不会像 `danger-full-access` 那样默认对整台机器开放写权限。

这解决的是“命令可以写到哪里”的问题。

## 3. 所有 Codex 会话都能访问本项目 `swarmesh` 目录

通过以下配置：

```toml
[sandbox_workspace_write]
writable_roots = ["<swarmesh 项目绝对路径>"]
```

实现的效果是：

- 无论从哪个目录启动 Codex，当前工作区仍然可写。
- 额外允许所有 Codex 会话写入本项目 `swarmesh` 的实际绝对路径。

## 4. 保留“方向性确认”

`developer_instructions` 中增加了全局约束，让 Codex 在以下情况先用中文确认，再继续执行：

- 引入新功能或新模块
- 预计改动超过 3 个文件
- 涉及架构调整
- 修改依赖、构建脚本、CI、数据库、认证、权限、安全、生产配置
- 删除文件
- 大范围重构
- 可能难以回滚或带破坏性的操作

这不是系统级命令审批弹窗，而是模型行为约束。

也就是说：

- 小而明确的任务，直接执行。
- 方向性、范围性、风险性问题，先询问用户。

## 为什么选择这套方案

这套方案在“少打断”和“别失控”之间做了折中：

- 比 `approval_policy = "on-request"` 更顺畅，避免频繁弹命令审批。
- 比 `sandbox_mode = "danger-full-access"` 更安全，不默认放开整机。
- 比纯粹依赖人工审批更高效，但仍保留高风险任务的确认机制。

## 当前生效范围

这是 Codex 的全局配置，不是单仓库配置，因此会影响后续新启动的 Codex 会话。

需要注意：

- 已经打开的旧会话通常不会自动加载新配置。
- 重启 Codex 后，新配置才会稳定生效。

## 行为预期

配置完成后，Codex 的默认行为应为：

- 在允许写入的范围内，命令默认直接执行。
- 当前工作区始终可写。
- 本项目 `swarmesh` 的实际绝对路径对所有 Codex 会话都可写。
- 超出上述范围的写操作会失败，而不是自动获得更高权限。
- 涉及方向调整或高风险改动时，先询问用户。

## 如果以后要调整

### 更激进

如果以后希望彻底放开整机权限，可以改成：

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

风险会明显升高，不建议长期默认使用。

### 更保守

如果以后希望恢复命令审批，可以把：

```toml
approval_policy = "never"
```

改回例如：

```toml
approval_policy = "on-request"
```

## 回滚方式

如需回滚，只需编辑 `~/.codex/config.toml`，撤销以下几类配置：

- `approval_policy = "never"`
- `sandbox_mode = "workspace-write"`
- `developer_instructions = """ ... """`
- `[sandbox_workspace_write]` 与对应的 `writable_roots`

## 结论

当前方案的核心原则是：

- 命令执行默认不打断
- 写入权限保持边界
- 方向性决策继续先确认
- `swarmesh` 目录对所有 Codex 会话全局可写

这是目前比较适合日常开发的折中配置。
