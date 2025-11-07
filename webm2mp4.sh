#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# webm2mp4.sh — Convert WEBM videos to same-name MP4 (H.264 + AAC) using ffmpeg
#
# Features
#   - Accepts files and/or directories (recursive *.webm).
#   - Outputs next to inputs with the same basename but .mp4.
#   - H.264 quality via CRF (-c/--crf) and preset (-p/--preset).
#   - Audio AAC bitrate (-a/--audio-bitrate).
#   - Codec switch: --video-codec {libx264|h264_nvenc}
#   - Logs: **verbose by default**; use --quiet to show only ffmpeg errors.
#   - Requires: ffmpeg
#
# Usage
#   webm2mp4.sh [-c CRF] [-p PRESET] [-a AUDIO_BITRATE]
#               [--video-codec CODEC] [--quiet] <input_path> [...]
#
# Arguments
#   -c, --crf INT         0–51 (lower = higher quality, larger file). Default: 23
#   -p, --preset NAME     {ultrafast,superfast,veryfast,faster,fast,medium,
#                          slow,slower,veryslow}. Default: medium
#   -a, --audio-bitrate   e.g., 96k, 128k, 160k, 192k. Default: 128k
#       --video-codec     libx264 (CPU) or h264_nvenc (NVIDIA). Default: libx264
#       --quiet           Show only ffmpeg errors (override default verbose logs)
#   input_path            A WEBM file or a directory to scan recursively
#
# Examples
#   # 1) Convert a single WEBM with defaults (crf=23, preset=medium, aac=128k)
#   ./webm2mp4.sh /path/to/clip.webm
#
#   # 2) Higher visual quality (larger file): lower CRF and slower preset
#   ./webm2mp4.sh -c 18 -p slow /path/to/clip.webm
#
#   # 3) Faster encode for previews
#   ./webm2mp4.sh -p veryfast /path/to/clip.webm
#
#   # 4) Recursively convert a directory with NVIDIA encoder
#   ./webm2mp4.sh --video-codec h264_nvenc /path/to/dir
#
#   # 5) Mix files and directories in one go
#   ./webm2mp4.sh movie.webm talks/ demos/
#
#   # 6) Tune for smaller size (raise CRF, lower audio bitrate)
#   ./webm2mp4.sh -c 26 -a 96k /path/to/clip.webm
#
#   # 7) Quiet mode (only errors)
#   ./webm2mp4.sh --quiet /path/to/clip.webm
#
# Notes
#   - To satisfy yuv420p/H.264 requirements, odd video dimensions are scaled
#     up to the nearest even size automatically (e.g., 833x756 -> 834x756).
#   - Use pad or downscale instead by changing the -vf line if desired.
#   - -movflags +faststart places moov atom at the beginning for web playback.
# -----------------------------------------------------------------------------

set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage:
  webm2mp4.sh [-c CRF] [-p PRESET] [-a AUDIO_BITRATE]
              [--video-codec {libx264|h264_nvenc}] [--quiet]
              <input_path> [<input_path> ...]

Options:
  -c, --crf INT         0–51 (lower = higher quality). Default: 23
  -p, --preset NAME     ultrafast…veryslow. Default: medium
  -a, --audio-bitrate   e.g., 128k, 160k, 192k. Default: 128k
      --video-codec     libx264 (CPU) or h264_nvenc (NVIDIA). Default: libx264
      --quiet           Show only ffmpeg errors (default is verbose logs)
  -h, --help            Show this help
EOF
  exit "${1:-1}"
}

crf=23
preset="medium"
audio_bitrate="128k"
video_codec="libx264"
verbose=1   # Default: verbose ON
inputs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--crf)            crf="${2:?}"; shift 2 ;;
    -p|--preset)         preset="${2:?}"; shift 2 ;;
    -a|--audio-bitrate)  audio_bitrate="${2:?}"; shift 2 ;;
    --video-codec)       video_codec="${2:?}"; shift 2 ;;
    --quiet)             verbose=0; shift ;;
    -h|--help)           print_usage 0 ;;
    -*)
      echo "Error: unknown option: $1" >&2; print_usage 2 ;;
    *) inputs+=("$1"); shift ;;
  esac
done

[[ ${#inputs[@]} -gt 0 ]] || { echo "Error: no input paths provided." >&2; print_usage 2; }
command -v ffmpeg >/dev/null 2>&1 || { echo "Error: ffmpeg not found in PATH." >&2; exit 1; }

# Basic validations
[[ "$crf" =~ ^[0-9]+$ ]] || { echo "Error: CRF must be an integer. Got: $crf" >&2; exit 1; }
case "$preset" in
  ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow) ;;
  *) echo "Warning: unusual preset '$preset'." >&2 ;;
esac
[[ "$audio_bitrate" =~ ^[0-9]+k$ ]] || echo "Warning: audio bitrate '$audio_bitrate' not like '128k'." >&2
case "$video_codec" in
  libx264|h264_nvenc) ;;
  *) echo "Error: --video-codec must be libx264 or h264_nvenc" >&2; exit 1 ;;
esac

# Gather inputs
mapfile -t webm_files < <(
  for p in "${inputs[@]}"; do
    if [[ -d "$p" ]]; then
      find "$p" -type f -iname '*.webm'
    elif [[ -f "$p" ]]; then
      case "${p##*.}" in webm|WEBM) echo "$p" ;; *) echo "Skipping non-WEBM: $p" >&2 ;; esac
    else
      echo "Warning: path not found or unsupported: $p" >&2
    fi
  done
)

[[ ${#webm_files[@]} -gt 0 ]] || { echo "No WEBM files found to process." >&2; exit 1; }

# ffmpeg loglevel: verbose by default; quiet shows only errors
ff_loglevel=info
(( verbose == 0 )) && ff_loglevel=error

convert_one() {
  local input_webm="$1"
  local dir base output_mp4

  dir="$(dirname "$input_webm")"
  base="$(basename "$input_webm")"
  base="${base%.*}"
  output_mp4="${dir}/${base}.mp4"

  echo "[INFO] Converting: $input_webm -> $output_mp4 (crf=${crf}, preset=${preset}, aac=${audio_bitrate}, vcodec=${video_codec}, verbose=$verbose)"

  # Ensure even dimensions for yuv420p/H.264 by rounding odd sizes up.
  ffmpeg -v "$ff_loglevel" -y -i "$input_webm" \
    -vf "scale=ceil(iw/2)*2:ceil(ih/2)*2" \
    -c:v "$video_codec" -crf "$crf" -preset "$preset" -pix_fmt yuv420p \
    -c:a aac -b:a "$audio_bitrate" \
    -movflags +faststart \
    -map_metadata -1 \
    "$output_mp4"

  echo "[OK]  Wrote: $output_mp4"
}

# Avoid locale/path pitfalls with non-ASCII paths
export LC_ALL=${LC_ALL:-C.UTF-8}

for f in "${webm_files[@]}"; do
  convert_one "$f"
done

echo "Done. Processed ${#webm_files[@]} file(s)."
