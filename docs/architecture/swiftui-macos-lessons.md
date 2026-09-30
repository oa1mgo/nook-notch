# Architecture Lessons — SwiftUI + macOS

> 跨项目普适的架构教训,源自 Nook 实际踩过的坑。每条都是"为什么不能这样写"的根因,不是"应该怎么写"的具体实现(具体实现看对应 spec)。

## 1. 不要用 layout 测量反推自身尺寸

> **教训**:如果一个 view 的"应该多大"可以从数据推出来,**从数据推**,不要用 GeometryReader 反馈回路。
> **关联**: `docs/specs/2026-07-01-picker-panel-height-redesign.md`(picker panel 高度数据驱动改造)

### 为什么

测量 = 几何求值,是 layout 的**结果**;尺寸 = 数据驱动,是 layout 的**输入**。本末倒置 = 不可预测的时机 + 不可靠的边界。

### 失败模式

`VStack 自然高度 → GeometryReader → onPreferenceChange → @Published state → 重新计算 parent size → 重新 layout`

SwiftUI 不保证 measurement 时机、不保证 preference 在哪一帧 fire、不保证 animation 从哪一帧开始。任何一环时序错位都导致闪烁或 stale state。

### 正确做法

- Panel 高度 = `Σ (每个 picker 声明的 expandedHeight) + 静态行高度 + header`。所有数字是编译期常量,从数据(`isExpanded` state)推出,跳过测量。
- Picker 自己的 `frame(height:)` 用 `withTransaction(\.disablesAnimations)` 瞬时设置,不要动画这段高度。
- 视觉动画用 opacity / scale,不动 frame(动 frame = 触发测量 = 时序不可控)。

## 2. 任何 `GeometryReader → onPreferenceChange → @Published state` 回路都有闪烁风险

> **教训**:SwiftUI 的 preference 在哪一帧 fire 不保证,measurement 在哪个 layout pass 出现不保证,这两个组合在一起**必然**有时序错位。
> **关联**: 同 #1,scrollbar flicker 9 次修复经验(详见 `docs/specs/2026-07-01-picker-panel-height-redesign.md` "9 次修复时间线")

### 失败模式

9 次修复的共同结构就是这个回路。每一层(动画曲线 / 同步预测 / disablesAnimations / keyboard 同步 / buffer)都在修一个症状,根因(回路本身)没动过。

### 诊断方法

看到"view 闪烁 + 高度变化 + 在 onPreferenceChange 里写状态"的组合,**先怀疑回路本身**,不要打补丁。打补丁能撑几个版本,SwiftUI 内部行为变化(每个 macOS 版本都有)就破。

### 正确做法

见 #1。**取消回路**,不要优化回路。

## 3. macOS NSScroller 的 gutter 保留行为是方向敏感的

> **教训**:buffer 不是几何问题,是平台行为问题。`contentSize` 接近 `visibleSize` 时 NSScroller 主动保留 gutter,且**方向敏感**。
> **关联**: 同 #1,#2

### 行为

- 内容向 visible area **增长**时保留 gutter(防溢出闪)。
- 内容向 visible area **收缩**时**不**保留。

实测阈值在 12-16pt 之间,**具体值不公开也测不准**。16pt 是当前架构下唯一可靠的 buffer 值。任何更小的值都可能偶尔闪 gutter。

### 失败模式

写"contentSize < visibleSize - 2pt scrollbar 就消失"。数学上对,但**方向不敏感**就必然闪。`overflow = -2pt` 时 expand 方向 NSScroller 仍保留 gutter(虽然 threshold 之上),collapse 方向不保留 → 宽度突变 → "咣"一下。

### 真正根治

**不是调 buffer 大小**。buffer 只是兜底,治本需要取消 GeometryReader 反馈回路(见 #1,#2),让 `contentSize == visibleSize` 在数学上恒等(用编译期 row height 公式)。

### 如果只能 buffer

16pt 兜底是当前架构下的 trade-off。14pt 视觉距离换稳定 + 零闪烁。如果用户能接受更小的视觉距离,可以试 12pt 或 8pt,**实测不一定复现**。**不要**凭"buffer 越大越好"无脑往上加 — 加到 100pt panel 直接被屏幕 cap 掉(13" MacBook ~900pt window),更糟。

## 4. 时间门控(time-based gating)能挡动画窗口内的 in-flight broadcast,但不要滥用

> **教训**:广播(broadcast)在动画窗口内的中间值不可信,需要时间门控拦截。但门控**只能**挡广播,**不能**修 picker 自己的状态。
> **关联**: `docs/specs/2026-07-07-picker-height-and-broadcast-pattern.md`

### 失败模式

picker 的 `frame(height:)` 动画 0.2s 内,documentView 的 frame 会经过中间值(771 → 770 → 659 → 597)。广播 timer(10Hz)在动画途中会采集一个"几乎等于旧高度"的瞬时值。如果直接写回 @Published state,会覆盖刚写下的编译期值,导致 panel 停在错误高度。

### 正确做法

picker 状态变化的处理函数**第一行**调 `markExplicitSet()` 记录时间戳,广播 handler **第二行**用 `pickerAnimationGuard`(0.3s)门控,门控外的广播才走收敛检测。

### 不要滥用

时间门控**只**用于拦截"广播 vs 编译期值"的覆盖冲突。**不要**用时间门控代替确定性重置(viewModel navigation API 的 EXIT 路径重置)。确定性重置是"进入 X 前先把 Y 清掉",时间门控是"刚改完 X 等 0.3s"。前者更可靠,只在确定性做不到时(time-sensitive 路径)才用后者。

## 5. 单点真相(SOI)比重复正确更重要

> **教训**:同一公式在 N 个地方写 N 次,后人改定义时漏一处就回到老 bug。**抽 helper** 比"写对注释"更可靠。
> **关联**: header 高度 helper 抽取(`SettingsPageLayout.swift` `settingsPageHeaderHeight(for:)`)

### 失败模式

`let xxx = 24` 写在某个文件,后来 N 个地方都重复这个 magic number。改定义时改了 N-1 处,漏 1 处 → 1pt / 2px / 0.87pt 不一致 bug,极难定位。

### 正确做法

任何**有跨文件使用场景**的常量(特别是"从数据 X 派生的数字"),抽成 `func deriveFromX(_ x: X) -> CGFloat`。函数比常量更可靠 — 调用方必须显式传依赖,IDE 跳转能直接找到所有调用点。

### 例外

- 真正意义的"全局 magic number"(比如设计 token、颜色),放常量文件正常。
- 跨文件但只在一个 case 用的(比如某个 fix 的 16pt buffer),可以就地写但加注释。
- **跨文件 + 多处使用 + 从其他数据派生** → 必须抽函数。

## 6. 跨进程/跨语言的兼容性矩阵必须单独建档

> **教训**:opencode plugin ↔ adapter ↔ opencode 上游之间的事件兼容性矩阵,光在 adapter 注释里写会被淹没。**单独建档**,顶部注释指过去。
> **关联**: `docs/specs/2026-06-17-opencode-v1.17-compatibility-matrix.md`

### 失败模式

adapter 顶部注释有事件列表,各 handler 注释有细节。但"v1.15.13 测过什么 / v1.17.x 测过什么 / 哪个事件哪个版本不消费"这种**矩阵视图**散在 N 处。新人遇到"opencode 升级到 v1.18.x,会不会炸"的问题,找不到汇总点。

### 正确做法

- 一张表(行=事件,列=版本,单元格=✅/❌/未测试)
- "已知陷阱"小节:每个陷阱单独一段,讲清"症状 → 根因 → 兜底"
- Adapter 顶部 docstring 只放 1 行指针 + 概要

### 同步策略

spec 是 single source of truth,adapter 注释是"实现说明"。两者脱节时以 spec 为准(更新 adapter 注释)。**不要**两边各写各的版本号 — 改一边忘改另一边比 bug 还烦。

## 7. Bug 调查的"复现条件 + 诊断 log 用法"必须单独建档

> **教训**:bug 调查的根因分析 + 诊断 log 用法,如果只写在代码 TODO 注释里,bug 不再触发后会被忘干净。**单独建档** + 在 TODO 注释里指过去。
> **关联**: `docs/debug/2026-06-23-bug-j-reasoning-flush.md`

### 失败模式

adapter 里有 `// TODO(#82): keep this log until Bug J's root cause is fully understood`,但"root cause"在哪行代码 / 哪些版本复现 / 诊断 log 怎么用 / 兜底方案是什么,全在 PROGRESS.md 或开发者脑子里。

半年后 PROGRESS 滚动归档,TODO 还在但没人记得为什么。**新人遇到类似症状不知道 grep 哪个 log、哪个 messageID 是关键、改哪段代码**。

### 正确做法

- 单独 `docs/debug/<date>-<bug-name>.md`
- 4 节必备:① 症状(用户视角);② 根因(代码/上游定位,带行号);③ 复现条件(什么场景触发);④ 诊断 log 用法(grep 什么 / 出现 → 意味着什么 / 没出现 → 意味着什么)
- 代码 TODO 注释里加 1 行指针 + 概要

---

**维护策略**:这 7 条是 Nook 实战踩出来的,不是教科书。建议每个新加入的 SwiftUI/macOS 项目都过一遍这 7 条,挑项目里中枪的 1-2 条放 AGENTS.md 或 README。