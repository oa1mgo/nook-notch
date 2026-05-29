import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog

@MainActor
final class NowPlayingController: MediaControllerProtocol {
    private enum AdapterCommand: Int {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    private struct AdapterExecutionResult {
        let data: Data
        let standardError: String
        let terminationStatus: Int32
    }

    private let subject = CurrentValueSubject<PlaybackState, Never>(PlaybackState())
    private let decoder = JSONDecoder()
    private let logger = Logger(subsystem: "com.celestial.Nook", category: "NowPlaying")
    private let optimisticToggleProtectionWindow: TimeInterval = 0.8

    private var cachedFrameworkURL: URL?
    private var streamProcess: Process?
    private var streamPipeHandler: JSONLinesPipeHandler?
    private var streamTask: Task<Void, Never>?
    private var pendingOptimisticToggleUntil: Date?

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        subject.removeDuplicates().eraseToAnyPublisher()
    }

    init() {
        startStreamingUpdates()
    }

    deinit {
        streamTask?.cancel()

        if let streamProcess, streamProcess.isRunning {
            streamProcess.terminate()
        }

        if let streamPipeHandler {
            Task {
                await streamPipeHandler.close()
            }
        }
    }
}

extension NowPlayingController {
    func refresh() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let result = await self.runAdapter(arguments: ["get"], context: "refresh") else { return }

            guard result.terminationStatus == 0 else {
                self.logger.error("Adapter refresh failed with status \(result.terminationStatus)")
                return
            }

            self.applySnapshot(from: result.data)
        }
    }

    func restartStreaming() {
        cleanupStream()
        startStreamingUpdates()
        refresh()
    }

    func togglePlayPause(displayedTime: TimeInterval?) {
        sendCommand(.togglePlayPause, displayedTime: displayedTime)
    }

    func nextTrack() {
        sendCommand(.nextTrack)
    }

    func previousTrack() {
        sendCommand(.previousTrack)
    }

    func openSourceApp() {
        let configuration = NSWorkspace.OpenConfiguration()

        if let bundleIdentifier = subject.value.bundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
            return
        }

        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Music.app"),
            configuration: configuration
        ) { _, _ in }
    }

    // MARK: - seekTo (Disabled)
    //
    // MRMediaRemoteSetElapsedTime returns false on macOS 15.6+ (confirmed via
    // adapter binary disassembly — the C function itself fails at the system
    // level). This is not an entitlement issue; sendCommand (which uses
    // MRMediaRemoteSendCommand) works fine through the same Perl process.
    //
    // Potential alternatives if Apple ever fixes this:
    //   positionUs = Int(time * 1_000_000)
    //   runAdapter(arguments: ["seek", String(positionUs)], context: "seek")
}

private extension NowPlayingController {
    func startStreamingUpdates() {
        cleanupStream()

        guard let scriptURL = adapterScriptURL(), let frameworkURL = adapterFrameworkURL() else {
            return
        }

        let process = Process()
        let pipeHandler = JSONLinesPipeHandler()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkURL.path, "stream", "--debounce=50"]
        process.standardOutput = pipeHandler.pipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self, logger] process in
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus != 0 {
                logger.error("Adapter stream exited with status \(process.terminationStatus): \(errorOutput, privacy: .public)")
            }

            // Auto-restart the streaming process after a brief delay.
            // Uses a simple rate limit to prevent rapid restart loops.
            guard streamRestartThrottle.allowRestart() else { return }
            logger.debug("Restarting adapter stream")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startStreamingUpdates()
            }
        }

        do {
            try process.run()
            streamProcess = process
            streamPipeHandler = pipeHandler
            streamTask = Task { @MainActor [weak self] in
                guard let self else { return }

                await pipeHandler.readJSONLines(as: AdapterStreamEvent.self, logger: self.logger) { [weak self] event in
                    guard let self else { return }
                    self.apply(event: event)
                }
            }
        } catch {
            logger.error("Failed to launch adapter stream: \(String(describing: error), privacy: .public)")
            streamProcess = nil
            streamPipeHandler = nil
        }
    }

    private func cleanupStream() {
        streamTask?.cancel()
        streamTask = nil

        if let process = streamProcess, process.isRunning {
            process.terminate()
        }
        streamProcess = nil

        if let handler = streamPipeHandler {
            Task {
                await handler.close()
            }
        }
        streamPipeHandler = nil
    }

    private func sendCommand(_ command: AdapterCommand, displayedTime: TimeInterval? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.logger.debug(
                "sendCommand command=\(command.rawValue) displayedTime=\(String(describing: displayedTime), privacy: .public) currentTime=\(self.subject.value.currentTime, privacy: .public) isPlaying=\(self.subject.value.isPlaying, privacy: .public) lastUpdated=\(self.subject.value.lastUpdated.ISO8601Format(), privacy: .public)"
            )
            self.applyOptimisticState(for: command, displayedTime: displayedTime)
            guard let result = await self.runAdapter(
                arguments: ["send", String(command.rawValue)],
                context: "send-\(command.rawValue)"
            ) else {
                return
            }

            guard result.terminationStatus == 0 else {
                self.logger.error("Adapter command \(command.rawValue) failed with status \(result.terminationStatus)")
                return
            }

            try? await Task.sleep(for: .milliseconds(200))
            self.refresh()
        }
    }

    private func applyOptimisticState(for command: AdapterCommand, displayedTime: TimeInterval?) {
        guard command == .togglePlayPause else { return }

        let current = subject.value
        let now = Date()
        let optimisticCurrentTime = displayedTime.map {
            clampedElapsedTime($0, duration: current.duration)
        } ?? clampedElapsedTime(current.currentTime, duration: current.duration)

        var optimistic = current
        optimistic.currentTime = optimisticCurrentTime
        optimistic.lastUpdated = now
        optimistic.isPlaying.toggle()
        pendingOptimisticToggleUntil = now.addingTimeInterval(optimisticToggleProtectionWindow)
        logger.debug(
            "optimisticToggle displayedTime=\(String(describing: displayedTime), privacy: .public) optimisticCurrentTime=\(optimisticCurrentTime, privacy: .public) previousCurrentTime=\(current.currentTime, privacy: .public) previousIsPlaying=\(current.isPlaying, privacy: .public) optimisticIsPlaying=\(optimistic.isPlaying, privacy: .public) protectUntil=\(self.pendingOptimisticToggleUntil?.ISO8601Format() ?? "nil", privacy: .public)"
        )
        subject.send(optimistic)
    }

    private func clampedElapsedTime(_ elapsedTime: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return max(0, elapsedTime) }
        return min(max(0, elapsedTime), duration)
    }

    private func runAdapter(arguments: [String], context: String) async -> AdapterExecutionResult? {
        guard let scriptURL = adapterScriptURL(), let frameworkURL = adapterFrameworkURL() else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [scriptURL.path, frameworkURL.path] + arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.terminationHandler = { [logger] process in
                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if process.terminationStatus != 0 {
                    logger.error("Adapter \(context, privacy: .public) failed with status \(process.terminationStatus): \(errorOutput, privacy: .public)")
                }

                continuation.resume(
                    returning: AdapterExecutionResult(
                        data: outputData,
                        standardError: errorOutput,
                        terminationStatus: process.terminationStatus
                    )
                )
            }

            do {
                try process.run()
            } catch {
                logger.error("Failed to launch adapter \(context, privacy: .public): \(String(describing: error), privacy: .public)")
                continuation.resume(returning: nil)
            }
        }
    }

    func adapterScriptURL() -> URL? {
        if let url = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl") {
            return url
        }

        logger.error("Missing bundled resource: mediaremote-adapter.pl")
        return nil
    }

    func adapterFrameworkURL() -> URL? {
        if let cachedFrameworkURL, FileManager.default.fileExists(atPath: cachedFrameworkURL.path) {
            return cachedFrameworkURL
        }

        guard let archiveURL = Bundle.main.url(forResource: "MediaRemoteAdapter.framework", withExtension: "zip") else {
            logger.error("Missing bundled resource: MediaRemoteAdapter.framework.zip")
            return nil
        }

        guard
            let archiveData = try? Data(contentsOf: archiveURL),
            let extractionRoot = adapterExtractionRoot(for: archiveData)
        else {
            logger.error("Failed to prepare adapter extraction root")
            return nil
        }

        let frameworkURL = extractionRoot.appendingPathComponent("MediaRemoteAdapter.framework", isDirectory: true)
        if FileManager.default.fileExists(atPath: frameworkURL.path) {
            cachedFrameworkURL = frameworkURL
            return frameworkURL
        }

        let extractedFrameworkURL = extractFrameworkArchive(at: archiveURL, to: extractionRoot)
        cachedFrameworkURL = extractedFrameworkURL
        return extractedFrameworkURL
    }

    private func applySnapshot(from data: Data) {
        guard let snapshot = try? decoder.decode(AdapterSnapshot.self, from: data) else {
            logDecodeFailure(for: data, context: "snapshot")
            return
        }

        let previousState = subject.value
        let state = makePlaybackState(
            payload: snapshot,
            diff: false,
            previous: previousState
        )
        let reconciledState = reconcileSnapshotIfNeeded(
            snapshot: snapshot,
            incoming: state,
            previous: previousState
        )
        logger.debug(
            "applySnapshot playing=\(String(describing: snapshot.playing), privacy: .public) elapsedTime=\(String(describing: snapshot.elapsedTime), privacy: .public) playbackRate=\(String(describing: snapshot.playbackRate), privacy: .public) timestamp=\(String(describing: snapshot.timestamp), privacy: .public) -> currentTime=\(reconciledState.currentTime, privacy: .public) isPlaying=\(reconciledState.isPlaying, privacy: .public) lastUpdated=\(reconciledState.lastUpdated.ISO8601Format(), privacy: .public)"
        )
        pendingOptimisticToggleUntil = nil
        subject.send(reconciledState)
    }

    private func apply(event: AdapterStreamEvent) {
        guard event.type == nil || event.type == "data" else { return }

        if shouldIgnoreStreamEventDuringOptimisticToggle(event) {
            logger.debug(
                "ignoreStreamEvent diff=\(event.diff ?? false, privacy: .public) playing=\(String(describing: event.payload.playing), privacy: .public) elapsedTime=\(String(describing: event.payload.elapsedTime), privacy: .public) playbackRate=\(String(describing: event.payload.playbackRate), privacy: .public) timestamp=\(String(describing: event.payload.timestamp), privacy: .public) pendingUntil=\(self.pendingOptimisticToggleUntil?.ISO8601Format() ?? "nil", privacy: .public)"
            )
            return
        }

        let state = makePlaybackState(
            payload: event.payload,
            diff: event.diff ?? false,
            previous: subject.value
        )
        logger.debug(
            "applyStreamEvent diff=\(event.diff ?? false, privacy: .public) playing=\(String(describing: event.payload.playing), privacy: .public) elapsedTime=\(String(describing: event.payload.elapsedTime), privacy: .public) playbackRate=\(String(describing: event.payload.playbackRate), privacy: .public) timestamp=\(String(describing: event.payload.timestamp), privacy: .public) -> currentTime=\(state.currentTime, privacy: .public) isPlaying=\(state.isPlaying, privacy: .public) lastUpdated=\(state.lastUpdated.ISO8601Format(), privacy: .public)"
        )
        subject.send(state)
    }

    private func shouldIgnoreStreamEventDuringOptimisticToggle(_ event: AdapterStreamEvent) -> Bool {
        guard let pendingUntil = pendingOptimisticToggleUntil else { return false }

        if Date() >= pendingUntil {
            pendingOptimisticToggleUntil = nil
            return false
        }

        guard event.diff ?? false else { return false }

        // Stream diffs immediately after play/pause can momentarily report an
        // inconsistent elapsed time. Let the scheduled full refresh win.
        return event.payload.playing != nil
            || event.payload.elapsedTime != nil
            || event.payload.timestamp != nil
            || event.payload.playbackRate != nil
    }

    private func reconcileSnapshotIfNeeded(
        snapshot: AdapterSnapshot,
        incoming: PlaybackState,
        previous: PlaybackState
    ) -> PlaybackState {
        guard pendingOptimisticToggleUntil != nil else { return incoming }

        let now = Date()
        let previousProjectedTime = projectedElapsedTime(for: previous, at: now)
        let incomingProjectedTime = projectedElapsedTime(for: incoming, at: now)
        let isLargeRegression = incomingProjectedTime + 1.0 < previousProjectedTime
        let hasExplicitTransportToggle = snapshot.playing != nil

        guard hasExplicitTransportToggle, isLargeRegression else {
            return incoming
        }

        var reconciled = incoming
        reconciled.currentTime = previousProjectedTime
        reconciled.lastUpdated = now
        logger.debug(
            "reconcileSnapshot previousProjected=\(previousProjectedTime, privacy: .public) incomingProjected=\(incomingProjectedTime, privacy: .public) reconciledCurrentTime=\(reconciled.currentTime, privacy: .public) incomingIsPlaying=\(incoming.isPlaying, privacy: .public)"
        )
        return reconciled
    }

    private func projectedElapsedTime(for state: PlaybackState, at date: Date) -> TimeInterval {
        guard state.isPlaying else {
            return clampedElapsedTime(state.currentTime, duration: state.duration)
        }

        let delta = max(0, date.timeIntervalSince(state.lastUpdated))
        return clampedElapsedTime(state.currentTime + (delta * state.playbackRate), duration: state.duration)
    }

    private func makePlaybackState(
        payload: AdapterPayload,
        diff: Bool,
        previous: PlaybackState
    ) -> PlaybackState {
        PlaybackState(
            bundleIdentifier: payload.bundleIdentifier
                ?? payload.parentApplicationBundleIdentifier
                ?? (diff ? previous.bundleIdentifier : NSWorkspace.shared.frontmostApplication?.bundleIdentifier),
            isPlaying: payload.playing ?? (diff ? previous.isPlaying : false),
            title: resolvedString(payload.title, previous: previous.title, diff: diff),
            artist: resolvedString(payload.artist, previous: previous.artist, diff: diff),
            album: resolvedString(payload.album, previous: previous.album, diff: diff),
            currentTime: resolvedDouble(payload.elapsedTime, previous: previous.currentTime, diff: diff),
            duration: resolvedDouble(payload.duration, previous: previous.duration, diff: diff),
            playbackRate: resolvedDouble(payload.playbackRate, previous: previous.playbackRate, diff: diff),
            lastUpdated: resolvedDate(payload.timestamp, previous: previous.lastUpdated, diff: diff),
            artworkData: resolvedArtworkData(payload.artworkData, previous: previous.artworkData, diff: diff)
        )
    }

    private func resolvedString(_ value: String?, previous: String, diff: Bool) -> String {
        if let value {
            return value
        }
        return diff ? previous : ""
    }

    private func resolvedDouble(_ value: Double?, previous: Double, diff: Bool) -> Double {
        if let value {
            return value
        }
        return diff ? previous : 0
    }

    private func resolvedArtworkData(_ value: String?, previous: Data?, diff: Bool) -> Data? {
        if let value {
            return Data(base64Encoded: value)
        }
        return diff ? previous : nil
    }

    private func resolvedDate(_ value: String?, previous: Date, diff: Bool) -> Date {
        if let value, let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        return diff ? previous : Date()
    }

    private func logDecodeFailure(for data: Data, context: String) {
        let sample = String(data: data.prefix(256), encoding: .utf8) ?? "<non-utf8>"
        logger.error("Failed to decode adapter \(context, privacy: .public): \(sample, privacy: .public)")
    }

    private func adapterExtractionRoot(for archiveData: Data) -> URL? {
        let digest = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        let baseDirectoryName = Bundle.main.bundleIdentifier ?? "Nook"

        guard let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            logger.error("Unable to resolve caches directory for adapter extraction")
            return nil
        }

        let baseURL = cachesURL
            .appendingPathComponent(baseDirectoryName, isDirectory: true)
            .appendingPathComponent("MusicAdapter", isDirectory: true)

        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return baseURL.appendingPathComponent(digest, isDirectory: true)
    }

    private func extractFrameworkArchive(at archiveURL: URL, to extractionRoot: URL) -> URL? {
        let finalFrameworkURL = extractionRoot.appendingPathComponent("MediaRemoteAdapter.framework", isDirectory: true)
        let tempRootURL = extractionRoot.deletingLastPathComponent()
            .appendingPathComponent("\(extractionRoot.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempRootURL, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archiveURL.path, tempRootURL.path]
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                logger.error("Framework archive extraction failed with status \(process.terminationStatus)")
                try? FileManager.default.removeItem(at: tempRootURL)
                return nil
            }

            let extractedFrameworkURL = tempRootURL.appendingPathComponent("MediaRemoteAdapter.framework", isDirectory: true)
            guard FileManager.default.fileExists(atPath: extractedFrameworkURL.path) else {
                logger.error("Extracted framework missing after archive expansion")
                try? FileManager.default.removeItem(at: tempRootURL)
                return nil
            }

            do {
                try FileManager.default.moveItem(at: tempRootURL, to: extractionRoot)
            } catch {
                if FileManager.default.fileExists(atPath: finalFrameworkURL.path) {
                    try? FileManager.default.removeItem(at: tempRootURL)
                    return finalFrameworkURL
                }

                logger.error("Failed to finalize framework extraction: \(String(describing: error), privacy: .public)")
                try? FileManager.default.removeItem(at: tempRootURL)
                return nil
            }

            return finalFrameworkURL
        } catch {
            logger.error("Failed to extract framework archive: \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: tempRootURL)
            return nil
        }
    }
}

// MARK: - Stream Restart Throttle

/// Sendable rate limiter for stream process restart, usable from
/// a @Sendable termination handler without @MainActor isolation conflicts.
private final class StreamRestartThrottle: @unchecked Sendable {
    nonisolated(unsafe) private var lastAttempt: Date = .distantPast
    private let minimumInterval: TimeInterval = 2.0

    fileprivate nonisolated func allowRestart() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastAttempt) >= minimumInterval else { return false }
        lastAttempt = now
        return true
    }
}

private let streamRestartThrottle = StreamRestartThrottle()

private struct AdapterStreamEvent: Decodable {
    let type: String?
    let diff: Bool?
    let payload: AdapterSnapshot
}

private struct AdapterSnapshot: Decodable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let timestamp: String?
    let playbackRate: Double?
    let artworkData: String?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
}

private typealias AdapterPayload = AdapterSnapshot

private actor JSONLinesPipeHandler {
    let pipe = Pipe()
    private let fileHandle: FileHandle
    private var buffer = ""

    init() {
        fileHandle = pipe.fileHandleForReading
    }

    func readJSONLines<T: Decodable>(
        as type: T.Type,
        logger: Logger,
        onLine: @escaping (T) async -> Void
    ) async {
        do {
            while true {
                let data = try await readData()
                guard !data.isEmpty else { break }

                if let chunk = String(data: data, encoding: .utf8) {
                    buffer.append(chunk)

                    while let range = buffer.range(of: "\n") {
                        let line = String(buffer[..<range.lowerBound])
                        buffer = String(buffer[range.upperBound...])

                        guard !line.isEmpty else { continue }
                        guard let data = line.data(using: .utf8) else { continue }

                        do {
                            let value = try JSONDecoder().decode(T.self, from: data)
                            await onLine(value)
                        } catch {
                            let sample = String(line.prefix(256))
                            logger.error("Failed to decode adapter stream line: \(sample, privacy: .public)")
                        }
                    }
                }
            }
        } catch {
            logger.error("Failed while reading adapter stream: \(String(describing: error), privacy: .public)")
        }
    }

    func close() async {
        fileHandle.readabilityHandler = nil
        try? fileHandle.close()
        try? pipe.fileHandleForWriting.close()
    }

    private func readData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                handle.readabilityHandler = nil
                continuation.resume(returning: data)
            }
        }
    }
}
