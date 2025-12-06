#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# mp4crop.sh — Batch crop videos using ffmpeg with robust directory handling
#
# Features
#   - Input can be a single file OR a directory of videos.
#   - Crop modes:
#       * --center      : Auto-calculates x/y to crop from the center (default).
#       * -x VAL -y VAL : Manually specify top-left coordinates.
#   - Output handling:
#       * Auto-generates filenames with a suffix (e.g., input.mp4 -> input_crop.mp4).
#       * Optional --output-dir to save processed files in a separate folder.
#   - Audio policy:
#       * Copies audio stream by default (-c:a copy) to preserve quality/speed.
#   - Robustness:
#       * Handles spaces in filenames correctly.
#       * Includes workarounds for Anaconda/system shell library conflicts (libtinfo).
#   - Logs: verbose by default; use --quiet to show only ffmpeg errors.
#   - Requires: ffmpeg
#
# Usage
#   mp4crop.sh -w WIDTH -h HEIGHT [-i INPUT | INPUT_DIR]
#              [--x X_POS] [--y Y_POS] [--center]
#              [--output-dir DIR] [--suffix "_crop"]
#              [--exts "mp4,mov,mkv,webm"]
#              [--crf 23] [--preset medium] [--quiet] [--dry-run]
#
# Example
#   # Center crop all videos in folder to 512x512
#   ./mp4crop.sh -w 512 -h 512 ./raw_clips
#
#   # Crop 1920x1080 from position 0,0 (top-left)
#   ./mp4crop.sh -w 1920 -h 1080 -x 0 -y 0 -i video.mp4
# -----------------------------------------------------------------------------

# NOTE: Strict mode (set -e) is disabled to prevent the script from crashing 
# immediately if "libtinfo" warnings appear in Anaconda environments.
set -u

print_usage() { sed -n '1,100p' "$0"; exit "${1:-1}"; }

# ------------------------------- Defaults ------------------------------------
input_path=""
out_dir=""
crop_w=""
crop_h=""
crop_x=""
crop_y=""
center_crop=1               # Default to center crop unless x/y provided
suffix="_crop"
exts="mp4,mov,mkv,webm"
crf=23
preset="medium"
verbose=1
dry_run=0

# ---------------------------- Parse arguments --------------------------------
positional_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)       input_path="${2:?}"; shift 2 ;;
    -w|--width)       crop_w="${2:?}"; shift 2 ;;
    -h|--height)      crop_h="${2:?}"; shift 2 ;;
    -x|--x)           crop_x="${2:?}"; center_crop=0; shift 2 ;;
    -y|--y)           crop_y="${2:?}"; center_crop=0; shift 2 ;;
    --center)         center_crop=1; shift ;;
    --output-dir)     out_dir="${2:?}"; shift 2 ;;
    --suffix)         suffix="${2:?}"; shift 2 ;;
    --exts)           exts="${2:?}"; shift 2 ;;
    --crf)            crf="${2:?}"; shift 2 ;;
    --preset)         preset="${2:?}"; shift 2 ;;
    --quiet)          verbose=0; shift ;;
    --dry-run)        dry_run=1; shift ;;
    -h|--help)        print_usage 0 ;;
    -*)
      echo "Error: unknown option: $1" >&2; print_usage 2 ;;
    *)
      positional_args+=("$1"); shift ;;
  esac
done

# If -i not provided, accept a single positional argument
if [[ -z "$input_path" ]]; then
  if [[ ${#positional_args[@]} -eq 1 ]]; then
    input_path="${positional_args[0]}"
  elif [[ ${#positional_args[@]} -gt 1 ]]; then
    echo "Error: multiple positional arguments; use -i/--input." >&2
    exit 1
  fi
fi

# ------------------------------ Validation -----------------------------------
[[ -n "$input_path" && ( -f "$input_path" || -d "$input_path" ) ]] || { echo "Error: Input must be a valid file or directory." >&2; exit 1; }
[[ -n "$crop_w" && "$crop_w" =~ ^[0-9]+$ ]] || { echo "Error: --width is required and must be integer." >&2; exit 1; }
[[ -n "$crop_h" && "$crop_h" =~ ^[0-9]+$ ]] || { echo "Error: --height is required and must be integer." >&2; exit 1; }

# Validate coordinates if not center cropping
if (( center_crop == 0 )); then
  [[ -n "$crop_x" && "$crop_x" =~ ^[0-9]+$ ]] || { echo "Error: -x required when not using --center." >&2; exit 1; }
  [[ -n "$crop_y" && "$crop_y" =~ ^[0-9]+$ ]] || { echo "Error: -y required when not using --center." >&2; exit 1; }
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "Error: ffmpeg not found in PATH." >&2
    exit 1
fi

# ------------------------------ Gather files ---------------------------------
files=()

if [[ -f "$input_path" ]]; then
  # Single file mode
  files+=("$input_path")
else
  # Directory mode (Robust find logic)
  IFS=',' read -r -a ext_arr <<< "$exts"
  pred=""
  for e in "${ext_arr[@]}"; do
    e="${e,,}"
    if [[ -z "$pred" ]]; then
      pred="-iname '*.${e}' -o -iname '*.${e^^}'"
    else
      pred="${pred} -o -iname '*.${e}' -o -iname '*.${e^^}'"
    fi
  done

  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(eval "find \"\$input_path\" -maxdepth 1 -type f \( $pred \) -print0 | sort -z")

  if (( ${#files[@]} == 0 )); then
    echo "No input videos found in: $input_path (exts: $exts)" >&2
    exit 1
  fi
fi

# ------------------------------ Prepare Logic --------------------------------
# Build the crop filter string
# FFmpeg syntax: crop=w:h:x:y
# Note: 'iw' and 'ih' are FFmpeg internal variables for input width/height.
# This allows us to use dynamic math inside the filter without probing first.
if (( center_crop == 1 )); then
  # x = (InputWidth - TargetWidth) / 2
  # y = (InputHeight - TargetHeight) / 2
  filter_str="crop=${crop_w}:${crop_h}:(iw-ow)/2:(ih-oh)/2"
  coord_label="Center"
else
  filter_str="crop=${crop_w}:${crop_h}:${crop_x}:${crop_y}"
  coord_label="X=${crop_x},Y=${crop_y}"
fi

ff_loglevel=info
(( verbose == 0 )) && ff_loglevel=error

# ------------------------------ Processing Loop ------------------------------
echo "[INFO] Starting Batch Crop..."
echo "[INFO] Target: ${crop_w}x${crop_h} (${coord_label})"
echo "[INFO] Files: ${#files[@]}"

count=0
success=0
total=${#files[@]}

for f in "${files[@]}"; do
  ((count++))
  
  # Determine output filename
  filename=$(basename -- "$f")
  extension="${filename##*.}"
  basename="${filename%.*}"
  
  if [[ -n "$out_dir" ]]; then
    mkdir -p "$out_dir"
    output_file="${out_dir}/${basename}${suffix}.${extension}"
  else
    dir=$(dirname -- "$f")
    output_file="${dir}/${basename}${suffix}.${extension}"
  fi

  if (( verbose == 1 )); then
    echo "-------------------------------------------------------------------------------"
    echo "[$count/$total] Processing: $filename"
    echo " -> Output: $output_file"
  fi

  # Build command
  # -c:a copy: Don't re-encode audio (faster)
  # -map_metadata 0: Keep metadata
  #
  # CRITICAL FIX: We use 'env LD_LIBRARY_PATH=""' to force the command to ignore 
  # the current Anaconda environment's libraries and use the system libraries instead.
  # This fixes the "libtinfo.so.6: no version information available" error.
  cmd=( env LD_LIBRARY_PATH="" ffmpeg -v "$ff_loglevel" -y -i "$f" )
  cmd+=( -vf "$filter_str" )
  cmd+=( -c:v libx264 -crf "$crf" -preset "$preset" )
  cmd+=( -c:a copy -map_metadata 0 )
  cmd+=( "$output_file" )

  if (( dry_run == 1 )); then
    echo "[DRY-RUN] ${cmd[@]}"
  else
    # Run ffmpeg, capture failure but don't exit script (so one bad file doesn't stop batch)
    if "${cmd[@]}" < /dev/null; then
       ((success++))
    else
       echo "[ERROR] Failed to crop: $f" >&2
    fi
  fi
done

echo "-------------------------------------------------------------------------------"
if (( dry_run == 0 )); then
  echo "[DONE] Successfully processed $success / $total files."
else
  echo "[DONE] Dry run complete."
fi