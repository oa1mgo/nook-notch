# Music Glow: audio-timestamped transients

## Why 1.4.0 needed a new engine

The old path was `40–160 Hz flux → UI aggregation → BPM lock → 2/4-beat stride → 1.15s cooldown → fixed 50/80/650ms pulse`. Those gates systematically discarded audible attacks. Before a lock, or when irregular music lost the lock, a three-second oscillator generated light unrelated to the music. Onsets and their order were reduced to one maximum per UI update; processing was therefore affected by UI scheduling.

The user approved the glow's existing size, colors, blur, and opacity treatment. Those remain unchanged. This change replaces detection and animation timing, behind the existing opt-in Beta switch. The outer permission-free Music Glow still uses its original simulated breathing. Capture/permission policy is unchanged.

## New path and responsibilities

1. `NookSystemAudioCapture`: the realtime callback stores mono Float32 samples and Core Audio host timestamps in its bounded ring. No DSP, locks, allocation, or logging on the callback. If the consumer falls behind, read the newest buffer-sized suffix, not an old queue of beats. The extra timestamp storage is about 1 MiB.
2. `MusicSignalProcessor`: 2048-sample Hann FFT with a 512-sample hop (10.67ms at 48kHz). Sample counters preserve the analysis clock across arbitrary capture chunk boundaries. Per-band positive spectral change is measured against a one-bin maximum of the previous spectrum, suppressing sideways pitch motion. A signal-energy floor avoids amplifying empty bands. Display bars are separately smoothed.
3. `MusicTransientDetector`: one-frame causal peak confirmation, adaptive noise threshold, and a rolling four-second strength reference. Low-frequency attacks are primary; body/presence attacks admit snare and acoustic percussion. Air alone cannot trigger the entire notch. The upper-quartile reference excludes weak ghost notes without letting one outlier suppress the whole song. Ordinary equal-strength attacks have a 240ms separation; a clearly stronger attack can replace a weak pickup after 100ms. No beat lock, fixed stride, inferred downbeat, or predictive pulse scheduling.
4. `MusicReactiveEngine`: runs every FFT frame on the worker, maps its sample time to host time, resets on capture discontinuities, and drops audio more than 120ms late. Track changes reset DSP/reference history while the already-visible tail finishes. Real onsets can respond immediately after the first complete analysis window of the new source.
5. `MusicGlowEnvelope`: a value object containing the original hit timestamp, strength, start level, and decay. Attack remains 50ms. The 80ms flat crest is removed. Release is a finite quadratic fade, `clamp(0.9 × recent-hit interval − 50ms, 220ms, 650ms)`. Sparse material keeps 650ms; dense material reaches darkness before the following normal hit. Sampling the envelope after a missed frame cannot restart it.
6. Worker snapshots: accents are published immediately; bars at about 30Hz. A latest-value relay coalesces main-actor deliveries **after** all onset analysis, preserving the current gesture instead of dropping analysis frames. `TimelineView` samples only the glow layer at 60Hz with a monotonic clock. No additional SwiftUI opacity animation wraps the reactive curve.

With active Beta analysis, no detected attack means the tail decays to dark; uncertain tempo no longer produces synthetic breathing. This deliberately replaces the earlier requested three-second acquisition fallback because it conflicts with the new requirement that flashes fit the actual music.

## Evidence and limits

- Full macOS suite: 56 tests pass, including 17 PCM/envelope regression tests. The obsolete tests asserting BPM lock, fixed stride, and synthetic fallback were removed; spectrum, permission/presentation policy, metadata, and other app regressions remain covered.
- PCM tests cover 80/120/160 BPM, syncopation, tempo changes, accented 3/4 patterns, quiet pickups preceding strong hits, rapid rolls, high-frequency hats, midrange percussion, vibrato, 44.1/48/96kHz, volume scaling, irregular capture chunks, silence, stale samples, track reset, invalid samples, and missed render frames. Known hard-hit timestamps must match within 70ms with expected counts; this is a synthetic detector test, not a claim about Bluetooth/audio-device end-to-end latency.
- Five actual recording excerpts are decoded to 48kHz mono and passed through the same engine, without playing or storing captured user audio: Choice (25.0s), Let's Go Fishin' (35s), Sweet Waltz (35s), Hungarian Dance #5 (35s), Vibe Ace (35s).
- Offline processing-only timing was approximately 0.05–0.07s per 25–35s recording on this Mac in an optimized build. This is not a measurement of total Nook CPU usage or UI rendering costs.
- `tools/music-glow-review.html` presents synchronized audio and old/new brightness curves. The old side uses actual 1.4.0 source with an approximate 30Hz aggregation cadence. Neither side simulates hardware-output or UI-scheduling latency. Sample audition, style switching, and data loading were checked in the in-app browser.
- Accent counts are not musical accuracy scores. These music examples have no hand-labelled downbeats in this evaluation. This is a causal signal-based detector, not instrument separation, a trained downbeat model, or a reproduction of Tesla's proprietary implementation. Bluetooth output delay is not automatically calibrated.

## Reproducible evaluation

All generated files live in ignored `build/MusicGlowEvaluation/`. No third-party audio belongs in the app or a release. Use `tools/prepare-music-glow-review.sh` to download the public sample corpus, reconstruct the baseline from `release/1.4.0`, compile both engines, and generate `comparison.json`. It requires the installed `gh`, `ffmpeg`, and Xcode toolchain. Then serve the repository on loopback:

```sh
python3 -m http.server 8765 --bind 127.0.0.1
```

Open `http://127.0.0.1:8765/tools/music-glow-review.html`. The page is paused initially. Choose a style and play, seek, or restart to compare the same moment. It approximates glow appearance with CSS and uses the production visibility mapping; the live SwiftUI glow remains the definitive appearance.

For new local WAV samples, the standalone evaluator accepts file paths and outputs JSON. Decode inputs to mono first. Compile without `LEGACY_COMPARISON` to evaluate the production engine only:

```sh
xcrun swiftc -O -parse-as-library \
  Nook/Services/Music/MusicSignalProcessor.swift \
  Nook/Services/Music/MusicTransientDetector.swift \
  Nook/Services/Music/MusicGlowEnvelope.swift \
  Nook/Services/Music/MusicReactiveEngine.swift \
  tools/evaluate-music-glow.swift -o build/MusicGlowEvaluation/evaluate
build/MusicGlowEvaluation/evaluate /absolute/path/to/mono.wav
```

## Diagnosing a live timing complaint

Enable the existing Debug log toggle, reproduce, and inspect `[music-glow] accent` in `/tmp/nook-debug.log`. `age_ms` is host-clock event age at main-actor delivery; `peak` and `release_ms` describe the gesture. There is no PCM, song name, or audio recording in this log. Regularly large event ages point to capture/main-thread latency; low event ages with perceived early light may indicate output-device latency; timely but musically inappropriate events require detector analysis against a concrete clip. The log does not prove acoustic timing by itself.

## Sources and recording credits

- [Tesla Model 3 manual: Light Sync](https://www.tesla.com/ownersmanual/model3/en_us/GUID-79A49D40-A028-435B-A7F6-8E48846AB9E9.html): confirms the beats/rhythm effect; does not disclose its algorithm.
- [LedFx melbank architecture](https://docs.ledfx.app/en/latest/developer/melbanks.html): inspiration for frequency-dependent response, not code copied into Nook.
- [Böck & Widmer, Maximum Filter Vibrato Suppression for Onset Detection, DAFx 2013](https://www.dafx.de/paper-archive/2013/papers/09.dafx2013_submission_12.pdf): inspiration for previous-spectrum maximum filtering. Nook uses coarse band aggregation, not the complete SuperFlux algorithm.
- [aubio onset API](https://aubio.org/doc/latest/onset_8h.html): causal peak-picking, silence threshold, and minimum-inter-onset concepts.
- [librosa example recordings](https://librosa.org/doc/latest/recordings.html) / [source corpus and individual license files](https://github.com/librosa/data/tree/main/audio).
- Choice — Admiral Bob, CC BY-NC (drum/bass excerpt edited by Brian McFee).
- Let's Go Fishin' — Karissa Hobbs, CC BY 3.0.
- Sweet Waltz — Setuniman, CC BY-NC 3.0.
- Hungarian Dance #5 — US Army Strings, Public Domain.
- Vibe Ace — Kevin MacLeod, CC BY 3.0.
