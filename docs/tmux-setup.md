# tmux 配置说明

本文档描述本项目推荐的 tmux 本机配置，重点覆盖以下场景：

- tmux pane 内使用鼠标滚动
- tmux 复制内容到系统剪贴板
- macOS 与 Ubuntu 的差异配置

## 通用最小配置

如果你只需要在 tmux pane 里启用鼠标滚动，`~/.tmux.conf` 至少加上：

```tmux
set -g mouse on
```

这会启用：

- 鼠标滚轮滚动 pane 历史输出
- 鼠标选中 pane
- 鼠标拖拽进入 copy-mode

修改后重新加载：

```bash
tmux source-file ~/.tmux.conf
```

临时对当前 tmux server 生效：

```bash
tmux set -g mouse on
```

## macOS 推荐配置

macOS 可以直接使用 `pbcopy` 对接系统剪贴板。

推荐 `~/.tmux.conf`：

```tmux
set -g mouse on
set -s copy-command 'pbcopy'

bind-key -T copy-mode-vi Enter send-keys -X copy-pipe-and-cancel "pbcopy"
bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "pbcopy"
bind-key -T copy-mode Enter send-keys -X copy-pipe-and-cancel "pbcopy"
bind-key -T copy-mode MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "pbcopy"
```

说明：

- `set -g mouse on` 负责鼠标滚动与拖拽
- `pbcopy` 负责把 copy-mode 里的内容写入 macOS 剪贴板
- 上述配置同时兼容 `copy-mode` 和 `copy-mode-vi`

## Ubuntu 推荐配置

Ubuntu 需要按图形协议选择剪贴板命令。

### Ubuntu X11

先安装：

```bash
sudo apt-get update
sudo apt-get install -y xclip
```

推荐 `~/.tmux.conf`：

```tmux
set -g mouse on
set -s copy-command 'xclip -selection clipboard -in'

bind-key -T copy-mode-vi Enter send-keys -X copy-pipe-and-cancel "xclip -selection clipboard -in"
bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "xclip -selection clipboard -in"
bind-key -T copy-mode Enter send-keys -X copy-pipe-and-cancel "xclip -selection clipboard -in"
bind-key -T copy-mode MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "xclip -selection clipboard -in"
```

### Ubuntu Wayland

先安装：

```bash
sudo apt-get update
sudo apt-get install -y wl-clipboard
```

推荐 `~/.tmux.conf`：

```tmux
set -g mouse on
set -s copy-command 'wl-copy'

bind-key -T copy-mode-vi Enter send-keys -X copy-pipe-and-cancel "wl-copy"
bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "wl-copy"
bind-key -T copy-mode Enter send-keys -X copy-pipe-and-cancel "wl-copy"
bind-key -T copy-mode MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "wl-copy"
```

### Ubuntu 兼容兜底

如果不确定当前是 X11 还是 Wayland，可以先只开鼠标滚动：

```tmux
set -g mouse on
```

剪贴板命令按机器环境补充，不要把 macOS 的 `pbcopy` 直接抄到 Ubuntu。

## 如何判断当前应该用哪套配置

在 Ubuntu 下：

```bash
echo "$XDG_SESSION_TYPE"
```

常见结果：

- `x11`：优先用 `xclip`
- `wayland`：优先用 `wl-copy`

## 验证方法

加载配置后，执行：

```bash
tmux show -g mouse
```

预期输出类似：

```text
mouse on
```

然后做两步人工验证：

1. 在 tmux pane 内用鼠标滚轮向上滚动，确认可以查看历史输出
2. 用鼠标拖拽选择文本，确认 copy-mode 能正常工作

如果配置了剪贴板命令，再验证：

- macOS：拖拽复制后用 `pbpaste` 检查
- Ubuntu X11：拖拽复制后用 `xclip -o -selection clipboard` 检查
- Ubuntu Wayland：拖拽复制后用 `wl-paste` 检查

## 与本项目的关系

本项目基于 tmux 管理多个 AI CLI pane。推荐至少启用：

```tmux
set -g mouse on
```

这样在多蜂群、多 pane 场景下更容易：

- 回看角色历史输出
- 手动定位某个 pane
- 复制角色结果进行核对

这属于本机体验配置，不是项目运行必需项；但在日常使用中强烈建议开启。
