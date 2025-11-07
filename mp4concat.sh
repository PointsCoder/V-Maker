#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# mp4concat.sh — Concatenate multiple MP4s in time, matching the first video's resolution
#
# Features
#   - Accepts one or more inputs: files and/or directories (recursive *.mp4).
#   - Concatenate in time order (directory inputs are filename-sorted).
#   - Output resolution matches the FIRST video (others are scaled & padded to fit).
#   - Optional constant frame rate (--fps); otherwise probe from the first input (fallback 30).
#   - Audio: muted by default; pass --unmute to keep audio IF all inputs have audio tracks.
#   - Re-encode options: CRF (-c/--crf) and preset (-p/--preset).
#   - Output file is named "<first>_concat.mp4" or written to -o OUTPUT_DIR.
#   - Logs: verbose by default; use --quiet to show only ffmpeg errors.
#   - Requires: ffmpeg and ffprobe.
#
# Usage
#   mp4concat.sh [-c CRF] [-p PRESET] [--fps FPS] [--unmute|--mute]
#                [-o OUTPUT_DIR] [--quiet] <input_path>...
#
# Examples
#   # 1) Concatenate files (video-only by default), force 30 fps
#   ./mp4concat.sh --fps 30 a.mp4 b.mp4 c.mp4
#
#   # 2) Concatenate all MP4s in a folder (sorted), keep audio if possible
#   ./mp4concat.sh --unmute /path/to/folder
#
#   # 3) Higher quality, slower preset, write to a directory
#   ./mp4concat.sh -c 20 -p slow -o out_dir clips1/ clips2/
#
# Notes
#   - Video chain per segment: settb=AVTB -> setpts=PTS-STARTPTS
#                             -> scale=WxH:force_original_aspect_ratio=decrease
#                             -> pad=W:H:center -> setsar=1 -> fps -> format=yuv420p
#   - Audio chain per segment (if enabled): asetpts=PTS-STARTPTS -> aformat -> aresample(48k)
#   - If any input lacks audio while --unmute is set, script falls back to video-only concat.
# -----------------------------------------------------------------------------

set -euo pipefail

print_usage() { sed -n '1,200p' "$0"; exit "${1:-1}"; }

# ------------------------------- Defaults ------------------------------------
crf=23
preset="medium"
output_dir=""
verbose=1
force_fps=""
mute=1     # Default: video-only. Pass --unmute to keep audio (if all inputs have audio).

# ---------------------------- Parse arguments --------------------------------
inputs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--crf)          crf="${2:?}"; shift 2 ;;
    -p|--preset)       preset="${2:?}"; shift 2 ;;
    -o|--output-dir)   output_dir="${2:?}"; shift 2 ;;
    --fps)             force_fps="${2:?}"; shift 2 ;;
    --mute|--no-audio) mute=1; shift ;;
    --unmute)          mute=0; shift ;;
    --quiet)           verbose=0; shift ;;
    -h|--help)         print_usage 0 ;;
    -*)
      echo "Error: unknown option: $1" >&2; print_usage 2 ;;
    *)
      inputs+=("$1"); shift ;;
  esac
done

# ------------------------------ Validation -----------------------------------
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

# ------------------------------ Gather inputs --------------------------------
# Expand inputs: files kept in provided order; directories expanded and filename-sorted.
mapfile -t mp4_files < <(
  for p in "${inputs[@]}"; do
    if [[ -d "$p" ]]; then
      find "$p" -type f -iname '*.mp4' | sort
    elif [[ -f "$p" ]]; then
      case "${p##*.}" in mp4|MP4) echo "$p" ;; *) echo "Skipping non-MP4: $p" >&2 ;; esac
    else
      echo "Warning: path not found or unsupported: $p" >&2
    fi
  done
)
[[ ${#mp4_files[@]} -ge 2 ]] || { echo "Error: need at least two MP4 files to concatenate." >&2; exit 1; }

# ------------------------------ Probe first video ----------------------------
first="${mp4_files[0]}"
# Target resolution from the FIRST video:
read first_w first_h < <(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height -of csv=p=0:s=x "$first")
# In some locales, separator might differ; ensure sane defaults.
first_w="${first_w%x*}"; first_h="${first_h#*x}"
[[ -z "$first_w" || -z "$first_h" ]] && { first_w=1920; first_h=1080; }

# Decide output CFR (use --fps if provided; otherwise probe first input; fallback 30).
if [[ -n "$force_fps" ]]; then
  out_fps="$force_fps"
else
  out_fps="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
    -of default=nw=1:nk=1 "$first" | awk -F'/' '{if ($2>0) printf "%.6f", $1/$2; else print $1}')"
  if [[ -z "$out_fps" || "$out_fps" == "0" ]]; then out_fps="30"; fi
fi

# Check audio availability across ALL inputs.
all_have_audio=1
for f in "${mp4_files[@]}"; do
  n=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$f" | wc -l | tr -d ' ')
  [[ -z "$n" || "$n" == "0" ]] && all_have_audio=0
done
enable_audio_concat=0
if (( mute == 0 && all_have_audio == 1 )); then
  enable_audio_concat=1
fi

# ------------------------------ Build ffmpeg args ----------------------------
ff_loglevel=info; (( verbose == 0 )) && ff_loglevel=error

# Build input args and record stream indices for filter graph.
in_args=()
for f in "${mp4_files[@]}"; do
  in_args+=( -i "$f" )
done

# Construct per-segment video & (optional) audio chains, then concat.
# We will generate labels: [v0],[a0],...,[vN-1],[aN-1] -> concat.
filter_parts=()
vlabels=()
alabels=()

for i in "${!mp4_files[@]}"; do
  # Video chain: reset TB/PTS -> scale to fit -> pad to exact -> setsar=1 -> fps -> format
  filter_parts+=( "[$i:v]settb=AVTB,setpts=PTS-STARTPTS,scale=${first_w}:${first_h}:force_original_aspect_ratio=decrease,pad=${first_w}:${first_h}:((ow-iw)/2):((oh-ih)/2):color=black,setsar=1,fps=fps=${out_fps},format=yuv420p[v$i]" )
  vlabels+=( "[v$i]" )
  if (( enable_audio_concat == 1 )); then
    # Audio chain: reset PTS -> format stereo/float -> resample 48k (uniform for concat)
    filter_parts+=( "[$i:a]asetpts=PTS-STARTPTS,aformat=sample_fmts=fltp:channel_layouts=stereo,aresample=48000[a$i]" )
    alabels+=( "[a$i]" )
  fi
done

# Concat blocks
if (( enable_audio_concat == 1 )); then
  filter_parts+=( "$(printf "%s" "${vlabels[*]} ${alabels[*]}" | sed 's/ //g')concat=n=${#mp4_files[@]}:v=1:a=1[vout][aout]" )
else
  filter_parts+=( "$(printf "%s" "${vlabels[*]}" | sed 's/ //g')concat=n=${#mp4_files[@]}:v=1:a=0[vout]" )
fi

filter_complex=$(IFS=';'; echo "${filter_parts[*]}")

# Output path/name
base="$(basename "$first")"
name="${base%.*}"
if [[ -n "$output_dir" ]]; then
  out="${output_dir}/${name}_concat.mp4"
else
  out="$(dirname "$first")/${name}_concat.mp4"
fi

echo "[INFO] Concatenating ${#mp4_files[@]} file(s)"
echo "[INFO] Target WxH=${first_w}x${first_h}  fps=${out_fps}  audio_concat=${enable_audio_concat}  preset=${preset} crf=${crf}"
echo "[INFO] Output: $out"

# ------------------------------ Run ffmpeg -----------------------------------
if (( enable_audio_concat == 1 )); then
  ffmpeg -v "$ff_loglevel" -y \
    "${in_args[@]}" \
    -filter_complex "$filter_complex" \
    -map "[vout]" -map "[aout]" \
    -c:v libx264 -crf "$crf" -preset "$preset" \
    -c:a aac \
    -vsync cfr -shortest \
    -movflags +faststart -map_metadata -1 \
    "$out"
else
  ffmpeg -v "$ff_loglevel" -y \
    "${in_args[@]}" \
    -filter_complex "$filter_complex" \
    -map "[vout]" -an \
    -c:v libx264 -crf "$crf" -preset "$preset" \
    -vsync cfr \
    -movflags +faststart -map_metadata -1 \
    "$out"
fi

echo "[OK] Wrote: $out"
