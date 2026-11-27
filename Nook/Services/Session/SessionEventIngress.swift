import Foundation

/// Runtime-owned ordering for socket submissions. Admission is synchronous so
/// the socket's callback order also determines the order of Store commits.
nonisolated final class SessionEventIngress: @unchecked Sendable {
    typealias Sink = @Sendable (SessionEvent) async -> Void

    private let lock = NSLock()
    private let sink: Sink
    private var generation: UUID?
    private var tail: Task<Void, Never>?

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    func beginGeneration() -> UUID {
        lock.withLock {
            let generation = UUID()
            self.generation = generation
            return generation
        }
    }

    /// Close admission only. Already accepted batches retain their place and
    /// continue through the same tail, including across a subsequent start.
    func close() {
        lock.withLock { generation = nil }
    }

    @discardableResult
    func enqueue(_ events: [SessionEvent], generation: UUID) -> Bool {
        lock.withLock {
            guard self.generation == generation else { return false }
            guard !events.isEmpty else { return true }
            let previous = tail
            let sink = self.sink
            tail = Task {
                await previous?.value
                for event in events {
                    await sink(event)
                }
            }
            return true
        }
    }

    /// Wait for the work accepted when this method is called. Runtime.stop()
    /// deliberately does not call this or promise to drain before app exit.
    func waitUntilDrained() async {
        let accepted = lock.withLock { tail }
        await accepted?.value
    }
}
