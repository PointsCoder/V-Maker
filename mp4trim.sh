#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# mp4trim.sh — Trim MP4 from [start, end) into a new MP4 using ffmpeg
#
# Features
#   - Accepts one or more inputs: files and/or directories (recursive *.mp4).
#   - Time can be given as seconds (e.g., 12.5) or HH:MM:SS(.ms) (e.g., 00:00:12.500).
#   - Two modes:
#       * --copy (default-fast): stream-copy, cut points align to nearest keyframe (no fps change).
#       * --reencode (default in this script): frame-accurate via H.264 re-encode (fps enforced).
#   - Re-encode options: CRF (-c/--crf), preset (-p/--preset), audio bitrate (-a/--audio-bitrate).
#   - NEW: Default mute outputs; use --audio to keep audio. Default output fps=30 (reencode only).
#   - Output files are written next to inputs with suffix “_trim_START_END.mp4” unless -o is given.
#   - Logs: verbose by default; use --quiet to show only ffmpeg errors.
#   - Requires: ffmpeg
#
# Usage
#   mp4trim.sh -s START -e END  [--copy|--reencode] [-c CRF] [-p PRESET] [-a AUDIO_BITRATE]
#              [-o OUTPUT_DIR] [--fps N] [--audio] [--quiet] <input_path>...
#   mp4trim.sh -s START -d DURATION  [--copy|--reencode] [...]
#
# Notes
#   - In copy mode, we place -ss BEFORE -i for speed; cuts may snap to keyframes. FPS is NOT changed.
#   - In reencode mode, we place -ss AFTER -i for accuracy and enforce fps via -vf "fps=fps=N".
#   - Outputs use yuv420p and +faststart in reencode mode for broad compatibility.
# -----------------------------------------------------------------------------

set -euo pipefail

print_usage() { sed -n '1,160p' "$0"; exit "${1:-1}"; }

# ------------------------------- Defaults ------------------------------------
start_arg=""
end_arg=""
duration_arg=""
mode="reencode"              # "copy" or "reencode"  (default: reencode)
crf=23
preset="medium"
audio_bitrate="128k"
output_dir=""
verbose=1                    # verbose by default

# NEW: default mute and fps
mute=1                       # 1 = drop audio by default; use --audio to keep
out_fps=30                   # default output fps for reencode mode

# ---------------------------- Parse arguments --------------------------------
inputs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--start)         start_arg="${2:?}"; shift 2 ;;
    -e|--end)           end_arg="${2:?}"; shift 2 ;;
    -d|--duration)      duration_arg="${2:?}"; shift 2 ;;
    --copy)             mode="copy"; shift ;;
    --reencode)         mode="reencode"; shift ;;
    -c|--crf)           crf="${2:?}"; shift 2 ;;
    -p|--preset)        preset="${2:?}"; shift 2 ;;
    -a|--audio-bitrate) audio_bitrate="${2:?}"; shift 2 ;;
    -o|--output-dir)    output_dir="${2:?}"; shift 2 ;;
    --fps)              out_fps="${2:?}"; shift 2 ;;     # NEW: set output fps (reencode only)
    --audio)            mute=0; shift ;;                 # NEW: keep audio if specified
    --quiet)            verbose=0; shift ;;
    -h|--help)          print_usage 0 ;;
    -*)
      echo "Error: unknown option: $1" >&2; print_usage 2 ;;
    *)
      inputs+=("$1"); shift ;;
  esac
done

# ------------------------------ Validation -----------------------------------
[[ -n "$start_arg" ]] || { echo "Error: --start is required." >&2; print_usage 2; }
if [[ -z "$end_arg" && -z "$duration_arg" ]]; then
  echo "Error: either --end or --duration is required." >&2; print_usage 2
fi
[[ ${#inputs[@]} -gt 0 ]] || { echo "Error: no input paths provided." >&2; print_usage 2; }
command -v ffmpeg >/dev/null 2>&1 || { echo "Error: ffmpeg not found in PATH." >&2; exit 1; }

# Reencode params sanity checks
if [[ "$mode" == "reencode" ]]; then
  [[ "$crf" =~ ^[0-9]+$ ]] || { echo "Error: CRF must be integer. Got: $crf" >&2; exit 1; }
  case "$preset" in
    ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow) ;;
    *) echo "Warning: unusual preset '$preset'." >&2 ;;
  esac
  [[ "$audio_bitrate" =~ ^[0-9]+k$ ]] || echo "Warning: audio bitrate '$audio_bitrate' not like '128k'." >&2
  [[ "$out_fps" =~ ^[0-9]+$ && "$out_fps" -ge 1 ]] || { echo "Error: --fps must be a positive integer. Got: $out_fps" >&2; exit 1; }
else
  # Copy mode ignores fps changes; we log a notice if user changed it
  if [[ "$out_fps" != "30" ]]; then
    echo "[INFO] --fps is ignored in --copy mode (stream copy keeps original fps)." >&2
  fi
fi

# Ensure output directory exists if provided
if [[ -n "$output_dir" ]]; then
  mkdir -p "$output_dir"
fi

# ------------------------------ Helpers --------------------------------------
# We pass user time strings directly to ffmpeg; here only build labels.
label_from_time() {
  local t="$1"
  echo "$t" | sed -E 's/:/-/g; s/\./-/g'
}

# Collect MP4 files from inputs
mapfile -t mp4_files < <(
  for p in "${inputs[@]}"; do
    if [[ -d "$p" ]]; then
      find "$p" -type f \( -iname '*.mp4' \)
    elif [[ -f "$p" ]]; then
      case "${p##*.}" in
        mp4|MP4) echo "$p" ;;
        *) echo "Skipping non-MP4: $p" >&2 ;;
      esac
    else
      echo "Warning: path not found or unsupported: $p" >&2
    fi
  done
)
[[ ${#mp4_files[@]} -gt 0 ]] || { echo "No MP4 files found to process." >&2; exit 1; }

# Determine end time or duration to use
ff_start="$start_arg"
ff_end="$end_arg"
ff_duration="$duration_arg"

# Build labels for filenames
start_label="$(label_from_time "$ff_start")"
if [[ -n "$ff_end" ]]; then
  end_label="$(label_from_time "$ff_end")"
else
  end_label="dur$(label_from_time "$ff_duration")"
fi

# ffmpeg loglevel
ff_loglevel=info
(( verbose == 0 )) && ff_loglevel=error

# ------------------------------ Trim logic -----------------------------------
trim_copy() {
  # Fast path: -ss before -i; may snap to previous keyframe. FPS unchanged.
  # If mute==1, we drop audio via -an while copying the video stream.
  local in="$1" out="$2"
  if [[ -n "$ff_end" ]]; then
    if (( mute == 1 )); then
      ffmpeg -v "$ff_loglevel" -y -ss "$ff_start" -to "$ff_end" -i "$in" \
        -c copy -an -movflags +faststart -map_metadata -1 "$out"
    else
      ffmpeg -v "$ff_loglevel" -y -ss "$ff_start" -to "$ff_end" -i "$in" \
        -c copy -movflags +faststart -map_metadata -1 "$out"
    fi
  else
    if (( mute == 1 )); then
      ffmpeg -v "$ff_loglevel" -y -ss "$ff_start" -t "$ff_duration" -i "$in" \
        -c copy -an -movflags +faststart -map_metadata -1 "$out"
    else
      ffmpeg -v "$ff_loglevel" -y -ss "$ff_start" -t "$ff_duration" -i "$in" \
        -c copy -movflags +faststart -map_metadata -1 "$out"
    fi
  fi
}

trim_reencode() {
  # Accurate path: -ss AFTER -i; enforce fps via -vf "fps=fps=out_fps"; yuv420p; +faststart.
  # If mute==1, drop audio with -an; else encode AAC at requested bitrate.
  local in="$1" out="$2"
  if [[ -n "$ff_end" ]]; then
    if (( mute == 1 )); then
      ffmpeg -v "$ff_loglevel" -y -i "$in" -ss "$ff_start" -to "$ff_end" \
        -vf "fps=fps=${out_fps}" -vsync cfr \
        -c:v libx264 -crf "$crf" -preset "$preset" -pix_fmt yuv420p \
        -an \
        -movflags +faststart -map_metadata -1 "$out"
    else
      ffmpeg -v "$ff_loglevel" -y -i "$in" -ss "$ff_start" -to "$ff_end" \
        -vf "fps=fps=${out_fps}" -vsync cfr \
        -c:v libx264 -crf "$crf" -preset "$preset" -pix_fmt yuv420p \
        -c:a aac -b:a "$audio_bitrate" \
        -movflags +faststart -map_metadata -1 "$out"
    fi
  else
    if (( mute == 1 )); then
      ffmpeg -v "$ff_loglevel" -y -i "$in" -ss "$ff_start" -t "$ff_duration" \
        -vf "fps=fps=${out_fps}" -vsync cfr \
        -c:v libx264 -crf "$crf" -preset "$preset" -pix_fmt yuv420p \
        -an \
        -movflags +faststart -map_metadata -1 "$out"
    else
      ffmpeg -v "$ff_loglevel" -y -i "$in" -ss "$ff_start" -t "$ff_duration" \
        -vf "fps=fps=${out_fps}" -vsync cfr \
        -c:v libx264 -crf "$crf" -preset "$preset" -pix_fmt yuv420p \
        -c:a aac -b:a "$audio_bitrate" \
        -movflags +faststart -map_metadata -1 "$out"
    fi
  fi
}

# ------------------------------ Main loop ------------------------------------
export LC_ALL=${LC_ALL:-C.UTF-8}

for inmp4 in "${mp4_files[@]}"; do
  dir="$(dirname "$inmp4")"
  base="$(basename "$inmp4")"
  name="${base%.*}"

  # Decide output path
  if [[ -n "$output_dir" ]]; then
    out="${output_dir}/${name}_trim_${start_label}_${end_label}.mp4"
  else
    out="${dir}/${name}_trim_${start_label}_${end_label}.mp4"
  fi

  echo "[INFO] Trimming: $inmp4 -> $out (mode=${mode}, start=${ff_start}, end=${ff_end:-"-"}, duration=${ff_duration:-"-"}, mute=${mute}, fps=${out_fps})"

  if [[ "$mode" == "copy" ]]; then
    trim_copy "$inmp4" "$out"
  else
    trim_reencode "$inmp4" "$out"
  fi

  echo "[OK]   Wrote: $out"
done

echo "Done. Processed ${#mp4_files[@]} file(s)."
