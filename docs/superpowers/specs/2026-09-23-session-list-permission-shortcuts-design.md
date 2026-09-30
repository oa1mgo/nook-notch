# Session List Permission Y/N/A Shortcuts

**Date:** 2026-09-23
**Status:** Approved

## Summary

给 instances 页（`SessionListView`）的行内审批按钮（`InlineApprovalButtons`）加键盘快捷键 **Y/N/A + C/Esc**，与 chat 页 `ChatApprovalBar` 键位完全一致。目标解析规则（用户确认）：

- keyboard-target 数量 **0** → 不响应（事件放行）
- **1** → 免高亮，直接打那一个（无论 `keyboardSelectedIndex` 在哪）
- **≥2** → 必须高亮行本身是 target 才打高亮行，否则不响应

**键位决策**：沿用 Y/N/A（chat 页已上线），不采用 `2026-07-10` spec 里从未实现的 ⌘↩/⌘⌫ 规划（该行随本实现更新划掉）。

## Goals

- 列表页单 pending permission 时，按一下 Y/N 即可审批，无需 ⌃N/导航
- 多 pending 时强制显式选中，杜绝误批
- Always 二段确认（A → Confirm(C)/Cancel(Esc)）与 chat 页心智一致
- 按钮加键帽提示 `(N)/(Y)/(A)/(C)/(Esc)`，两页视觉一致
- 零改动：`ShortcutManager` / `ShortcutBindings` / `ShortcutAction` / `NotchViewModel` 触发器体系

## Non-Goals

- 不做 ⌘↩/⌘⌫；不做可配置绑定（不进 settings）
- 不改 permission auto-expand 路径（仍直接 push chat 页，绕过列表）
- 不修 `keyboardSelectedIndex` 在导航 EXIT 未重置的既有问题（已知，另记）
- question（`waitingForInput`）不接 Y/N/A——⌃R 已覆盖
- terminal/interactive 审批行（只有 Go to Terminal 按钮）不算 target

## Design

### 1. SOI：keyboard-target 判定（`SessionListView.swift`）

单一来源函数，渲染与键盘共用（跨分支条件禁止两处内联）：

```swift
extension SessionState {
    /// SOI: row renders InlineApprovalButtons — keyboard Y/N/A target.
    /// Mirrors InstanceRow action-area branch (SessionListView.swift
    /// `isWaitingForTerminalApproval || (... && isInteractiveTool)` first,
    /// then approval buttons). Keep both in sync when either changes.
    ///
    /// Premise: `phase.isWaitingForApproval` matches ONLY
    /// `.waitingForApproval` (SessionPhase.swift L266-269) — terminal-side
    /// `.waitingForTerminalApproval` is a different case and is NOT
    /// included. Targets do not pass through InstanceRow's else-if chain,
    /// so this exclusivity is what keeps terminal-approval rows out of the
    /// keyboard target set. Do not "merge" the two phase helpers.
    var showsInlineApprovalButtons: Bool {
        guard phase.isWaitingForApproval else { return false }
        if let tool = pendingToolName, ToolCallItem.kind(of: tool) == .askUserQuestion {
            return false // branch 1: Go to Terminal, not Y/N/A
        }
        return true
    }

    /// Always button exists only for OpenCode (mirrors onApproveAlways wiring at L195).
    var canApproveAlways: Bool { showsInlineApprovalButtons && provider == .opencode }
}
```

`InstanceRow` 动作区 branch 2 条件由 `else if isWaitingForApproval` 改为 `else if session.showsInlineApprovalButtons`（branch 1 保持不动；对 `waitingForApproval` 行二者等价——branch 1 已拦掉 interactive）。

键盘 target 列表 = `sortedInstances.filter(\.showsInlineApprovalButtons)`（与屏幕排序一致，count 语义 = 可见可批行数）。

### 2. 触发规则（`handleKeyDown`）

| targets.count | 行为 |
|---|---|
| 0 | `return event` 放行，无 beep |
| 1 | 打 `targets[0]`，忽略高亮 |
| ≥2 | 高亮行 ∈ targets → 打它；否则 `return event` |

- 歧义已确认：count==1 且高亮在别的行 → **仍批唯一 target**
- `keyboardSelectedIndex == -1` 是无高亮哨兵（NotchViewModel.swift L118）。≥2 分支取高亮行前必须 `guard idx >= 0, idx < sortedInstances.count`（照 L217/L224 同款），越界/无高亮 = 不响应

### 3. 键位

| 键 | 动作 | 复用 |
|---|---|---|
| `Y` | Allow | `approveSession(target)`（L251） |
| `N` | Deny | `rejectSession(target)`（L260） |
| `A` | Always（仅 `target.canApproveAlways`） | 进入确认态，不直接批 |
| `C`（确认态） | Confirm | `approveAlwaysSession(确认行)`（L255） |
| `Esc`（确认态） | Cancel 确认态 | `confirmingSessionId = nil` |

- 无修饰键才处理（`guard !hasCmd, !hasCtrl`，照 ChatView L1975）；文本框 firstResponder 放行（照 L1966-1970，防未来输入框）
- `A` 对非 opencode target：`return event` 放行（等价 ChatApprovalBar `where onApproveAlways != nil`）
- **确认态期间**：只处理 C/Esc，其余键放行——与 ChatApprovalBar `isConfirmingAlways` 分支一致；C 确认的是 `confirmingSessionId` 对应行（可能与当前高亮不同），不是"target"

### 4. 监视器（照 ChatApprovalBar 模板，但不抢焦点）

- `SessionListView` 持 `@State keyMonitor: Any?`；**onAppear 只装 monitor，不做 `NSApp.activate` / `makeKey`**；onDisappear 卸
- **不抢焦点是硬约束**：`NotchWindowController.swift:74-78` 规定 `.notification` 打开路径不 activate（任务完成等通知场景，打开后挂载的正是 instances 页）。若 `SessionListView.onAppear` 无条件 activate，链路 = 通知弹出 → 用户在别的 app 打字 → 焦点被抢 → 击键落入 Nook → 恰有 pending 时散落的 `y` 直接批权限。ChatView L1946-1951 的 steal-focus 是 permission auto-expand → chat 页特例（该路径本 spec Non-Goal 保留，职责仍在 ChatApprovalBar）；用户主动打开路径（click / `.hover` / hotkey——窗口控制器对 `openReason != .notification` 一律 activate+makeKey，NotchWindowController.swift L75-77）monitor 本来就能收到事件
- **monitor 顺序 = LIFO（后装先收），`return nil` 即消费、先收者吞掉后收者**：本 monitor onAppear 装 → 比常驻的 ShortcutManager 后装 → **本 monitor 先收到事件**。工作原理是「只处理 y/n/a/c/esc-确认态，其余 `return event` 放行」——放行后才轮到 ShortcutManager（j/k/Enter/⌃R/非确认态 Esc 在彼处消费），**不是** ShortcutManager 先拦截。此心智模型是维护前提，勿写反
- 与 ShortcutManager 共存（无需改它）：y/n/a 不在任何绑定里 → 本 monitor 消费；j/k/Enter/⌃R 等本 monitor 放行 → ShortcutManager 按绑定消费
- 页面互斥：`.instances`（本 monitor）与 `.chat`（bar monitor）经 `switch contentType` 替换视图，onAppear/onDisappear 保证不并存
- 防御性 `contentType == .instances` guard 不加（Performance ⌃M spec 先例：视图只由该 case 托管）

### 5. 确认态提升

`InstanceRow` 的 `@State isConfirmingAlways`（L400）提升到 `SessionListView`：

```swift
@State private var confirmingSessionId: String? // nil = 无确认态
```

- `InstanceRow` 改收 `@Binding var isConfirmingAlways: Bool`；调用点按行派生：

```swift
isConfirmingAlways: Binding(
    get: { confirmingSessionId == session.sessionId },
    set: { confirmingSessionId = $0 ? session.sessionId : nil }
)
```

- 鼠标点 Always/Cancel/Confirm 与键盘路径写同一状态（picker spec「键盘路径必须镜像鼠标路径副作用」）
- **EXIT 重置**（picker spec ❌3）：target 列表变更且 `confirmingSessionId` 不再是 target（审批已决）→ 清空；`onDisappear` → 清空
- `.onChange(of: targets)` 直接可用——`SessionState: Equatable`（SessionState.swift L13）
- **顺带修复既有 bug**：现状每行独立 `@State isConfirmingAlways`，两行可同时进确认态；提升为父级单值后天然全局单确认态（见 behavior matrix）

### 6. 键帽提示

`InlineApprovalButtons` 文案：`Deny (N)` / `Allow (Y)` / `Always (A)` / `Confirm (C)` / `Cancel (Esc)`——对齐 ChatApprovalBar L1811-1900 样式。

### 7. 文档随改

- `docs/specs/2026-07-10-opencode-permission-handling.md` ⌘↩/⌘⌫ 行（~L536）→ 标记由本实现取代（Y/N/A）
- Y/N/A 决策沉淀（PROGRESS Open 条目所指）：本 spec 即沉淀载体，覆盖 chat + list 两处

## Behavior matrix

| 状态 | 键 | 结果 |
|---|---|---|
| 0 target | y/n/a | 放行 |
| 1 target，无高亮 | y/n | 批/拒唯一 target |
| 1 target，高亮别行 | y/n | **仍批唯一 target**（已确认） |
| 2+ target，高亮 target | y/n | 批/拒高亮行 |
| 2+ target，高亮非 target / 无高亮 | y/n | 放行 |
| target 为 opencode | a | 进入该行确认态（Patterns 文本 + Cancel/Confirm） |
| target 为 claude/codex/cursor | a | 放行（无 Always） |
| 确认态 | c | 批确认行（always），清确认态 |
| 确认态 | esc | 清确认态（见风险表 Esc 交互） |
| 确认态 | y/n/其他 | 放行 |
| 行 A 确认态中，鼠标点行 B 的 Always | — | 行 A 自动退出确认态（父级单值；修复现可双确认态的 bug） |
| terminal-approval / interactive 行 | y/n/a | 不算 target：列表只有这类 pending 时 count=0 无反应；2+ 真 target 时高亮它 = 不响应 |
| question 行（waitingForInput） | y/n/a | 放行（⌃R 职责） |
| chat 页 | y/n/a | 由 ChatApprovalBar 处理，本 monitor 已卸 |

## Testing

项目无 SwiftUI key monitor 自动化测试（先例：`2026-05-26-keyboard-shortcuts-design.md`）。手动：

```bash
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Debug -destination 'platform=macOS' build
```

1. **不抢焦点**：任务完成通知弹出 instances 页（用户正在其他 app 输入）→ 无 pending 时 y/n 不进 Nook、焦点不被抢；有 pending 时散落 y 不误批（`NotchWindowController.swift:74` 规则不被 onAppear 破坏）
2. 单 opencode pending → 不导航按 Y → 批准；按 A → 确认态，C 批 / Esc 取消（**且 notch 不关**，验证 LIFO Esc 分流）
3. 造两个 pending（两个会话各触发一次权限）→ 无高亮按 Y 无效；⌃N 选中其一 → Y 打中该行
4. 高亮在 idle 行 + 2 pending → Y 放行不批；高亮 idx=-1（无高亮）同验
5. claude pending → A 放行（无 Always 键帽）
6. question 行 → Y 不触发审批、⌃R 正常
7. chat 页审批 bar Y/N/A 行为不回归
8. 确认态中切页/关 notch → 重开无残留确认态；行 A 确认态中点行 B Always → A 退出
9. `/tmp/nook-debug.log` 出现 approve/deny 记录且 `directory` 正确（与 1.5.1 reply 修复叠加验证）

## Risk & Mitigations

| Risk | Mitigation |
|---|---|
| Esc 路由误判（看似双动作：确认态 Esc 同时关 notch？） | **机制上不可能**（monitor LIFO，后装先收，先收 `return nil` 即消费）：确认态 Esc 被本 monitor 先收并消费 → 只清确认态、notch 不关；非确认态 Esc 本 monitor 放行 → ShortcutManager 收到 → closeNotch。与 chat 页同构（bar monitor 后装于 ShortcutManager，已上线即此行为）。测试 2 的 Esc 取消步骤顺带验证 notch 不关 |
| SOI 与 InstanceRow branch 1 漂移 | SOI 注释双向锚定 branch 结构；branch 2 改用 SOI 消除第二处内联 |
| 键帽文案加长挤压行宽 | ChatApprovalBar 已用同文案在更宽 bar 验证；行内 `layoutPriority(1)` 已给按钮区优先（L615） |
| count==1 批准后 `confirmingSessionId` 残留 | `.onChange` of target 集合：id 不在集合 → 清空 + onDisappear 清空 |
| monitor 泄漏 | onDisappear 必卸（页面 switch 销毁视图）；同 Performance ⌃M 风险表 |

## Compatibility

- macOS only（NSEvent）；无 settings/迁移；无 VM/Shortcut 系统改动
- 依赖 plugin 1.5.1 directory 修复（同日未提交改动）——审批动作经既有 `SessionMonitor` 通道，本 spec 不重复其设计
