# Codex 权限配置速查

这是一份便于快速查看的 README 式说明，详细版见：`Codex权限配置方案.md`

## 当前目标

- 尽量少打断
- 但不要失控
- 所有 Codex 都能访问本项目 `swarmesh` 的路径

## 当前配置

配置文件：`~/.codex/config.toml`

```toml
approval_policy = "never"
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
writable_roots = ["<swarmesh 项目绝对路径>"]
```

## 这意味着什么

- 命令执行默认不弹审批
- 当前工作区默认可写
- 所有 Codex 会话额外可写本项目 `swarmesh` 目录
- 不会默认放开整台机器
- 遇到方向性或高风险改动时，仍应先确认

## 推荐理解

- `approval_policy = "never"`：解决“命令要不要先审批”
- `sandbox_mode = "workspace-write"`：解决“命令能写到哪里”

## 为什么不是 `danger-full-access`

因为当前诉求是“顺畅使用”，不是“无限制放权”。

`workspace-write` 更适合日常开发：

- 比 `danger-full-access` 安全
- 比频繁命令审批更顺畅
- 还能把额外目录加入白名单

## 如果以后要改

### 更激进

```toml
approval_policy = "never"
sandbox_mode = "danger-full-access"
```

### 更保守

```toml
approval_policy = "on-request"
sandbox_mode = "workspace-write"
```

## 一句话结论

当前方案是一个折中配置：命令尽量自动执行，写权限保持边界，方向性决策继续先确认。
