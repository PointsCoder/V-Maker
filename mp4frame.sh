#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# mp4frame.sh — Extract a single frame from MP4 into a JPG using ffmpeg
#
# Features
#   - Choose frame by:
#       * --time      : timestamp in seconds or HH:MM:SS(.ms), frame-accurate.
#       * --frame     : zero-based frame index (uses select=eq(n,IDX)).
#     (Exactly one of --time or --frame is required.)
#   - Optional resize while preserving aspect ratio:
#       * --max-width / --max-height (downscale only; keeps AR, pads to exact
#         size if BOTH width and height are given).
#   - JPEG quality control via --jpeg-quality (2..31; lower → better).
#   - Output path via --output; default: alongside input as <name>_frame.jpg.
#   - Verbose by default; --quiet to show only ffmpeg errors.
#   - Requires: ffmpeg, ffprobe
#
# Usage
#   mp4frame.sh --time 12.5        input.mp4                # by seconds
#   mp4frame.sh --time 00:00:12.5  -o /tmp/out.jpg input.mp4
#   mp4frame.sh --frame 120        --max-width 1280 input.mp4
#   mp4frame.sh --frame 300        --max-width 1920 --max-height 1080 input.mp4
#
# Notes
#   - Time-based extraction uses "-i <in> -ss <t> -frames:v 1" for accuracy.
#   - Frame-index extraction uses "select=eq(n,IDX)" (may scan up to that frame).
#   - When BOTH --max-width and --max-height are set, we letterbox-pad to exact
#     WxH; otherwise we only downscale so the longer side <= the given cap.
# -----------------------------------------------------------------------------

set -euo pipefail

print_usage() { sed -n '1,200p' "$0"; exit "${1:-1}"; }

# ------------------------------- Defaults ------------------------------------
time_arg=""            # e.g., "12.5" or "HH:MM:SS(.ms)"
frame_idx=""           # e.g., "120" (zero-based)
output_jpg=""          # output path; default: "<input_dir>/<name>_frame.jpg"
max_w=""               # optional cap width
max_h=""               # optional cap height
jpeg_q=3               # 2(best) .. 31(worst), default fairly high quality
verbose=1              # verbose by default

# ---------------------------- Parse arguments --------------------------------
input_mp4=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --time)          time_arg="${2:?}"; shift 2 ;;
    --frame)         frame_idx="${2:?}"; shift 2 ;;
    -o|--output)     output_jpg="${2:?}"; shift 2 ;;
    --max-width)     max_w="${2:?}"; shift 2 ;;
    --max-height)    max_h="${2:?}"; shift 2 ;;
    --jpeg-quality)  jpeg_q="${2:?}"; shift 2 ;;
    --quiet)         verbose=0; shift ;;
    -h|--help)       print_usage 0 ;;
    -*)
      echo "Error: unknown option: $1" >&2; print_usage 2 ;;
    *)
      # First non-option is taken as input file
      if [[ -z "${input_mp4}" ]]; then
        input_mp4="$1"
      else
        echo "Error: multiple inputs provided. Only one input MP4 is supported." >&2
        print_usage 2
      fi
      shift
      ;;
  esac
done

# ------------------------------ Validation -----------------------------------
[[ -n "$input_mp4" && -f "$input_mp4" ]] || { echo "Error: need an input MP4 file." >&2; print_usage 2; }
command -v ffmpeg  >/dev/null 2>&1 || { echo "Error: ffmpeg not found in PATH." >&2; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo "Error: ffprobe not found in PATH." >&2; exit 1; }

if [[ -n "$time_arg" && -n "$frame_idx" ]]; then
  echo "Error: use exactly one of --time or --frame." >&2; exit 1
fi
if [[ -z "$time_arg" && -z "$frame_idx" ]]; then
  echo "Error: you must provide --time or --frame." >&2; exit 1
fi

if [[ -n "$frame_idx" && ! "$frame_idx" =~ ^[0-9]+$ ]]; then
  echo "Error: --frame must be a non-negative integer (zero-based)." >&2; exit 1
fi
if [[ ! "$jpeg_q" =~ ^[0-9]+$ ]] || (( jpeg_q < 2 || jpeg_q > 31 )); then
  echo "Error: --jpeg-quality must be an integer in [2,31]." >&2; exit 1
fi
if [[ -n "$max_w" && ! "$max_w" =~ ^[0-9]+$ ]]; then
  echo "Error: --max-width must be integer." >&2; exit 1
fi
if [[ -n "$max_h" && ! "$max_h" =~ ^[0-9]+$ ]]; then
  echo "Error: --max-height must be integer." >&2; exit 1
fi

# ------------------------------ Build output ---------------------------------
in_dir="$(dirname "$input_mp4")"
in_base="$(basename "$input_mp4")"
in_name="${in_base%.*}"
if [[ -z "$output_jpg" ]]; then
  if [[ -n "$time_arg" ]]; then
    # sanitize time string for filename
    label="$(echo "$time_arg" | sed -E 's/[^0-9A-Za-z_.-]+/-/g')"
    output_jpg="${in_dir}/${in_name}_t${label}.jpg"
  else
    output_jpg="${in_dir}/${in_name}_n${frame_idx}.jpg"
  fi
fi

# ------------------------------ Video filter ---------------------------------
# Build vf chain: optional scale/pad → format yuvj420p (mjpeg-friendly) → setsar=1
build_vf_chain() {
  local W="$1" H="$2"
  local vf=""
  if [[ -n "$W" && -n "$H" ]]; then
    # contain + pad to exact WxH
    vf="scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2"
  elif [[ -n "$W" ]]; then
    # cap width only (downscale if wider)
    vf="scale='min(iw,${W})':-2"
  elif [[ -n "$H" ]]; then
    # cap height only (downscale if taller)
    vf="scale=-2:'min(ih,${H})'"
  fi
  # For JPEG, use full-range yuvj420p; ensure square pixels
  vf="${vf:+$vf,}format=yuvj420p,setsar=1"
  echo "$vf"
}
vf_chain="$(build_vf_chain "${max_w}" "${max_h}")"

# ------------------------------ Logging level --------------------------------
ff_loglevel=info
(( verbose == 0 )) && ff_loglevel=error

# ------------------------------ Extract logic --------------------------------
# We always re-encode a single frame to MJPEG with the requested quality.
# -q:v 2(best)..31(worst). Lower values increase detail/size.
if [[ -n "$time_arg" ]]; then
  # Time-based accurate seek:
  # Put -ss AFTER -i for frame-accurate decode; then -frames:v 1 to output a single frame.
  if [[ -n "$vf_chain" ]]; then
    ffmpeg -v "$ff_loglevel" -y -i "$input_mp4" -ss "$time_arg" \
      -frames:v 1 -vf "$vf_chain" -map 0:v:0 -c:v mjpeg -q:v "$jpeg_q" \
      -an -f image2 "$output_jpg"
  else
    ffmpeg -v "$ff_loglevel" -y -i "$input_mp4" -ss "$time_arg" \
      -frames:v 1 -map 0:v:0 -c:v mjpeg -q:v "$jpeg_q" \
      -an -f image2 "$output_jpg"
  fi
else
  # Frame-index based using select=eq(n,IDX). This may decode up to that frame.
  # We also ensure exactly 1 output frame with -frames:v 1 and -vsync vfr.
  sel="select='eq(n\,${frame_idx})'"
  if [[ -n "$vf_chain" ]]; then
    vf_full="${sel},${vf_chain}"
  else
    vf_full="${sel},format=yuvj420p,setsar=1"
  fi
  ffmpeg -v "$ff_loglevel" -y -i "$input_mp4" \
    -vf "$vf_full" -vsync vfr -frames:v 1 -map 0:v:0 \
    -c:v mjpeg -q:v "$jpeg_q" -an -f image2 "$output_jpg"
fi

(( verbose == 1 )) && echo "[OK] Wrote: $output_jpg"
