# 会话事件入口与注册前缓存治理（三期，2026-10-22）

## 优先级判断

本期继续在 `feature/architecture-governance` 实施，承接 [总方案](2026-10-22-architecture-governance.md) 与 [Claude 读取治理](2026-10-22-claude-read-lifecycle.md)。历史回填决策、问答/权限快捷键手测等旧待办不变。

剩余事项中，先处理事件入口的顺序与归属，再处理纯模型隔离告警和 provider reducer 拆分。顺序不明确会直接影响最终 phase、工具状态和注册结果；先明确输入契约，也能给后续拆分提供可靠的回归边界。

以下判断来自源码审计，不代表已复现真实 provider 故障。当前 `/tmp/nook-debug.log` 没有足以重新验证 OpenCode 新版本事件协议的样本，因此本期只改变应用内部调度与缓存，不据旧兼容矩阵改动事件识别。

| 源码证据 | 风险 | 本期措施 |
| --- | --- | --- |
| Socket 串行解码后，Runtime 为内容和 lifecycle 回调各自创建 Task | “先发内容回调”不保证内容在 stop 前提交；较晚执行的实时内容可能再次激活会话 | 保留完整适配批次，统一显式 FIFO |
| OpenCode wrapper 的 `clearSession` 在 Runtime 异步 stop 内执行 | 旧 stop 的清理可能晚于下一帧的消息上下文建立 | 当前帧转换结束后，在适配序列内同步清理 |
| `earlyChatItemBuffer` 只按 session ID 分组，注册时先回放再完成真实 session 建立 | 早到的错误 provider 内容可能决定 placeholder 归属；创建时的旧局部值也可能覆盖回放结果 | 注册先确认 provider，回放只作用于已建立的正确 session |
| 未注册内容无容量/TTL，未知 child 通常没有有效移除路径 | 无法注册的输入可长期累积 | 提取有界、可过期的注册前缓存 |

## 设计契约

### Runtime 拥有有序入口

- 所有 socket provider 的 Store 提交共用 Runtime 实例拥有的 FIFO；同步 enqueue 确定顺序，每项等待上一项完成。不能先创建异步 Task，再在 Task 内争抢入队。
- OpenCode/Cursor 的一次适配结果作为一个批次提交，批内保持现有 content → passthrough 顺序；批间不交错。Store 的 UI 操作、文件读取提交仍可在 actor await 处正常进入，这不是全应用事务锁。
- 队列注入异步 event sink；测试用 continuation gate 阻塞 sink，验证实际完成顺序。生产 sink 使用现有 `SessionStore.process`，不更改事件含义。
- 每次 Runtime start 生成接收代次，stop 关闭该代次的接收；过期回调不能向重启后的入口新增任务。
- 保留现有 stop 的非 drain 行为：已经接受的批次继续按序完成，不在中途取消。队列贯穿 Runtime 实例寿命，重启后的新批次排在已接受旧批次之后；提供显式等待入口供测试验证。App 退出不承诺等待全部排空。
- Claude watcher 的代次保护和权限 socket 清理语义保留；不将问答等待、人机确认或文件 history load 放入入口 FIFO。
- 显式的非隔离 callback 暴露了 Runtime 读取 MainActor phase 和触达 socket singleton 的旧隔离问题。Phase 判断留在已有 watcher MainActor task；Stop/PostToolUse 的权限连接清理由 socket 自身串行处理器负责，并以临时 socket 测试验证，不额外排一个可能延迟的 UI actor 清理任务。

### Adapter 清理与转换同序

OpenCode wrapper 在当前 envelope 转换完成、识别到 stop passthrough 后清理其 message/block-index 上下文，然后才允许下一 envelope 转换。Runtime 不再延迟清理它。保留 `OpencodeHookAdapter` 的 PRIMARY/DEFENSIVE 路径、子代理路由、permission/question payload 和 pid/port 协议。

Cursor 的 `clearSession` 当前为空，不声称存在同样的缓存竞态。它的 stop/sessionEnd 继续遵守现有 reducer 行为。

### 注册前缓存有明确归属和边界

- 缓存键为 `(provider, sessionId)`，每条记录保留原 `appliesLifecycleEffects`。只有合法 session 创建/注册可以授权回放；缓冲内容不能自行创建顶层会话或抢占 provider。
- 注册时丢弃同 ID 的不匹配 provider 桶，回放匹配桶且只回放一次。无副作用的 history 内容不能升级为实时事件。Codex 被抑制的 startup 不能被缓存提前变成可见 session。
- 保留未知 child 不产生顶层 session 的白名单约束。会话移除/reset 清理相关缓存；已注册会话的数据不受注册前缓存预算限制。
- 默认预算：最多 64 个未知身份，每身份 256 条，全局 4096 条；TTL 为首次收到内容起 30 秒，后续输入不续期。使用可注入的单调时钟和预算，测试不靠 sleep。
- 单桶溢出丢弃该桶全部内容，并将该身份标记为抑制，避免回放一个缺少末尾完成事件的旧前缀。全局条数不足时也将最老内容桶清空并抑制；身份数不足时淘汰最老身份。抑制持续至到期、注册或身份记录被容量淘汰；身份淘汰后再次输入可以建立新桶。规则须有确定性测试。
- enqueue、注册回放、周期状态检查均清理过期数据。清理记录只含原因、provider/ID 和数量，不写消息正文。
- 预算只限制注册前缓存的条数与保留时间，不限制入口 FIFO 积压，也不宣称严格限制进程字节数；大图和大型工具结果的字节预算属于后续独立资源治理。真正的 session 若长期不注册或超出预算，早期展示数据可能被丢弃，本期不增加持久化/上游重放协议。
- 现有 wire payload 没有完整会话代际。FIFO 能保留本机接收顺序，不能辨识 provider 在网络层迟送的同 ID 旧事件，也不能修复它上游已经乱序的数据。
- 本期保证注册前缓存的 provider 归属，未给所有 `SessionEvent` 增加 provider 标签。既有通用 `sessionEnded` 和 `subagent*` 事件仍依赖 session ID；不同 provider 撞 ID 时的这些旁路，需要后续以 provider 明确的事件契约治理，不能将本期描述为全入口隔离。

## 实施顺序

1. 保存本方案，随后实现 Runtime FIFO、完整批次传递和 adapter 同序清理。
2. 实现 provider 明确的注册回放与有界缓存，保留既有生命周期语义。
3. 独立审查，执行针对性回归、全量 app tests 和 Release 通用构建，补齐实施证据后在当前开发分支提交。

## 验收

- 门控 sink 验证内容 → stop、start → 内容、连续批次及跨 provider 顺序；stop/start 期间已接受项继续完成，旧接收代次不能再入队。
- 实际 Store 验证 OpenCode/Cursor stop 后最终 idle、工具收尾且聊天保留；现有 Codex/Claude 与 runtime/socket 回归不退化。
- Adapter fixture 验证 stop 后新消息上下文和 block index 不被迟到清理；不改 PRIMARY/DEFENSIVE 解析路径。
- 缓存验证 provider 冲突、合法回放顺序、content-only/realtime 策略、Codex startup 隔离、未知 child、TTL 边界、持续输入不续期、三层容量限制、周期过期及 remove/reset 清理。
- 完整 `NookTests` 通过；Release 的 arm64/x86_64 构建与 strict codesign 校验通过。真实 provider 权限/问答手测和远端 CI 不计入本地通过声明。

## 实施证据

- 已在 `feature/architecture-governance` 实施：`SessionEventIngress` 拥有同步接收代次与异步 FIFO，Socket 传递完整适配批次，OpenCode wrapper 在转换序列清理；Store 先建立合法 owner，再回放 `PendingChatItemBuffer`，内容入口不再创建 placeholder。
- 独立审查确认 admission/close 同锁、已接收批次跨重启继续排空、注册回放先于当前生命周期事件、Cursor 首次 stop 的工具收尾、Codex startup 抑制，以及权限连接在 socket 接收路径直接清理。未发现阻塞项；通用结束/subagent 的 provider 来源限制已记录在设计边界中。
- 新增 29 项确定性回归：`SessionEventIngressTests` 5 项、`OpencodeIngressAdapterTests` 2 项、`HookSocketServerBatchTests` 1 项、`HookSocketPermissionCleanupTests` 2 项、`PendingChatItemBufferTests` 9 项、`SessionStoreRegistrationTests` 10 项。最终完整 Debug 测试为 **260/260**，无失败。
- 最终代码的 Release 通用构建通过，产物含 **arm64 + x86_64**，`codesign --verify --deep --strict` 通过；本轮新入口、缓存及 Runtime 在该构建中没有隔离告警。
- Socket 回归使用唯一临时路径，验证真实解码、完整批次与权限连接 EOF；不连接 `/tmp/nook.sock`，不触发真实 provider。Adapter fixtures 使用唯一 ID 并发送本地终态事件收尾；既有 wire cleanup 的短期 stopped 标记仍按原策略过期。
- 本地证据（构建产物不提交）：`build/session-ingress-verified-tests.log`、`build/SessionIngressGovernance-Verified.xcresult`、`build/session-ingress-release.log`。
- 未运行真实 provider 权限/问答手测或远端 CI；旧待办与 `PROGRESS.md` 保持不变。未切换 Swift language mode；既有模型/adapter/DebugLog 的隔离告警仍属于后续治理。

无持久化格式迁移；回滚需保持 socket 批次接口、Runtime 消费方式与 adapter 清理位置匹配。
