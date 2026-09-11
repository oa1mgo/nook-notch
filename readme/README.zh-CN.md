# Nook

<p align="center">
  <img src="./ic_launcher.png" alt="Nook 应用图标" width="112" />
</p>

<p align="center">
  <strong>把 MacBook 刘海变成 agent、音乐和系统状态的桌面工作层。</strong>
</p>

<p align="center">
  <a href="../README.md">English</a> ·
  <a href="https://github.com/oa1mgo/nook-notch/releases/latest">下载最新版本</a>
</p>

<p align="center">
  <img src="./img_nook_home.png" alt="Nook 主页：性能、音乐和 agent 会话" width="720" />
</p>

<p align="center">
  <img src="./img_nook_settings.png" alt="Nook 设置页" width="720" />
</p>

<p align="center">
  <img src="./img_nook_compact_music.png" alt="Nook 音乐收起态" width="225" />
  <img src="./img_nook_compact_music_artwork.png" alt="Nook 音乐信息收起态" width="225" />
  <img src="./img_nook_compact_music_glow.png" alt="Nook 带音乐光效的收起态" width="225" />
</p>

Nook 会把 MacBook notch 变成一个轻量的桌面控制层。主页集中展示 Mac 性能、音乐播放和 AI coding agent 会话，让这些状态保持可见，但不额外占用一个聊天窗口或播放器窗口。

## 主要能力

| 模块 | 功能 |
| --- | --- |
| Agent 会话 | 通过本地 hook 监控 Claude Code、Codex、OpenCode、Cursor。 |
| 会话详情 | 展示 prompt、thinking、工具调用、工具结果、审批、问题、完成状态和 token 用量。 |
| 音乐 | 展示封面、来源 App、歌曲信息、进度和播放控制，支持封面配色光晕与可选的真实音频响应。 |
| 系统状态 | 展示 CPU、内存、电池、网络概览，并提供可配置的性能详情页。 |
| 设置 | 支持屏幕选择、提示音、agent hooks、快捷键、glow、开机启动、辅助功能和独立开启的 Beta 功能入口。 |
| 外观 | 支持 Music 动态配色、macOS 26+ Glass、纯黑 Black 三种 notch 样式。 |

## Agent 支持

Nook 会把不同 agent 的本地事件整理成统一的会话时间线。

- Claude Code：hook、transcript 解析、状态追踪、中断检测、权限处理、tmux 终端聚焦。
- Codex：hook、transcript 解析、terminal approval 状态、compacting/subagent 事件、完成会话保留。
- OpenCode：事件流接入、实时工具占位、用户输入状态、subagent 追踪、idle/完成状态转换。
- Cursor：会话生命周期、processing/compacting 状态、thought/response 更新、工具调用和会话清理。

## 外观样式

设置页可以切换三种 notch 样式：

- `Music`：播放音乐时使用封面提取的动态颜色。
- `Glass`：在 macOS 26+ 且系统支持时使用 Liquid Glass。
- `Black`：保持展开面板为干净的纯黑样式。

收起状态的小 notch 保持低干扰外观；玻璃效果只作用于展开面板。

## 音乐光晕（Music Glow）

打开 `Settings` → `Music Edge Glow`，收起态 notch 周围就会出现封面配色光晕。单独开启时使用固定节奏的呼吸效果，不需要音频采集权限。

如果希望光晕响应真实音频，还需进入 `Settings` → `Beta Features...`（位于 Accessibility 下方），开启 `Audio-Reactive Music Glow`。该 Beta 选项默认关闭，主动开启时会申请 macOS 系统音频录制权限。

- 音频中的明显击打会让光晕从低亮的专辑配色底光上提亮，再回落到底光；音频分析运行时不会用固定频率补闪。
- 没有明显击打的音乐段落保持底光。暂停播放时光晕淡出并停止采集，持续静音也会让光晕熄灭。
- Beta 采集运行时，小 notch 的四条音柱展示真实音频分析结果；其余情况保留模拟动画。
- 音频仅在本机内存中实时分析，不保存录音、不上传；采集的是系统播放音频，不是麦克风输入。

关闭 Beta 后恢复无需权限的普通呼吸效果。节奏响应仍属实验功能，蓝牙设备的输出延迟目前不会自动补偿。

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
- 仅 Audio-Reactive Music Glow Beta 需要系统音频录制权限。

## 从源码构建

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug build
```

```bash
xcodebuild test -project Nook.xcodeproj -scheme Nook -configuration Debug -derivedDataPath build/TestDerivedData -destination 'platform=macOS'
```

测试说明见 [docs/testing.md](../docs/testing.md)。
音乐光晕的实现方案、回归覆盖和五种音乐风格的可复现对照见 [Music Glow 技术说明](../docs/specs/2026-09-11-music-glow-transients.md)。

## 项目结构

- `Nook/Core`：设置、几何计算、快捷键、活动优先级和视图状态。
- `Nook/Services/Hooks`：agent hook 安装和本地 Unix socket 事件接入。
- `Nook/Services/Session`：transcript 解析、状态监听和会话监控。
- `Nook/Services/State`：中心化会话状态和工具事件处理。
- `Nook/Services/Music`：音乐状态、播放控制、封面颜色，以及可选的系统音频分析、响应式光晕和音柱。
- `Nook/Services/System`：性能采样。
- `Nook/UI`：notch 外壳、会话列表、聊天详情、音乐、性能和设置界面。

## 致谢

Nook 的方向受到这些项目启发：

- [farouqaldori/claude-island](https://github.com/farouqaldori/claude-island)
- [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch)
