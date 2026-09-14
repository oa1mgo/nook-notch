# Music Glow: give sparse passages a visible tail

## Scope

User-approved follow-up to 1.4.2: slower music, or a passage whose accents become more widely spaced, should return to the ambient color more gently. Keep the 50ms attack, immediate decline after the peak, album colors, glow geometry, 95% maximum opacity, and 18% ambient floor. Do not change which accents are detected, permissions, the regular permission-free glow, or the version number.

This supersedes only the release-timing portion of the [original transient design](2026-09-11-music-glow-transients.md). The [1.4.2 accent detector](2026-09-14-music-glow-accent-refinement.md) is unchanged.

## Why a larger duration alone was insufficient

The old release was capped at 650ms and used `(1 - progress)^2`. Appearance then applies a threshold and smoothstep to intensity. Thus much of the nominal tail was already invisible. For a full-strength, isolated accent, displayed accent opacity fell below 5% of its peak about 382ms after the hit, including the 50ms attack. That is a reproducible curve measurement, not a universal human visibility threshold.

## Animation policy

`MusicGlowEnvelope.ReleasePacing` is a bounded, constant-size animation context. It is not BPM estimation, musical downbeat recognition, or a new detector.

- Ordinary material retains the existing median-based nominal release, `clamp(0.9 × detector interval - 50ms, 220ms, 650ms)`. Unknown pace starts at 650ms. Invalid intervals cannot poison the curve.
- Three consecutive actual accent gaps must support a duration above 650ms before extending it. The shorter of the last two gaps determines the supported duration, capped at 1.5s. Extension is limited to 250ms per accepted accent. One missing hit cannot establish a sparse passage; the existing five-gap detector median still handles the ordinary duration.
- The last three accents must include one foreground-strength anchor (at least 0.45). Do **not** require all three to be bright: the existing detector can assign very different brightness to identical synthetic drum hits at different FFT phases. Weak-only decoration cannot establish long tails; an existing extension relaxes toward the ordinary duration when foreground evidence expires.
- A new shorter gap immediately caps an already-extended gesture. A temporary cap bridges the detector median's lag; subsequent corroborated spacing can relax it, so a fast transition cannot permanently pin later medium-speed music to a short release. Ordinary syncopation without an extended tail is not shortened by every individual raw gap.
- Sub-240ms pickup replacements do not establish a new pace. Gaps over 2.5s discard stale pacing context. Track/capture-analysis resets also clear this context, while preserving every sampled point of the already-visible gesture.
- The first 50ms and its peak strength are unchanged. Release becomes `peak × r × (r + softness × progress)`, where `r = 1 - progress`. Once adjacent gaps have a foreground anchor, softness moves from 0 to 1 as nominal release moves from 400ms to 1.1s. This interpolates quadratic toward linear decay without a plateau or a new brightness mapping. Dense gestures at or below 400ms retain the old quadratic curve exactly.
- Existing ambient signal gating and the 450ms pause fade are unchanged. With silence or missing samples, an accent can finish its finite gesture (at most 1.55s including attack), but cannot renew it. Do not multiply the accent by a signal gate that reopens on resumed audio: that can brighten an old tail without a new attack. Resuming signal during a tail is covered by a continuity regression.

No extra FFT, audio buffer, capture work, timer, or SwiftUI animation was added. Sampling remains timestamp-based; missed UI frames cannot stretch a gesture. The evaluator now includes each accent's nominal `release` duration for diagnosis.

## Deterministic curve check

Settled full-strength accents with continuous audible background, sampled at 1ms. The visible-end column means the last point where accent-only opacity exceeds 5% of peak, measured from onset; it excludes the unchanged ambient floor.

| Actual accent gap | New nominal release | Old / new visible end |
| --- | --- | --- |
| 375ms | 288ms | 196 / 196ms |
| 500ms | 400ms | 254 / 254ms |
| 750ms | 625ms | 369 / 423ms |
| 1.0s | 850ms | 382 / 631ms |
| 1.2s | 1.03s | 382 / 813ms |
| 1.5s | 1.30s | 382 / 1.039s |
| 2.2s | 1.50s | 382 / 1.191s |

These are accent intervals, **not** a song's BPM. Weaker peaks naturally have less visible tail. A slow song containing frequent accepted attacks will not automatically get long pulses.

## Verification

- Full macOS suite: **99 tests, 0 failures** (76 previous + 23 new). New tests include 17 envelope tests, four appearance tests, and two PCM integration tests. Existing onset, signal, presentation, permission, and app tests remain passing.
- Before production changes, six of the initial 11 new envelope tests failed, reproducing the duration cap, stale-interval adaptation, and invalid-interval issues. PCM integration additionally caught the overly strict all-bright confidence gate. A raw-gap-only prototype made ordinary syncopated recordings snappier; the final policy preserves ordinary median-based durations instead.
- Synthetic PCM verifies slow accents, fast → slow → fast passages, unchanged event timing/counts, and track-reset wiring. Unit tests cover moderate-speed recovery, missing hits, weak decoration, alternating strengths, finite tails, immediate decline, continuity on retrigger/resume, clock shifts, and pause/silence.
- The same five licensed recording excerpts used for 1.4.2 were processed through pre-change and revised engines: **all 444 accent timestamps, strengths, and interval values match exactly**. These mostly dense excerpts do not exercise sustained sparse passages; their nominal releases remain at or below 650ms. Mean displayed opacity changes were small (Choice 0.291 → 0.296, Fishin' 0.300 → 0.300, Waltz 0.289 → 0.290, Brahms 0.272 → 0.272, Jazz 0.297 → 0.297).
- Additional local half-speed derivatives made with FFmpeg `atempo=0.5` exercise longer spacing, without changing pitch: Waltz has 98 identical events in both engines, with 44 revised releases above 650ms (maximum 680ms); Choice has 74 identical events, with seven above 650ms (maximum 1.054s). These are transformed regression fixtures, **not naturally slow songs or listening-accuracy evidence**. No audio was added to app resources or recorded from the user.
- Debug build and launch use the existing `./script/build_and_run.sh --verify` entrypoint. No Beta preference or permission is enabled on the user's behalf. Acoustic synchronization, Bluetooth delay, and whether the feel is better remain live-listening checks; passing tests is not perceptual acceptance.

## Reproduction

Quit Nook before hosted tests to avoid its single-instance guard. Run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Nook.xcodeproj -scheme Nook -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/CodexDerivedData test
./script/build_and_run.sh --verify
```

For recordings, use the [existing evaluator compile command](2026-09-11-music-glow-transients.md#reproducible-evaluation). This run's baseline/revised JSON, diagnostic/full test logs, curve probe, and temporary slowed fixtures are in ignored `build/MusicGlowAdaptiveRelease/`; original recording licenses remain in `build/MusicGlowEvaluation/`. Compare only `time`, `strength`, and `interval` when asserting event identity, since the revised evaluator adds `release`.
