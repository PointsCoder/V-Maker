#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# png2jpg.sh — Convert PNG images to same-name JPGs using ffmpeg
#
# Features
#   - Accepts one or more inputs: files and/or directories.
#   - For directories, it recursively processes *.png / *.PNG.
#   - Outputs are written next to inputs with the same basename but .jpg.
#   - JPEG quality is configurable via -q/--quality (default: 4).
#   - Requires: ffmpeg
#
# Usage
#   png2jpg.sh [-q QUALITY] <input_path> [<input_path> ...]
#
# Arguments
#   -q, --quality   Integer for ffmpeg -q:v (2–31). Smaller = better quality,
#                   larger file. Default: 4.
#   input_path      A PNG file or a directory to scan recursively.
#
# Examples
#   # 1) Convert a single PNG with default quality (q=4)
#   ./png2jpg.sh /path/to/image.png
#
#   # 2) Convert a single PNG with better quality (smaller q => higher quality)
#   ./png2jpg.sh -q 3 /path/to/image.png
#
#   # 3) Recursively convert all PNGs in a directory (q=5 for smaller files)
#   ./png2jpg.sh -q 5 /path/to/dir
#
#   # 4) Mix files and directories
#   ./png2jpg.sh img1.png img2.png /path/to/dir
#
# Notes
#   - The command strips all metadata (-map_metadata -1) to reduce size.
#   - Uses 4:2:0 sampling (format=yuvj420p) for best compatibility and size.
#   - If your PNG has transparency, JPEG cannot preserve it. If you need a
#     solid background (e.g., white/black) before conversion, ask for the
#     background-color extension version of this script.
# -----------------------------------------------------------------------------

set -euo pipefail

###############################################################################
# Helper: print usage and exit
###############################################################################
print_usage() {
  cat <<'EOF'
Usage:
  png2jpg.sh [-q QUALITY] <input_path> [<input_path> ...]

Arguments:
  -q, --quality   Integer for ffmpeg -q:v (2–31). Smaller = better quality,
                  larger file. Default: 4.
  input_path      A PNG file or a directory to scan recursively.

Examples:
  # 1) Convert a single PNG with default quality (q=4)
  ./png2jpg.sh /path/to/image.png

  # 2) Convert a single PNG with better quality (smaller q => higher quality)
  ./png2jpg.sh -q 3 /path/to/image.png

  # 3) Recursively convert all PNGs in a directory (q=5 for smaller files)
  ./png2jpg.sh -q 5 /path/to/dir

  # 4) Mix files and directories
  ./png2jpg.sh img1.png img2.png /path/to/dir
EOF
  exit "${1:-1}"
}

###############################################################################
# Parse arguments
###############################################################################
quality=4
inputs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--quality)
      [[ $# -ge 2 ]] || { echo "Error: missing value for $1" >&2; print_usage 2; }
      quality="$2"
      shift 2
      ;;
    -h|--help)
      print_usage 0
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      print_usage 2
      ;;
    *)
      inputs+=("$1")
      shift
      ;;
  esac
done

[[ ${#inputs[@]} -gt 0 ]] || { echo "Error: no input paths provided." >&2; print_usage 2; }

###############################################################################
# Preconditions
###############################################################################
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg not found in PATH." >&2
  exit 1
fi

# Validate quality is an integer within a sensible range
if ! [[ "$quality" =~ ^[0-9]+$ ]]; then
  echo "Error: QUALITY must be an integer. Got: $quality" >&2
  exit 1
fi
if (( quality < 2 || quality > 31 )); then
  echo "Warning: QUALITY=$quality is unusual (expected 2–31). Proceeding anyway..."
fi

###############################################################################
# Collect PNG files from inputs
###############################################################################
mapfile -t png_files < <(
  for p in "${inputs[@]}"; do
    if [[ -d "$p" ]]; then
      # Recursively find .png / .PNG
      find "$p" -type f \( -iname '*.png' \)
    elif [[ -f "$p" ]]; then
      # Single file; ensure it's a PNG by extension
      case "${p##*.}" in
        png|PNG) echo "$p" ;;
        *)
          echo "Skipping non-PNG file: $p" >&2
          ;;
      esac
    else
      echo "Warning: path not found or unsupported: $p" >&2
    fi
  done
)

if [[ ${#png_files[@]} -eq 0 ]]; then
  echo "No PNG files found to process." >&2
  exit 1
fi

###############################################################################
# Convert loop
###############################################################################
convert_one() {
  local input_png="$1"
  local dir base output_jpg

  dir="$(dirname "$input_png")"
  base="$(basename "$input_png")"
  base="${base%.*}"                 # strip extension
  output_jpg="${dir}/${base}.jpg"

  echo "[INFO] Converting: $input_png -> $output_jpg (q=${quality})"

  # Core conversion:
  #  - format=yuvj420p: use 4:2:0 sampling for smaller size & compatibility
  #  - -q:v ${quality}: JPEG quality (lower = better quality, larger size)
  #  - -map_metadata -1: strip all metadata to reduce size further
  ffmpeg -y -i "$input_png" -vf "format=yuvj420p" -q:v "$quality" -map_metadata -1 "$output_jpg" \
    >/dev/null 2>&1

  echo "[OK]  Wrote: $output_jpg"
}

# Process each discovered PNG
for f in "${png_files[@]}"; do
  convert_one "$f"
done

echo "Done. Processed ${#png_files[@]} file(s)."
