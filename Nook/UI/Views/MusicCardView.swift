import SwiftUI

struct MusicCardView: View {
    @ObservedObject var musicManager: MusicManager
    /// Fired when the user requests the music source app — either via the
    /// artwork tap or the ⌃O shortcut. The owner wires this up so it can do
    /// additional work (e.g. close the notch) alongside `openSourceApp()`.
    let onOpenSourceApp: () -> Void
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 12) {
            artworkColumnWithTooltip

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(primaryLineText)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(secondaryLineText)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    controlsRow
                }

                TimelineView(.animation(minimumInterval: musicManager.playbackState.isPlaying ? 0.2 : 1.0)) { timeline in
                    let elapsedTime = displayedElapsedTime(at: timeline.date)
                    let fraction = progressFraction(for: elapsedTime)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(Color.white.opacity(0.15))
                                .frame(height: 5)

                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(Color.white.opacity(0.9))
                                .frame(width: max(0, geo.size.width * fraction), height: 5)
                        }
                        .frame(height: 5)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            let tapFraction = location.x / geo.size.width
                            let seekTime = max(0, min(tapFraction, 1)) * musicManager.playbackState.duration
                            musicManager.seekTo(seekTime)
                        }
                    }
                    .frame(height: 5)

                    HStack {
                        Text(formatTime(elapsedTime))
                        Spacer()
                        Text(formatTime(musicManager.playbackState.duration))
                    }
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.05))
        )
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak musicManager] event in
                guard let musicManager, musicManager.isVisible else { return event }

                // Space: toggle play/pause (skip if text field has focus)
                if event.keyCode == 49 {
                    if let window = event.window,
                       let responder = window.firstResponder,
                       responder.isKind(of: NSTextView.self) || responder.isKind(of: NSTextField.self) {
                        return event
                    }
                    musicManager.togglePlayPause()
                    return nil
                }

                // ⌃⌘ left/right arrows
                let relevantFlags = event.modifierFlags.intersection([.command, .control, .option, .shift])
                if relevantFlags == [.command, .control] {
                    switch event.keyCode {
                    case 123: musicManager.previousTrack(); return nil
                    case 124: musicManager.nextTrack(); return nil
                    default: break
                    }
                }

                // ⌃O: open music app
                if relevantFlags == .control && event.keyCode == 31 {
                    onOpenSourceApp()
                    return nil
                }

                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }
}

private extension MusicCardView {
    var trimmedTitle: String? {
        trimmedPlaybackText(musicManager.playbackState.title)
    }

    var trimmedArtist: String? {
        trimmedPlaybackText(musicManager.playbackState.artist)
    }

    var trimmedAlbum: String? {
        trimmedPlaybackText(musicManager.playbackState.album)
    }

    var primaryLineText: String {
        trimmedTitle
            ?? trimmedArtist
            ?? "Nothing Playing"
    }

    var secondaryLineText: String {
        let secondaryCandidates = [trimmedArtist, trimmedAlbum]
            .compactMap { $0 }
            .filter { $0 != primaryLineText }

        if let secondaryText = secondaryCandidates.first {
            return secondaryText
        }

        return "Unknown Artist"
    }

    var artworkColumn: some View {
        Button(action: onOpenSourceApp) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image = musicManager.albumArt {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: musicManager.fallbackSymbolName)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                    }
                }
                .frame(width: 76, height: 76)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                if let sourceApp = musicManager.sourceApp, let icon = sourceApp.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .background(Color.black.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .padding(3)
                }
            }
            .frame(width: 76, height: 76)
        }
        .buttonStyle(.plain)
    }

    private var artworkColumnWithTooltip: some View {
        artworkColumn
            .shortcutTooltip("⌃O")
    }

    var controlsRow: some View {
        HStack(spacing: 10) {
            TransportButton(
                systemName: "backward.fill",
                shortcut: "⌃⌘←",
                action: musicManager.previousTrack
            )

            TransportButton(
                systemName: musicManager.playbackState.isPlaying ? "pause.fill" : "play.fill",
                shortcut: "Space",
                isPrimary: true,
                action: {
                    musicManager.togglePlayPause(displayedTime: displayedElapsedTime(at: Date()))
                }
            )

            TransportButton(
                systemName: "forward.fill",
                shortcut: "⌃⌘→",
                action: musicManager.nextTrack
            )
        }
    }

    func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = max(Int(time.rounded()), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    func displayedElapsedTime(at date: Date) -> TimeInterval {
        let state = musicManager.playbackState
        guard state.isPlaying else {
            return clampedElapsedTime(state.currentTime, duration: state.duration)
        }

        let delta = max(0, date.timeIntervalSince(state.lastUpdated))
        return clampedElapsedTime(state.currentTime + (delta * state.playbackRate), duration: state.duration)
    }

    func progressFraction(for elapsedTime: TimeInterval) -> Double {
        guard musicManager.playbackState.duration > 0 else { return 0 }
        return min(max(elapsedTime / musicManager.playbackState.duration, 0), 1)
    }

    func clampedElapsedTime(_ elapsedTime: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return max(0, elapsedTime) }
        return min(max(0, elapsedTime), duration)
    }

    func trimmedPlaybackText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Transport Button

private struct TransportButton: View {
    let systemName: String
    let shortcut: String?
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: isPrimary ? 13 : 11, weight: .semibold))
                .foregroundColor(.white.opacity(isPrimary ? 0.98 : 0.82))
                .frame(width: isPrimary ? 28 : 24, height: isPrimary ? 28 : 24)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isPrimary ? 0.12 : 0.05))
                )
        }
        .buttonStyle(.plain)
        .modifier(ShortcutTooltip(shortcut: shortcut))
    }
}
