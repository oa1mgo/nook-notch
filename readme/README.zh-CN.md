# Nook

<p align="center">
  <img src="./ic_launcher.png" alt="Nook 应用图标" width="128" />
</p>

<p align="center">
  <strong>把 MacBook 刘海变成 AI 会话、音乐和系统状态的常驻工作层。</strong>
</p>

<p align="center">
  <a href="../README.md">English</a> ·
  <a href="https://github.com/oa1mgo/nook-notch/releases/latest">下载最新版本</a>
</p>

<p align="center">
  <img src="./img_nook_collapse.png" alt="Nook 收起态" width="720" />
</p>

<p align="center">
  <img src="./img_nook_expand.png" alt="Nook 展开态" width="720" />
</p>

Nook 会把 AI agent 的运行状态、会话详情、音乐播放和 Mac 性能信息放到 notch 里。它不是新的聊天窗口，也不是完整播放器，而是一个轻量、持续在线、随时可展开的桌面状态层。

## 功能亮点

| 模块 | 能力 |
| --- | --- |
| AI agent | 支持 Claude Code、Codex、OpenCode、Cursor 的本地会话监控。 |
| 会话详情 | 展示 prompt、thinking、工具调用、工具结果、审批、问题和完成状态。 |
| 音乐 | 展示封面、来源 App、歌曲信息、进度、拖动 seek、播放暂停、上一首/下一首。 |
| 性能 | 展示 CPU、内存、电池、网络概览，并提供可配置指标和详情页。 |
| 外观 | 可在 Music 动态配色、macOS 26+ Glass、纯黑 Black 三种样式间切换。 |
| 设置 | 屏幕选择、提示音选择、快捷键、开机启动、辅助功能入口、各 agent hook 开关。 |

## Agent 支持

Nook 通过本地 hook 和 socket 接收事件，然后统一整理成会话时间线。

- Claude Code：hook 安装、状态追踪、transcript 解析、中断检测、tmux 聚焦辅助。
- Codex：hook 安装、transcript 解析、terminal approval 状态、compacting/subagent 事件、完成会话保留。
- OpenCode：事件流接入、实时工具占位、idle/完成状态转换。
- Cursor：处理 processing、compacting、完成和 session end 清理。

展开后可以看到会话列表、provider 标识、状态、工作目录；进入会话后可以查看接近聊天记录的详情，而不需要频繁切回终端。

## 音乐与性能

当 agent 没有关键状态时，Nook 可以切到音乐或性能信息。

- 音乐卡片：封面、歌名、歌手、专辑、进度、键盘控制和播放按钮。
- 动态配色：Music 样式会从封面提取颜色，生成展开态背景。
- 边缘光效：播放音乐时可以开启独立的进度边缘 glow。
- 性能概览：主页展示 CPU、内存、电池、网络的快速状态。
- 性能详情：支持 CPU、内存、电池、网络、进程、网络接口等详情页。

## 外观样式

设置里可以选择三种 notch 样式：

- Glass：macOS 26+ 上的系统 Liquid Glass 效果。
- Music：有音乐封面时使用动态封面配色，没有音乐时回退到黑色。
- Black：无背景色的纯黑样式。

收起状态的小 notch 保持安静的黑色外观；玻璃效果只作用于展开面板，避免收起态显得突兀。

## 安装

1. 从 [Releases](https://github.com/oa1mgo/nook-notch/releases/latest) 下载最新 `Nook.dmg`。
2. 将 `Nook.app` 拖入 `Applications`。
3. 从 `Applications` 打开 `Nook`。

如果 macOS 首次启动时拦截，可以到 `系统设置` -> `隐私与安全性` 中允许 Nook 运行，然后重新打开。

## 环境要求

- macOS 15.6 或更高版本。
- Glass 外观需要 macOS 26 或更高版本。
- 需要安装 Claude Code、Codex、OpenCode 或 Cursor，才能启用对应 agent 集成。
- 建议开启辅助功能权限，用于全局快捷键和窗口聚焦相关能力。

## 从源码构建

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug build
```

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS'
```

测试覆盖说明见 [docs/testing.md](../docs/testing.md)。

## 项目结构

- `Nook/App`：应用生命周期、菜单栏/窗口创建、屏幕变化监听、单实例处理。
- `Nook/Core`：设置、几何计算、快捷键、活动优先级和视图状态。
- `Nook/Services/Hooks`：agent hook 安装和本地 Unix socket 事件接入。
- `Nook/Services/Session`：transcript 解析、状态监听和会话监控。
- `Nook/Services/State`：中心化会话状态和工具事件处理。
- `Nook/Services/Music`：音乐状态、播放控制和封面颜色提取。
- `Nook/Services/System`：性能采样。
- `Nook/UI`：notch 外壳、会话列表、聊天详情、音乐、性能和设置界面。

## 致谢

Nook 的方向受到这些项目启发：

- [farouqaldori/claude-island](https://github.com/farouqaldori/claude-island)
- [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch)
