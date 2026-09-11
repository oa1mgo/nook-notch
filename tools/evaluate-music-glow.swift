// Build instructions and recording credits: docs/specs/2026-09-11-music-glow-transients.md
import AVFoundation
import Foundation

@main
struct EvaluateMusicGlow {
    static func main() throws {
        var reports: [[String: Any]] = []
        for path in CommandLine.arguments.dropFirst() {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let rate = file.processingFormat.sampleRate
            guard let engine = MusicReactiveEngine(sampleRate: rate),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512) else {
                throw NSError(domain: "MusicGlowEvaluation", code: 1)
            }
            var total: Int64 = 0
            var accents: [[String: Any]] = []
            var levels: [[Double]] = []
            #if LEGACY_COMPARISON
            let legacy = LegacyMusicReviewEngine(sampleRate: rate)
            #endif
            let start = ProcessInfo.processInfo.systemUptime
            while file.framePosition < file.length {
                try file.read(into: buffer, frameCount: 512)
                guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }
                total += Int64(buffer.frameLength)
                let time = Double(total) / rate
                engine.ingest(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)), endingAt: time, now: time) {
                    accents.append(["time": $0.timestamp, "strength": $0.strength, "interval": $0.interval ?? 0])
                }
                #if LEGACY_COMPARISON
                legacy.ingest(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)), at: time)
                levels.append([time, Double(engine.envelope.value(at: time)), Double(legacy.value)])
                #else
                levels.append([time, Double(engine.envelope.value(at: time))])
                #endif
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            reports.append(["file": URL(fileURLWithPath: path).lastPathComponent,
                "duration": Double(total) / rate, "processingSeconds": elapsed,
                "accents": accents, "envelope": levels])
        }
        let data = try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}
