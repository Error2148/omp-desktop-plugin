# omp-desktop-plugin

一键得到和作者相同的 Tern + omp 桌面环境：Codex / Claude 桌面风格的项目与对话布局、思考链与工具调用展示、默认模型和常用偏好。

## 包含内容

| 部分 | 效果 |
|---|---|
| Tern 插件 `omp-desk` | 每个 Tern 会话是一个项目，首个标签是「项目主页」：进行中的对话、该项目的 omp 历史（点击继续）、其他项目；新对话在项目目录打开；Ctrl+C 有选中时复制、无选中时发送 ^C；文件拖进 omp 对话框直接粘贴路径 |
| Tern 偏好 | 竖排标签、新标签默认开 Agent、跟随系统主题、选中即复制、回合结束通知、8x 抗锯齿 |
| omp 显示 | 思考块显示且默认折叠、思考摘要不含代码块、工具调用折叠成一行（`compact-tools` 扩展）、状态栏思考等级图标、会话标题带图标 |
| omp 模型 | 默认 `anthropic/claude-opus-5-5`，思考强度 xhigh；smol（快速小模型）用 `anthropic/claude-haiku-5-5` |
| omp 快捷键 | `Ctrl+Shift+O` / `Alt+T` 切换工具调用显示 |

## 前置条件

- Windows + 已安装 Tern（自带 omp）；Linux/macOS 只会装 omp 部分
- 已在 omp 中登录 Anthropic（`omp login`），否则默认模型不可用

## 让 AI 自动安装（推荐）

把下面整段复制给能执行命令的 AI 助手（omp、Claude Code、Codex 等）：

```text
帮我安装 omp Desk 桌面环境（仓库：https://github.com/Error2148/omp-desktop-plugin）。按顺序执行，每步确认输出正常再继续，任何一步失败就停下，把完整报错发给我：

1. 检查环境：运行 `omp --version`，不成功就停下，提示我先安装 Tern（自带 omp）。再看系统是不是 Windows、`%APPDATA%\Tern` 目录是否存在；不满足时继续，但告诉我这次只会装 omp 部分。
2. 获取仓库，放到 `%USERPROFILE%\omp-desktop-plugin`：
   - 目录已存在：是这个仓库的 git 克隆就运行 `git pull --ff-only`，不是就停下问我。
   - 目录不存在、有 git：`git clone https://github.com/Error2148/omp-desktop-plugin.git` 到该目录。
   - 没有 git：下载 https://github.com/Error2148/omp-desktop-plugin/archive/refs/heads/main.zip，解压到 `%USERPROFILE%`，使用解压出的 `omp-desktop-plugin-main` 目录。
3. 安装：在仓库目录运行 `powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1`（非 Windows 运行 `omp sh install.sh`）。只运行这个脚本，不要手动修改任何配置文件。
4. 验证：
   - `omp config get modelRoles` 的输出包含 `"default":"anthropic/claude-opus-5-5:xhigh"`
   - Windows 下 `%APPDATA%\Tern\plugins\omp-desk\plugin.toml` 存在，`%APPDATA%\Tern\settings.json` 包含 `plugin.omp-desk.smart_copy`
5. 汇报：改了哪些东西、原文件备份在哪（脚本输出中“原文件备份在”那一行），并提醒我：完全退出再重新打开 Tern 才生效；没登录过 Anthropic 的话，在终端运行 `omp login`。
```

## 手动安装

```powershell
git clone https://github.com/Error2148/omp-desktop-plugin.git
cd omp-desktop-plugin
powershell -ExecutionPolicy Bypass -File install.ps1
```

或在任意 shell 中：`omp sh install.sh`。装完重启 Tern。

## 安装脚本会改什么

- omp：按 `omp/settings.txt` 逐项 `omp config set`，其他配置不动；`modelRoles` 只改 `default` 和 `smol`
- omp 扩展复制到 `~/.omp/agent/extensions/`，内容不同时原文件先备份为 `.bak`
- omp 快捷键按动作合并，已有的不覆盖
- Tern 插件复制到 `%APPDATA%\Tern\plugins\omp-desk`；Tern `settings.json` 按键合并（同名键以本仓库为准，包括 Ctrl+C 绑定）
- 被替换的 Tern 文件备份在 `%APPDATA%\Tern\backup-omp-desk-<时间>`

## 修改配置

增删 omp 配置只改 `omp/settings.txt`，每行一个 `键 值`。
