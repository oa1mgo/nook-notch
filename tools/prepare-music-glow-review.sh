#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/build/MusicGlowEvaluation"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$OUTPUT_DIR"
cd "$PROJECT_DIR"

# Local evaluation only. Keep audio/credits out of app resources and releases.
names=(choice fishin waltz brahms jazz)
paths=(
  'admiralbob77_-_Choice_-_Drum-bass'
  'Karissa_Hobbs_-_Lets_Go_Fishin'
  '147793__setuniman__sweet-waltz-0i-22mi'
  'Hungarian_Dance_number_5_-_Allegro_in_F_sharp_minor_(string_orchestra)'
  'Kevin_MacLeod_-_Vibe_Ace'
)
audio_files=()
for index in "${!names[@]}"; do
  name="${names[$index]}"
  source_path="${paths[$index]}"
  if [[ ! -s "$OUTPUT_DIR/$name.ogg" ]]; then
    gh api "repos/librosa/data/contents/audio/$source_path.ogg" --jq '.content' \
      | base64 -D > "$OUTPUT_DIR/$name.ogg"
  fi
  gh api "repos/librosa/data/contents/audio/$source_path.txt" --jq '.content' \
    | base64 -D > "$OUTPUT_DIR/$name-license.txt"
  ffmpeg -v error -y -i "$OUTPUT_DIR/$name.ogg" -t 35 -ar 48000 -ac 1 "$OUTPUT_DIR/$name.wav"
  audio_files+=("$OUTPUT_DIR/$name.wav")
done

# These are generated baseline snapshots, not a second maintained implementation.
git show release/1.4.0:Nook/Services/Music/MusicSignalProcessor.swift \
  | sed 's/MusicSignalProcessor/LegacyMusicSignalProcessor/g' \
  > "$OUTPUT_DIR/LegacyMusicSignalProcessor.swift"
git show release/1.4.0:Nook/Services/Music/MusicAudioAnalyzer.swift \
  | awk '/^nonisolated private final class MusicAudioAnalysisWorker/ {exit} {print}' \
  | sed 's/MusicGlowEnvelope/LegacyMusicGlowEnvelope/g' \
  > "$OUTPUT_DIR/LegacyMusicGlowEnvelope.swift"

xcrun swiftc -O -D LEGACY_COMPARISON -parse-as-library \
  Nook/Services/Music/MusicSignalProcessor.swift \
  Nook/Services/Music/MusicTransientDetector.swift \
  Nook/Services/Music/MusicGlowEnvelope.swift \
  Nook/Services/Music/MusicReactiveEngine.swift \
  "$OUTPUT_DIR/LegacyMusicSignalProcessor.swift" \
  "$OUTPUT_DIR/LegacyMusicGlowEnvelope.swift" \
  tools/legacy-music-glow-review.swift tools/evaluate-music-glow.swift \
  -o "$OUTPUT_DIR/compare"
"$OUTPUT_DIR/compare" "${audio_files[@]}" > "$OUTPUT_DIR/comparison.json"
echo "Ready: serve the project on loopback and open /tools/music-glow-review.html"
