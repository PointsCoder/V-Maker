#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# mp4size.sh — Batch inspect video dimensions, FPS, duration, and AR.
#
# Features
#   - Input is a single file or a directory (recursive search not enabled by default).
#   - Robust Parsing:
#       * Uses Key-Value parsing to strictly map metadata (width, height, etc.)
#         regardless of FFmpeg output order.
#       * Retrieves Duration from container format (more reliable) and resolution
#         from video stream.
#   - Output formats:
#       * Table (default) : Human readable aligned columns.
#       * CSV (--csv)     : filename,width,height,fps,duration
#       * JSON (--json)   : Machine readable JSON array.
#   - FPS handling:
#       * Automatically converts fractional FPS (e.g., 30000/1001) to decimal (29.97).
#   - Robustness:
#       * Includes workarounds for Anaconda/system shell library conflicts (libtinfo).
#
# Usage
#   mp4size.sh [-i INPUT | INPUT_DIR]
#              [--csv | --json]
#              [--exts "mp4,mov,mkv,webm"]
#
# Examples
#   # Check all videos in current folder
#   ./mp4size.sh .
#
#   # Check specific file with JSON output
#   ./mp4size.sh -i video.mp4 --json
# -----------------------------------------------------------------------------

# Note: 'set -e' is removed to prevent crash on minor environment warnings (like libtinfo)
set -u

print_usage() { sed -n '1,40p' "$0"; exit "${1:-1}"; }

# ------------------------------- Defaults ------------------------------------
input_path=""
out_fmt="table"        # table | csv | json
exts="mp4,mov,mkv,webm"

# ---------------------------- Parse arguments --------------------------------
positional_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)   input_path="${2:?}"; shift 2 ;;
    --csv)        out_fmt="csv"; shift ;;
    --json)       out_fmt="json"; shift ;;
    --exts)       exts="${2:?}"; shift 2 ;;
    -h|--help)    print_usage 0 ;;
    -*)           echo "Error: unknown option: $1" >&2; exit 1 ;;
    *)            positional_args+=("$1"); shift ;;
  esac
done

# If -i not provided, accept a single positional argument
if [[ -z "$input_path" ]]; then
  if [[ ${#positional_args[@]} -eq 1 ]]; then
    input_path="${positional_args[0]}"
  else
    echo "Error: Please provide an input file or directory." >&2; exit 1
  fi
fi

if ! command -v ffprobe >/dev/null 2>&1; then
    echo "Error: ffprobe not found in PATH." >&2
    exit 1
fi

# ------------------------------ Gather files ---------------------------------
files=()
if [[ -f "$input_path" ]]; then
  files+=("$input_path")
elif [[ -d "$input_path" ]]; then
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
else
  echo "Error: Input not found: $input_path" >&2; exit 1
fi

if (( ${#files[@]} == 0 )); then
  echo "No video files found." >&2; exit 0
fi

# ------------------------------ Headers --------------------------------------
if [[ "$out_fmt" == "table" ]]; then
  printf "%-38s | %-12s | %-6s | %-6s | %-10s\n" "Filename" "Resolution" "AR" "FPS" "Duration"
  printf "%s\n" "---------------------------------------------------------------------------------------"
elif [[ "$out_fmt" == "csv" ]]; then
  echo "filename,width,height,fps,duration_sec"
elif [[ "$out_fmt" == "json" ]]; then
  echo "["
fi

# ------------------------------ Loop & Probe ---------------------------------
count=0
total=${#files[@]}

for f in "${files[@]}"; do
  ((count++))
  
  # PROBE LOGIC (Robust)
  # 1. LD_LIBRARY_PATH="" prevents Anaconda libtinfo conflict.
  # 2. We request both stream entries (width, height, fps) and format entries (duration).
  # 3. We use -of default=noprint_wrappers=1:nokey=0 to get "key=value" output.
  raw_data=$(LD_LIBRARY_PATH="" ffprobe -v error -select_streams v:0 \
             -show_entries stream=width,height,r_frame_rate \
             -show_entries format=duration \
             -of default=noprint_wrappers=1:nokey=0 "$f" 2>/dev/null || true)

  # Initialize variables
  w=0
  h=0
  fps_raw="0/0"
  dur_raw="0"

  # Parse Key=Value output line by line
  while IFS='=' read -r key value; do
      # Trim carriage returns if any
      value="${value//$'\r'/}"
      case "$key" in
          width)        w="$value" ;;
          height)       h="$value" ;;
          r_frame_rate) fps_raw="$value" ;;
          duration)     dur_raw="$value" ;;
      esac
  done <<< "$raw_data"

  # CALCULATIONS
  
  # FPS: Convert "30000/1001" -> "29.97"
  fps=$(echo "$fps_raw" | awk -F'/' '{ if ($2 > 0) printf "%.2f", $1/$2; else print "0" }')
  
  # Duration: Keep 2 decimal places
  duration=$(echo "$dur_raw" | awk '{printf "%.2f", $1}')
  
  # Aspect Ratio
  ar="N/A"
  if [[ "$h" =~ ^[0-9]+$ ]] && [[ "$h" -gt 0 ]]; then
     ar=$(awk -v w="$w" -v h="$h" 'BEGIN { printf "%.2f", w/h }')
  fi

  filename=$(basename -- "$f")

  # ------------------------------ Output Logic -------------------------------
  if [[ "$out_fmt" == "table" ]]; then
    # Truncate filename for table view
    display_name="${filename}"
    if [ ${#display_name} -gt 36 ]; then
        display_name="${display_name:0:33}..."
    fi
    printf "%-38s | %-4s x %-4s | %-6s | %-6s | %-10s\n" "$display_name" "$w" "$h" "$ar" "$fps" "${duration}s"

  elif [[ "$out_fmt" == "csv" ]]; then
    echo "${filename},${w},${h},${fps},${duration}"

  elif [[ "$out_fmt" == "json" ]]; then
    comma=","
    if (( count == total )); then comma=""; fi
    cat <<EOF
  {
    "filename": "$filename",
    "width": "$w",
    "height": "$h",
    "fps": "$fps",
    "duration": "$duration"
  }$comma
EOF
  fi
done

if [[ "$out_fmt" == "json" ]]; then
  echo "]"
fi