import Foundation

/// Short-lived storage for content whose provider has not registered a session.
/// Budgets count identities and updates, not the bytes retained by each payload.
nonisolated struct PendingChatItemBuffer: Sendable {
    struct Policy: Sendable {
        var maximumIdentities = 64
        var maximumUpdatesPerIdentity = 256
        var maximumUpdates = 4096
        var timeToLive: TimeInterval = 30
    }

    struct Identity: Hashable, Sendable {
        let provider: SessionProvider
        let sessionId: String

        func hash(into hasher: inout Hasher) {
            hasher.combine(provider.rawValue)
            hasher.combine(sessionId)
        }
    }

    struct Entry: Sendable {
        let update: ChatItemUpdate
        let appliesLifecycleEffects: Bool
    }

    struct Discard: Sendable {
        enum Reason: String, Sendable {
            case expired, identityLimit, updateLimit, identityOverflow, suppressed, providerMismatch
        }

        let identity: Identity
        let count: Int
        let reason: Reason
    }

    struct Drain: Sendable {
        let entries: [Entry]
        let discards: [Discard]
    }

    private struct Bucket: Sendable {
        let receivedAt: TimeInterval
        let sequence: UInt64
        var entries: [Entry] = []
        var suppressed = false
    }

    private let policy: Policy
    private var buckets: [Identity: Bucket] = [:]
    private var nextSequence: UInt64 = 0
    private(set) var updateCount = 0

    init(policy: Policy = Policy()) {
        precondition(policy.maximumIdentities > 0 && policy.maximumUpdatesPerIdentity > 0)
        precondition(policy.maximumUpdates > 0 && policy.timeToLive > 0)
        self.policy = policy
    }

    var identityCount: Int { buckets.count }
    var sessionIds: Set<String> { Set(buckets.keys.map(\.sessionId)) }

    mutating func enqueue(_ entry: Entry, now: TimeInterval) -> [Discard] {
        var discards = prune(now: now)
        let identity = Identity(provider: entry.update.provider, sessionId: entry.update.sessionId)
        if buckets[identity] == nil {
            if buckets.count >= policy.maximumIdentities, let oldest = oldestIdentity() {
                // Identity eviction also forgets suppression. A later update
                // may start a new bucket even before the evicted bucket's TTL.
                let removed = remove(oldest)
                discards.append(Discard(identity: oldest, count: removed.count, reason: .identityLimit))
            }
            buckets[identity] = Bucket(receivedAt: now, sequence: nextSequence)
            nextSequence &+= 1
        }

        if buckets[identity]?.suppressed == true {
            discards.append(Discard(identity: identity, count: 1, reason: .suppressed))
            return discards
        }
        if (buckets[identity]?.entries.count ?? 0) >= policy.maximumUpdatesPerIdentity {
            let count = suppress(identity) + 1
            discards.append(Discard(identity: identity, count: count, reason: .identityOverflow))
            return discards
        }

        while updateCount >= policy.maximumUpdates, let oldest = oldestIdentity(withContent: true) {
            let count = suppress(oldest)
            discards.append(Discard(identity: oldest, count: count, reason: .updateLimit))
        }
        // The incoming identity may itself have been the oldest content bucket.
        // Do not begin retaining a detached tail after discarding its prefix.
        if buckets[identity]?.suppressed == true {
            discards.append(Discard(identity: identity, count: 1, reason: .suppressed))
            return discards
        }
        buckets[identity]?.entries.append(entry)
        updateCount += 1
        return discards
    }

    mutating func drain(provider: SessionProvider, sessionId: String, now: TimeInterval) -> Drain {
        var discards = prune(now: now)
        let matching = Identity(provider: provider, sessionId: sessionId)
        let related = buckets.keys.filter { $0.sessionId == sessionId }
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
        var entries: [Entry] = []
        for identity in related {
            let removed = remove(identity)
            if identity == matching {
                entries = removed
            } else {
                discards.append(Discard(identity: identity, count: removed.count, reason: .providerMismatch))
            }
        }
        return Drain(entries: entries, discards: discards)
    }

    mutating func prune(now: TimeInterval) -> [Discard] {
        let expired = buckets.filter { now - $0.value.receivedAt >= policy.timeToLive }
            .sorted { $0.value.sequence < $1.value.sequence }
        return expired.map { identity, _ in
            Discard(identity: identity, count: remove(identity).count, reason: .expired)
        }
    }

    mutating func remove(sessionId: String) {
        for identity in buckets.keys.filter({ $0.sessionId == sessionId }) {
            _ = remove(identity)
        }
    }

    mutating func removeAll() {
        buckets.removeAll()
        updateCount = 0
        nextSequence = 0
    }

    private func oldestIdentity(withContent: Bool = false) -> Identity? {
        buckets.filter { !withContent || !$0.value.entries.isEmpty }
            .min { $0.value.sequence < $1.value.sequence }?.key
    }

    private mutating func suppress(_ identity: Identity) -> Int {
        let count = buckets[identity]?.entries.count ?? 0
        buckets[identity]?.entries.removeAll()
        buckets[identity]?.suppressed = true
        updateCount -= count
        return count
    }

    @discardableResult
    private mutating func remove(_ identity: Identity) -> [Entry] {
        let entries = buckets.removeValue(forKey: identity)?.entries ?? []
        updateCount -= entries.count
        return entries
    }
}
