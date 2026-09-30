import XCTest
@testable import Nook

@MainActor
final class SessionStoreServerPortTests: XCTestCase {
    /// 多实例：各 session 的 serverPort 由自身 pid 绑定，互不串台。
    func testServerPortBoundByPidDoesNotLeakAcrossInstances() async {
        let store = SessionStore.shared
        await store.resetForTesting()

        await store.process(.opencodeSessionStarted(sessionId: "A", cwd: "/tmp/proj-a"))
        await store.process(.opencodeSessionStarted(sessionId: "B", cwd: "/tmp/proj-b"))

        // 模拟 enrichOpencodeRuntimeMetadata 按 cwd 解析出的进程 pid
        await store.setSessionPidForTesting(sessionId: "A", pid: 100)
        await store.setSessionPidForTesting(sessionId: "B", pid: 200)

        // 两个实例各上报端口
        await store.process(.opencodeServerPortReceived(sessionId: "?", port: 4096, version: nil, pid: 100))
        await store.process(.opencodeServerPortReceived(sessionId: "?", port: 55123, version: nil, pid: 200))

        let a = await store.session(for: "A")
        let b = await store.session(for: "B")
        XCTAssertEqual(a?.serverPort, 4096)
        XCTAssertEqual(b?.serverPort, 55123)
    }

    /// 旧 plugin（无 pid）：fallback 广播到所有 opencode session。
    func testServerPortFallbackBroadcastsWhenNoPid() async {
        let store = SessionStore.shared
        await store.resetForTesting()

        await store.process(.opencodeSessionStarted(sessionId: "A", cwd: "/tmp/proj-a"))
        await store.process(.opencodeServerPortReceived(sessionId: "?", port: 4096, version: nil, pid: nil))

        let a = await store.session(for: "A")
        XCTAssertEqual(a?.serverPort, 4096)
    }

    /// port=0 表示当前实例无 HTTP server（TUI 模式无 --port），不得写入映射。
    func testServerPortZeroIgnoredDoesNotLeak() async {
        let store = SessionStore.shared
        await store.resetForTesting()

        await store.process(.opencodeSessionStarted(sessionId: "A", cwd: "/tmp/proj-a"))
        await store.setSessionPidForTesting(sessionId: "A", pid: 100)
        await store.process(.opencodeServerPortReceived(sessionId: "?", port: 0, version: nil, pid: 100))

        let a = await store.session(for: "A")
        XCTAssertNil(a?.serverPort)

        // 后续真实端口正常接收
        await store.process(.opencodeServerPortReceived(sessionId: "?", port: 55123, version: nil, pid: 100))
        guard let a2 = await store.session(for: "A") else { return XCTFail("session A gone") }
        XCTAssertEqual(a2.serverPort, 55123)
    }
}
