# Music Glow: distinguish an attack from its importance

## Feedback and scope

After 1.4.1, the user still heard missed heavy accents and saw flashes in unconvincing places, varying by song. Keep the approved glow geometry, album colors, 18% ambient floor, 50ms attack, and interval-dependent release. Change only worker-side analysis and event selection. No extra permissions, recording, model download, BPM lock, or synthetic pulses. The permission-free outer Music Glow is unchanged.

This refines the [1.4.1 transient engine](2026-09-11-music-glow-transients.md); it is not instrument separation or a trained downbeat detector.

## Reproduced problems before changing production code

Four new synthetic PCM tests failed against 1.4.1 (the fifth, kicks over sustained bass, already passed and is retained as a guard):

- A quiet 350Hz pickup 160ms before each 80Hz kick took all eight kick slots. Independently whitened bands could each appear equally strong, so the normalized-score replacement rule rejected the actually louder kick.
- Alternating low and 1.1kHz attacks at 300ms separation returned only eight of sixteen attacks. Frequency weighting and the additional `gap < 340ms && relative < 0.85` veto removed the middle-frequency attacks.
- A quiet new frequency band over sustained bass was promoted to roughly 70–97% accent strength because it was judged mainly against its own previously empty band.
- Smooth 3Hz amplitude modulation of a sustained bass tone gradually learned its own strength reference and became repeated bright accents.

These demonstrate concrete failure modes, not a diagnosis of every song the user heard.

## Revised responsibilities

### Signal processor: three complementary measurements

Reuse the existing FFT and frequency-neighbor maximum filter. The compact display bars, their smoothing, and the FFT/hop sizes do not change.

- **Local novelty** (`onsetBands`): spectral rise relative to the band's recent energy. This retains within-instrument strong/weak relationships instead of treating every isolated event equally.
- **Actual energy / mix impact** (`onsetEnergies`, `onsetImpacts`): unwhitened spectral rise, and that rise relative to the whole signal. Impact uses `max(current RMS, 0.35 × decaying mix peak)` with an 800ms peak time constant. A dying tail or a tiny newly occupied band cannot normalize itself to a main accent.
- **Attack contrast** (`onsetContrasts`): newly arriving energy as a fraction of the band's energy, normalized to a 10.67ms reference hop. Requiring contrast of at least 0.12 rejects the tested smooth amplitude modulation; the same time normalization is used across sample rates. This is a causal sharpness heuristic, not a full tremolo-suppression model.

The existing frequency-neighbor suppression is inspired by [Böck and Widmer's SuperFlux work](https://github.com/CPJKU/SuperFlux). That work also distinguishes the additional tremolo-suppression problem; frequency movement suppression alone should not be presented as solving amplitude modulation. Our contrast gate is a separate, locally tested heuristic, not their phase-based ComplexFlux implementation.

### Detector: independent evidence, shared musical importance

1. Bass, body, and presence each get their own adaptive noise threshold, causal peak confirmation, and recent local-novelty reference. Air alone remains excluded. Peaks are picked from **mix impact**, not self-normalized novelty, avoiding premature peaks in a newly occupied band.
2. A four-second, upper-quartile reference is used for local prominence. References are bounded to 48 observations and cluster observations within 75ms; one multi-band attack must not count as several votes.
3. A second reference uses actual attack energy across the mix. Its soft weighting reduces the brightness of minor accompaniment without imposing the old all-or-nothing cross-instrument veto. Final strength combines local prominence, mix prominence, foreground impact, and loudness. Near-invisible results below 0.20 do not consume the flash cooldown or influence release pacing.
4. Keep the ordinary 240ms separation and 100ms minimum for a stronger replacement. Replacement compares **actual energy** (1.6×), not separately normalized scores. Update the previous attack's energy over its first 70ms so a partial first FFT does not make the next equal roll hit look like a stronger replacement.
5. Remove the separate 340ms/85% veto. Legitimate kick/midrange alternation is no longer discarded by that extra gate. There is still no predictive scheduling, beat-stride selection, or invented flash.

Snapshots, capture timestamps, stale-data rejection, ambient lifetime, pause behavior, and UI rendering are unchanged. No new FFT, audio callback work, or timer is introduced; added histories and per-band metrics are bounded.

## Verification and limits

- Full macOS suite: **76 tests, 0 failures**, including 27 engine tests (9 new).
- Debug and Release builds passed; `./script/build_and_run.sh --verify` successfully launched the revised Debug app. Work was developed on `feature/music-glow-accent-refinement`; after reviewing the result, the user approved main integration and release 1.4.2 together with the Retina installer fix.
- New cases cover mixed-instrument pickups, alternating low/midrange accents, quiet decorations over bass, audible kicks over bass, smooth bass tremolo, synthesized kick/snare/hat mixtures, long pitch-swept kick tails, several FFT alignments/chunk sizes, and melodic pitch glides.
- Existing tests still cover 80/120/160 BPM, three-beat strong/weak patterns, dense-roll suppression, high-frequency hats, volume scaling, 44.1/48/96kHz, silence, resets, stale samples, invalid samples, ambient light, and missed UI frames.
- Five existing licensed recording excerpts were run through the 1.4.1 and revised production engines. These recordings are **not hand-labelled**, so neither event counts nor test passes are claimed as musical accuracy or listening acceptance.

| Recording | 1.4.1 events | Revised events | 1.4.1 / revised events with strength > 0.6 |
| --- | ---: | ---: | ---: |
| Choice, 25s | 43 | 54 | 27 / 36 |
| Let's Go Fishin', 35s | 84 | 105 | 60 / 71 |
| Sweet Waltz, 35s | 80 | 81 | 48 / 56 |
| Hungarian Dance #5, 35s | 85 | 107 | 56 / 54 |
| Vibe Ace, 35s | 78 | 97 | 61 / 62 |

The increased counts are an explicit live-listening risk, not a success metric: more real attacks are eligible now, particularly alternating instruments. Soft mix weighting keeps the extra detections from all becoming equally bright. If a style still feels too busy, investigate actual candidate importance rather than restoring an arbitrary BPM stride or changing the approved glow opacity.

Optimized offline evaluation of all ~165s of audio took 0.34s (baseline) versus 0.35s (revised) in one process-level measurement. Peak resident memory was 20,152,320 versus 20,299,776 bytes. Individual revised clips required about 0.05–0.067s of processing. These include evaluator overhead and exclude live capture and SwiftUI; they are **not total Nook CPU/memory measurements**. No heavy model or audio buffer growth was added.

End-to-end acoustic timing, Bluetooth compensation, and perceptual acceptance remain live-listening checks. No claim is made to reproduce Tesla's implementation or identify the true musical downbeat in arbitrary music.

## Reproduction

Run the engine tests or full suite with Xcode selected explicitly if `xcode-select` points to Command Line Tools. Quit the running Nook first: its existing single-instance protection otherwise exits the hosted test runner before XCTest connects.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Nook.xcodeproj -scheme Nook -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/CodexDerivedData test
```

Use `tools/evaluate-music-glow.swift` and the compile command in the [original evaluation instructions](2026-09-11-music-glow-transients.md#reproducible-evaluation). Build the same evaluator once against the five music-engine files from `release/1.4.1`, and once against the working tree. Feed both the identical mono WAV files; no captured user audio is needed. This run's generated binaries, JSON reports, resource measurements, and test logs are in ignored `build/MusicGlowRefinement/` (`baseline.json`, `refined.json`, `full-tests.log`). The original five-style audio corpus and credits remain in `build/MusicGlowEvaluation/`; nothing is added to app resources.

For a user's live check, build/launch with `./script/build_and_run.sh --verify` and use their existing Beta opt-in state. Do not enable capture or change permissions on their behalf.
