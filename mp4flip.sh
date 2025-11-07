#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# mp4flip.sh — Vertically and/or horizontally flip MP4 videos using ffmpeg
#
# Features
#   - Accepts one or more inputs: files and/or directories (recursive *.mp4).
#   - Flip directions: vertical (--vflip), horizontal (--hflip); both allowed.
#   - Stable timestamps & CFR (optional --fps) for smooth web playback.
#   - Audio: muted by default (consistent with speed script); pass --unmute to keep.
#   - Re-encode options: CRF (-c/--crf) and preset (-p/--preset).
#   - Outputs are written next to inputs with suffix “_flip[H][V].mp4” (or -o dir).
#   - Logs: verbose by default; use --quiet to show only ffmpeg errors.
#   - Requires: ffmpeg and ffprobe.
#
# Usage
#   mp4flip.sh [--vflip] [--hflip] [-c CRF] [-p PRESET] [--fps FPS]
#              [-o OUTPUT_DIR] [--unmute|--mute] [--quiet] <input_path>...
#
# Arguments
#   --vflip             Apply vertical flip (top-bottom).
#   --hflip             Apply horizontal flip (left-right mirror).
#   -c, --crf           H.264 CRF 0–51 (lower = higher quality). Default: 23.
#   -p, --preset        {ultrafast, superfast, veryfast, faster, fast, medium,
#                       slow, slower, veryslow}. Default: medium.
#   -o, --output-dir    Directory to place outputs. Default: alongside inputs.
#       --fps FPS       Force output constant frame rate (e.g., 30/60). Optional.
#       --mute          Forcefully disable audio in outputs (default).
#       --unmute        Keep/process audio if present.
#       --quiet         Only show ffmpeg errors (default is verbose logs).
#   -h, --help          Show this help.
#
# Examples
#   # 1) Vertical flip only, default muted, force 30 fps
#   ./mp4flip.sh --vflip --fps 30 /path/video.mp4
#
#   # 2) Horizontal + vertical (both), keep audio, higher quality/slower encode
#   ./mp4flip.sh --hflip --vflip --unmute -c 20 -p slow /path/video.mp4
#
#   # 3) Batch flip all MP4s in a folder horizontally, quiet logs
#   ./mp4flip.sh --hflip --quiet /path/to/folder
#
# Notes
#   - Video chain: settb=AVTB -> setpts=PTS-STARTPTS -> flips -> fps (optional) -> yuv420p.
#   - Audio chain (when unmuted): aac re-encode for compatibility; timestamps start at 0.
#   - Outputs use +faststart for better HTML5 video playback.
# -----------------------------------------------------------------------------

set -euo pipefail

print_usage() { sed -n '1,200p' "$0"; exit "${1:-1}"; }

# ------------------------------- Defaults ------------------------------------
crf=23
preset="medium"
output_dir=""
verbose=1
force_fps=""
mute=1          # Default muted (video-only), pass --unmute to keep audio.
want_vflip=0
want_hflip=0

# ---------------------------- Parse arguments --------------------------------
inputs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vflip)             want_vflip=1; shift ;;
    --hflip)             want_hflip=1; shift ;;
    -c|--crf)            crf="${2:?}"; shift 2 ;;
    -p|--preset)         preset="${2:?}"; shift 2 ;;
    -o|--output-dir)     output_dir="${2:?}"; shift 2 ;;
    --fps)               force_fps="${2:?}"; shift 2 ;;
    --mute|--no-audio)   mute=1; shift ;;
    --unmute)            mute=0; shift ;;
    --quiet)             verbose=0; shift ;;
    -h|--help)           print_usage 0 ;;
    -*)
      echo "Error: unknown option: $1" >&2; print_usage 2 ;;
    *)
      inputs+=("$1"); shift ;;
  esac
done

# ------------------------------ Validation -----------------------------------
(( want_vflip==1 || want_hflip==1 )) || { echo "Error: you must specify at least one of --vflip or --hflip." >&2; exit 1; }
[[ ${#inputs[@]} -gt 0 ]] || { echo "Error: no input paths provided." >&2; print_usage 2; }
command -v ffmpeg  >/dev/null 2>&1 || { echo "Error: ffmpeg not found in PATH." >&2; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo "Error: ffprobe not found in PATH." >&2; exit 1; }
[[ "$crf" =~ ^[0-9]+$ ]] || { echo "Error: CRF must be integer. Got: $crf" >&2; exit 1; }
case "$preset" in
  ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow) ;;
  *) echo "Warning: unusual preset '$preset'." >&2 ;;
esac
if [[ -n "$force_fps" ]]; then
  awk -v f="$force_fps" 'BEGIN{ if (f+0<=0) exit 1 }' || { echo "Error: --fps must be > 0. Got: $force_fps" >&2; exit 1; }
fi
if [[ -n "$output_dir" ]]; then mkdir -p "$output_dir"; fi

# ------------------------------ Helpers --------------------------------------
label_from_flags() {
  local s="flip"
  (( want_hflip==1 )) && s="${s}H"
  (( want_vflip==1 )) && s="${s}V"
  echo "$s"
}

# Collect MP4 files from inputs.
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

# Decide output CFR (use --fps if provided; otherwise probe first input; fallback 30).
probe_file="${mp4_files[0]}"
if [[ -n "$force_fps" ]]; then
  out_fps="$force_fps"
else
  out_fps="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
    -of default=nw=1:nk=1 "$probe_file" | awk -F'/' '{if ($2>0) printf "%.6f", $1/$2; else print $1}')"
  if [[ -z "$out_fps" || "$out_fps" == "0" ]]; then out_fps="30"; fi
fi

# ------------------------------ Main loop ------------------------------------
export LC_ALL=${LC_ALL:-C.UTF-8}
suffix="$(label_from_flags)"

for inmp4 in "${mp4_files[@]}"; do
  dir="$(dirname "$inmp4")"
  base="$(basename "$inmp4")"
  name="${base%.*}"

  if [[ -n "$output_dir" ]]; then
    out="${output_dir}/${name}_${suffix}.mp4"
  else
    out="${dir}/${name}_${suffix}.mp4"
  fi

  # Count audio streams (for info only when muted).
  audio_streams=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$inmp4" | wc -l | tr -d ' ')
  [[ -z "$audio_streams" ]] && audio_streams=0
  has_audio=0; (( audio_streams > 0 )) && has_audio=1
  if (( mute == 1 )); then has_audio=0; fi

  echo "[INFO] Flip: H=${want_hflip} V=${want_vflip}  fps=${out_fps}  mute=${mute}  in=${inmp4}"

  # -------- Build video filter chain (order: reset TB/PTS -> flips -> fps -> format) --------
  vchain="settb=AVTB,setpts=PTS-STARTPTS"
  (( want_hflip==1 )) && vchain="${vchain},hflip"
  (( want_vflip==1 )) && vchain="${vchain},vflip"
  vchain="${vchain},fps=fps=${out_fps},format=yuv420p"

  if (( has_audio == 1 )); then
    # Map both video and audio, re-encode audio for compatibility.
    ffmpeg -v "$ff_loglevel" -y -i "$inmp4" \
      -fflags +genpts -avoid_negative_ts make_zero \
      -filter_complex "[0:v]${vchain}[v];[0:a]asetpts=PTS-STARTPTS[a]" \
      -map "[v]" -map "[a]" \
      -c:v libx264 -crf "$crf" -preset "$preset" \
      -c:a aac \
      -vsync cfr -shortest \
      -movflags +faststart -map_metadata -1 \
      "$out"
  else
    # Video-only path (muted or no audio in source).
    ffmpeg -v "$ff_loglevel" -y -i "$inmp4" \
      -fflags +genpts -avoid_negative_ts make_zero \
      -vf "$vchain" -an \
      -c:v libx264 -crf "$crf" -preset "$preset" \
      -vsync cfr \
      -movflags +faststart -map_metadata -1 \
      "$out"
  fi

  echo "[OK]  Wrote: $out"
done

echo "Done. Processed ${#mp4_files[@]} file(s)."
