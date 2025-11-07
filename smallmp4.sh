#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# smallmp4.sh — Shrink MP4 files with ffmpeg (CRF mode or target-size mode)
#
# Features
#   - Inputs: one or more files and/or directories (recursively finds *.mp4).
#   - Modes:
#       * CRF mode (default): visually controlled quality with H.264.
#       * Target-size / target-vbitrate mode: 2-pass for accurate final size.
#   - Optional downscale to a max width/height while keeping aspect ratio.
#   - Optional FPS cap (e.g., 30) to further reduce size.
#   - Audio: re-encode to AAC (default 128k) or copy original.
#   - Output is written next to inputs with suffix "_small",
#     or to a chosen output directory with the same basenames.
#   - Adds +faststart for better web playback, strips metadata.
#   - Requires: ffmpeg, ffprobe
#
# Usage
#   smallmp4.sh [options] <input_or_dir>...
#
# Common Options
#   --crf N            CRF for H.264 (0–51, lower=better/larger). Default: 23.
#   --preset P         x264 preset {ultrafast..veryslow}. Default: medium.
#   --max-width W      Cap output width to W (height auto, keep AR).
#   --max-height H     Cap output height to H (width auto, keep AR).
#   --fps F            Cap output FPS to F (e.g., 30). Off by default.
#   --copy-audio       Copy original audio stream (if compatible).
#   --audio-bitrate B  AAC bitrate for audio re-encode (e.g., 96k, 128k). Default: 128k.
#   --target-mb MB     Target final file size in megabytes (enables 2-pass).
#   --vbitrate Kbps    Target video bitrate (e.g., 1500k / 1500K) (2-pass).
#   --out-dir DIR      Write outputs to DIR (keeps names).
#   --quiet            Only show ffmpeg errors.
#   --dry-run          Print what would be done but do not encode.
#   -h, --help         Show help.
#
# Examples
#   # Quick CRF shrink to 1080p/30fps
#   ./smallmp4.sh --crf 26 --max-width 1920 --fps 30 video.mp4
#
#   # Batch shrink all mp4 under a folder
#   ./smallmp4.sh --crf 28 --max-width 1280 --fps 24 /path/to/folder
#
#   # Target ~50 MB (two-pass)
#   ./smallmp4.sh --target-mb 50 movie.mp4
# -----------------------------------------------------------------------------

set -euo pipefail

print_usage() { sed -n '1,200p' "$0"; exit "${1:-1}"; }

# ------------------------------- Defaults ------------------------------------
crf=23
preset="medium"
max_w=""
max_h=""
cap_fps=""
copy_audio=0
audio_bitrate="128k"
target_mb=""
target_vbitrate=""
out_dir=""
suffix="_small"
verbose=1
dry_run=0

# ---------------------------- Parse arguments --------------------------------
inputs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --crf)            crf="${2:?}"; shift 2 ;;
    --preset)         preset="${2:?}"; shift 2 ;;
    --max-width)      max_w="${2:?}"; shift 2 ;;
    --max-height)     max_h="${2:?}"; shift 2 ;;
    --fps)            cap_fps="${2:?}"; shift 2 ;;
    --copy-audio)     copy_audio=1; shift ;;
    --audio-bitrate)  audio_bitrate="${2:?}"; shift 2 ;;
    --target-mb)      target_mb="${2:?}"; shift 2 ;;
    --vbitrate)       target_vbitrate="${2:?}"; shift 2 ;;
    --out-dir)        out_dir="${2:?}"; shift 2 ;;
    --quiet)          verbose=0; shift ;;
    --dry-run)        dry_run=1; shift ;;
    -h|--help)        print_usage 0 ;;
    -*)
      echo "Error: unknown option: $1" >&2; print_usage 2 ;;
    *)
      inputs+=("$1"); shift ;;
  esac
done

# ------------------------------ Validation -----------------------------------
[[ ${#inputs[@]} -gt 0 ]] || { echo "Error: no inputs." >&2; print_usage 2; }
command -v ffmpeg  >/dev/null 2>&1 || { echo "Error: ffmpeg not found." >&2; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo "Error: ffprobe not found." >&2; exit 1; }

# ------------------------------ Helpers --------------------------------------
human_size() { awk -v b="$1" 'BEGIN{s[0]="B";s[1]="KB";s[2]="MB";i=0;while(b>=1024&&i<2){b/=1024;i++}printf "%.2f %s",b,s[i]}' ; }
get_duration() { ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1" | awk '{printf "%.6f",$0+0}'; }
get_size_bytes() { stat -c '%s' "$1"; }

build_vf_chain() {
  local vf=""
  if [[ -n "$1" && -n "$2" ]]; then
    vf="scale=${1}:${2}:force_original_aspect_ratio=decrease,pad=${1}:${2}:(ow-iw)/2:(oh-ih)/2"
  elif [[ -n "$1" ]]; then
    vf="scale='min(iw,${1})':-2"
  elif [[ -n "$2" ]]; then
    vf="scale=-2:'min(ih,${2})'"
  fi
  [[ -n "$3" ]] && vf="${vf:+$vf,}fps=fps=$3"
  vf="${vf:+$vf,}format=yuv420p,setsar=1"
  echo "$vf"
}

calc_vbitrate_for_target_mb() {
  awk -v MB="$1" -v D="$2" -v A="$3" 'BEGIN{total=MB*8*1024*1024;vbits=total-A*D;if(vbits<2e5)vbits=2e5;printf "%.0f",vbits/D}'
}

# ------------------------------ Collect files --------------------------------
mapfile -t mp4_files < <(for p in "${inputs[@]}"; do
  if [[ -d "$p" ]]; then find "$p" -type f -iname '*.mp4'; elif [[ -f "$p" ]]; then echo "$p"; fi
done)
[[ ${#mp4_files[@]} -gt 0 ]] || { echo "No MP4 files found."; exit 1; }

# ------------------------------ Main loop ------------------------------------
for inmp4 in "${mp4_files[@]}"; do
  dir="$(dirname "$inmp4")"
  name="${inmp4##*/}"; name="${name%.*}"
  out="${out_dir:-$dir}/${name}${suffix}.mp4"
  dur="$(get_duration "$inmp4")"
  vf_chain="$(build_vf_chain "$max_w" "$max_h" "$cap_fps")"

  a_opts=(); ((copy_audio)) && a_opts+=( -c:a copy ) || a_opts+=( -c:a aac -b:a "$audio_bitrate" )
  echo "[INFO] Compressing $inmp4 -> $out"

  if [[ -n "$target_mb" || -n "$target_vbitrate" ]]; then
    vbps="${target_vbitrate:-$(calc_vbitrate_for_target_mb "$target_mb" "$dur" 128000)}"
    ffmpeg -v error -y -i "$inmp4" -vf "$vf_chain" -c:v libx264 -b:v "${vbps}" -pass 1 -an -f mp4 /dev/null
    ffmpeg -v error -y -i "$inmp4" -vf "$vf_chain" -c:v libx264 -b:v "${vbps}" -pass 2 "${a_opts[@]}" -movflags +faststart "$out"
    rm -f ffmpeg2pass-0.log*
  else
    ffmpeg -v error -y -i "$inmp4" -vf "$vf_chain" -c:v libx264 -crf "$crf" -preset "$preset" "${a_opts[@]}" -movflags +faststart "$out"
  fi

  echo "[OK] $(basename "$out") done."
done

echo "All done."
