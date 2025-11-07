#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# mp4speed.sh — Speed up MP4 playback by N× (video + audio) using ffmpeg
#
# Features
#   - Accepts one or more inputs: files and/or directories (recursive *.mp4).
#   - Speeds up both video and audio by factor N (e.g., 2.0 = 2× faster).
#   - Video: setpts = PTS / N; Audio: auto-built atempo chain (0.5–2.0 per stage).
#   - If an input has no audio stream, audio processing is skipped automatically.
#   - Re-encode options: CRF (-c/--crf) and preset (-p/--preset).
#   - Outputs are written next to inputs with suffix “_speedN.mp4” (or -o dir).
#   - Logs: verbose by default; use --quiet to show only ffmpeg errors.
#   - Requires: ffmpeg (and ffprobe for auto audio-detection).
#
# Usage
#   mp4speed.sh -n SPEED [-c CRF] [-p PRESET] [-o OUTPUT_DIR] [--quiet]
#                [--fps FPS] [--unmute|--mute] <input_path>...
#
# Arguments
#   -n, --speed          Speed factor N (>0). Examples: 2, 1.5, 3.75, 0.5.
#   -c, --crf            H.264 CRF 0–51 (lower = higher quality). Default: 23.
#   -p, --preset         {ultrafast, superfast, veryfast, faster, fast, medium,
#                         slow, slower, veryslow}. Default: medium.
#   -o, --output-dir     Directory to place outputs. Default: alongside inputs.
#       --quiet          Only show ffmpeg errors (default is verbose logs).
#   -h, --help           Show this help.
#   --fps FPS            (NEW) Force output constant frame rate to FPS (e.g., 30).
#   --mute | --no-audio  (NEW) Forcefully disable audio in outputs (use -an).
#   --unmute             (NEW) Override default mute; keep/process audio if present.
#
# Examples
#   # 1) 2× speed (video only by default mute), default quality, force 30 fps
#   ./mp4speed.sh -n 2 --fps 30 /path/video.mp4
#
#   # 2) 1.25× speed with higher quality encode, keep audio
#   ./mp4speed.sh -n 1.25 --unmute -c 20 -p slow /path/video.mp4
#
#   # 3) Batch: speed up all MP4s in a folder by 4×, logs quiet, force 60 fps
#   ./mp4speed.sh -n 4 --fps 60 --quiet /path/to/folder
#
#   # 4) Write outputs to a specific directory (muted by default)
#   ./mp4speed.sh -n 3 -o out_dir movie.mp4 clips/
#
#   # 5) (Optional) Slow down to 0.5×, keep audio
#   ./mp4speed.sh -n 0.5 --unmute /path/video.mp4
#
# Notes
#   - Audio “atempo” only accepts 0.5–2.0 per filter. This script auto-chains
#     multiple atempo filters (e.g., 8× => atempo=2.0,atempo=2.0,atempo=2.0;
#     0.25× => atempo=0.5,atempo=0.5).
#   - Outputs use yuv420p and +faststart for wide compatibility and web playback.
# -----------------------------------------------------------------------------

set -euo pipefail

print_usage() { sed -n '1,200p' "$0"; exit "${1:-1}"; }

# ------------------------------- Defaults ------------------------------------
speed=""
crf=23
preset="medium"
output_dir=""
verbose=1
mute=1          # NEW DEFAULT: start muted (video-only) unless --unmute is passed.
force_fps=""    # NEW: when set (e.g., "30"), force output CFR to this FPS.

# ---------------------------- Parse arguments --------------------------------
inputs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--speed)        speed="${2:?}"; shift 2 ;;
    -c|--crf)          crf="${2:?}"; shift 2 ;;
    -p|--preset)       preset="${2:?}"; shift 2 ;;
    -o|--output-dir)   output_dir="${2:?}"; shift 2 ;;
    --quiet)           verbose=0; shift ;;
    --fps)             force_fps="${2:?}"; shift 2 ;;     # NEW: parse forced FPS.
    --mute|--no-audio) mute=1; shift ;;                   # Keep explicit mute.
    --unmute)          mute=0; shift ;;                   # NEW: allow enabling audio.
    -h|--help)         print_usage 0 ;;
    -*)
      echo "Error: unknown option: $1" >&2; print_usage 2 ;;
    *)
      inputs+=("$1"); shift ;;
  esac
done

# ------------------------------ Validation -----------------------------------
[[ -n "$speed" ]] || { echo "Error: --speed is required." >&2; print_usage 2; }
awk -v s="$speed" 'BEGIN{ if (s+0<=0) exit 1 }' || { echo "Error: --speed must be > 0. Got: $speed" >&2; exit 1; }

[[ ${#inputs[@]} -gt 0 ]] || { echo "Error: no input paths provided." >&2; print_usage 2; }
command -v ffmpeg  >/dev/null 2>&1 || { echo "Error: ffmpeg not found in PATH." >&2; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo "Error: ffprobe not found in PATH (needed for audio detection)." >&2; exit 1; }

[[ "$crf" =~ ^[0-9]+$ ]] || { echo "Error: CRF must be integer. Got: $crf" >&2; exit 1; }
case "$preset" in
  ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow) ;;
  *) echo "Warning: unusual preset '$preset'." >&2 ;;
esac
if [[ -n "$force_fps" ]]; then
  awk -v f="$force_fps" 'BEGIN{ if (f+0<=0) exit 1 }' || { echo "Error: --fps must be > 0. Got: $force_fps" >&2; exit 1; }
fi

if [[ -n "$output_dir" ]]; then
  mkdir -p "$output_dir"
fi

# ------------------------------ Helpers --------------------------------------
# Build an atempo filter chain with repeated filter names (0.5–2.0 per stage).
build_atempo_chain() {
  local target="$1"
  local stages=()
  while awk -v t="$target" 'BEGIN{exit !(t>2.0000001)}'; do
    stages+=("2.0"); target=$(awk -v t="$target" 'BEGIN{printf "%.9f", t/2.0}')
  done
  while awk -v t="$target" 'BEGIN{exit !(t<0.4999999)}'; do
    stages+=("0.5"); target=$(awk -v t="$target" 'BEGIN{printf "%.9f", t*2.0}')
  done
  if ! awk -v t="$target" 'BEGIN{exit (t>0.9995 && t<1.0005)}'; then
    if awk -v t="$target" 'BEGIN{exit !(t<0.5)}'; then target="0.5"; fi
    if awk -v t="$target" 'BEGIN{exit !(t>2.0)}'; then target="2.0"; fi
    stages+=("$(awk -v t="$target" 'BEGIN{printf "%.6f", t}')")
  fi
  local out="" v
  for v in "${stages[@]}"; do
    if [[ -z "$out" ]]; then out="atempo=${v}"; else out="${out},atempo=${v}"; fi
  done
  [[ -n "$out" ]] || out="atempo=1.0"
  echo "$out"
}

label_from_speed() { echo "$1" | sed -E 's/\./-/g'; }

# Collect MP4 files from inputs (files or directories).
mapfile -t mp4_files < <(
  for p in "${inputs[@]}"; do
    if [[ -d "$p" ]]; then
      find "$p" -type f -iname '*.mp4'
    elif [[ -f "$p" ]]; then
      case "${p##*.}" in mp4|MP4) echo "$p" ;; *) echo "Skipping non-MP4: $p" >&2 ;; esac
    else
      echo "Warning: path not found or unsupported: $p" >&2
    fi
  done
)
[[ ${#mp4_files[@]} -gt 0 ]] || { echo "No MP4 files found to process." >&2; exit 1; }

# ffmpeg loglevel
ff_loglevel=info
(( verbose == 0 )) && ff_loglevel=error

# ------------------------------ Main loop ------------------------------------
export LC_ALL=${LC_ALL:-C.UTF-8}
speed_label="$(label_from_speed "$speed")"
atempo_chain="$(build_atempo_chain "$speed")"
setpts_expr="$(awk -v s="$speed" 'BEGIN{printf "PTS/%.9f", s+0.0}')"  # (kept for readability; not used below)

# Decide output CFR (use --fps if provided; otherwise probe first input; fallback 30).
probe_file="${mp4_files[0]}"
if [[ -n "$force_fps" ]]; then
  out_fps="$force_fps"
else
  out_fps="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
    -of default=nw=1:nk=1 "$probe_file" | awk -F'/' '{if ($2>0) printf "%.6f", $1/$2; else print $1}')"
  if [[ -z "$out_fps" || "$out_fps" == "0" ]]; then out_fps="30"; fi
fi

for inmp4 in "${mp4_files[@]}"; do
  dir="$(dirname "$inmp4")"
  base="$(basename "$inmp4")"
  name="${base%.*}"

  if [[ -n "$output_dir" ]]; then
    out="${output_dir}/${name}_speed${speed_label}.mp4"
  else
    out="${dir}/${name}_speed${speed_label}.mp4"
  fi

  # Detect number of audio streams (for info only when muted).
  audio_streams=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$inmp4" | wc -l | tr -d ' ')
  if [[ -z "$audio_streams" ]]; then audio_streams=0; fi
  has_audio=0
  if (( audio_streams > 0 )); then has_audio=1; fi

  # Apply default mute unless --unmute was passed.
  if (( mute == 1 )); then
    has_audio=0
  fi

  echo "[INFO] Speeding x${speed} : $inmp4 -> $out (audio_streams=${audio_streams}, crf=${crf}, preset=${preset}, mute=${mute}, fps=${out_fps})"

  if (( has_audio == 1 )); then
    # Video: reset timeline to 0, scale by speed, force CFR, ensure compatibility.
    vgraph="[0:v]settb=AVTB,setpts=(PTS-STARTPTS)/${speed},fps=fps=${out_fps},format=yuv420p[v]"
    # Audio: reset PTS, speed with chained atempo, resample async to stabilize clock.
    agraph="[0:a]asetpts=PTS-STARTPTS,${atempo_chain},aresample=async=1:first_pts=0[a]"

    ffmpeg -v "$ff_loglevel" -y -i "$inmp4" \
      -fflags +genpts -avoid_negative_ts make_zero \
      -filter_complex "${vgraph};${agraph}" \
      -map "[v]" -map "[a]" \
      -c:v libx264 -crf "$crf" -preset "$preset" \
      -c:a aac \
      -vsync cfr -shortest \
      -movflags +faststart -map_metadata -1 \
      "$out"
  else
    # Video-only path: disable audio explicitly.
    vgraph="settb=AVTB,setpts=(PTS-STARTPTS)/${speed},fps=fps=${out_fps},format=yuv420p"
    ffmpeg -v "$ff_loglevel" -y -i "$inmp4" \
      -fflags +genpts -avoid_negative_ts make_zero \
      -vf "$vgraph" -an \
      -c:v libx264 -crf "$crf" -preset "$preset" \
      -vsync cfr \
      -movflags +faststart -map_metadata -1 \
      "$out"
  fi

  echo "[OK]  Wrote: $out"
done

echo "Done. Processed ${#mp4_files[@]} file(s)."
