#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# mp4stack.sh — Spatially stack many videos into an N×M grid using ffmpeg
#
# Features
#   - Input is a folder (sorted by filename). Supports both `-i DIR` and a
#     positional DIR argument (e.g., `mp4stack.sh -n 2 -m 3 ./clips`).
#   - Arrange videos into an N×M grid (row-major): top-left to bottom-right.
#   - Per-cell resize with aspect-ratio preserved, then pad to exact cell size.
#   - Duration policy:
#       * --fit-duration shortest : stop when the shortest input ends (default).
#       * --fit-duration longest  : pad each clip by cloning last frame so the
#                                  grid lasts as long as the longest input.
#   - Audio policy:
#       * --audio first : keep audio from the first input file.
#       * --audio mix   : mix all available audio tracks (with amix).
#       * --audio none  : drop audio (DEFAULT).
#   - Cell size:
#       * Default cell size is 640×360.
#       * If the user did NOT set --cell-width/--cell-height, the script will
#         auto-detect cell size from the FIRST video’s native resolution.
#   - Output size = (cell_width * cols) × (cell_height * rows).
#   - Logs: verbose by default; use --quiet to show only ffmpeg errors.
#   - Requires: ffmpeg, ffprobe
#
# Usage
#   mp4stack.sh -n ROWS -m COLS [-i INPUT_DIR | INPUT_DIR]
#               [-o OUTPUT_MP4]
#               [--fit-duration shortest|longest]
#               [--audio first|mix|none]
#               [--cell-width W] [--cell-height H]
#               [--exts "mp4,mov,mkv,webm"] [--limit K]
#               [--fps 30] [--crf 23] [--preset medium] [--quiet]
# -----------------------------------------------------------------------------

set -euo pipefail

print_usage() { sed -n '1,200p' "$0"; exit "${1:-1}"; }

# ------------------------------- Defaults ------------------------------------
rows=""
cols=""
input_dir=""
output_mp4=""
fit_duration="shortest"     # shortest | longest
audio_mode="none"           # first | mix | none   (DEFAULT: muted)
cell_w=640
cell_h=360
exts="mp4,mov,mkv,webm"
limit=""                    # default: N*M
fps=30
crf=23
preset="medium"
verbose=1

# Track whether user explicitly set cell size (to decide auto-detect behavior)
user_set_cell_w=0
user_set_cell_h=0

# ---------------------------- Parse arguments --------------------------------
positional_dirs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--rows)        rows="${2:?}"; shift 2 ;;
    -m|--cols)        cols="${2:?}"; shift 2 ;;
    -i|--input-dir)   input_dir="${2:?}"; shift 2 ;;
    -o|--output)      output_mp4="${2:?}"; shift 2 ;;
    --fit-duration)   fit_duration="${2:?}"; shift 2 ;;
    --audio)          audio_mode="${2:?}"; shift 2 ;;
    --cell-width)     cell_w="${2:?}"; user_set_cell_w=1; shift 2 ;;
    --cell-height)    cell_h="${2:?}"; user_set_cell_h=1; shift 2 ;;
    --exts)           exts="${2:?}"; shift 2 ;;
    --limit)          limit="${2:?}"; shift 2 ;;
    --fps)            fps="${2:?}"; shift 2 ;;
    --crf)            crf="${2:?}"; shift 2 ;;
    --preset)         preset="${2:?}"; shift 2 ;;
    --quiet)          verbose=0; shift ;;
    -h|--help)        print_usage 0 ;;
    -*)
      echo "Error: unknown option: $1" >&2; print_usage 2 ;;
    *)
      positional_dirs+=("$1"); shift ;;
  esac
done

# If -i not provided, accept a single positional directory
if [[ -z "$input_dir" ]]; then
  if [[ ${#positional_dirs[@]} -eq 1 ]]; then
    input_dir="${positional_dirs[0]}"
  elif [[ ${#positional_dirs[@]} -gt 1 ]]; then
    echo "Error: multiple positional directories provided; use -i/--input-dir." >&2
    exit 1
  fi
fi

# ------------------------------ Validation -----------------------------------
[[ -n "$rows" && "$rows" =~ ^[0-9]+$ && "$rows" -ge 1 ]] || { echo "Error: --rows must be >=1." >&2; exit 1; }
[[ -n "$cols" && "$cols" =~ ^[0-9]+$ && "$cols" -ge 1 ]] || { echo "Error: --cols must be >=1." >&2; exit 1; }
[[ -n "$input_dir" && -d "$input_dir" ]] || { echo "Error: INPUT_DIR must be an existing directory." >&2; exit 1; }
case "$fit_duration" in shortest|longest) ;; *) echo "Error: --fit-duration must be shortest|longest." >&2; exit 1 ;; esac
case "$audio_mode" in first|mix|none) ;; *) echo "Error: --audio must be first|mix|none." >&2; exit 1 ;; esac
[[ "$cell_w" =~ ^[0-9]+$ && "$cell_w" -ge 8 ]] || { echo "Error: --cell-width invalid." >&2; exit 1; }
[[ "$cell_h" =~ ^[0-9]+$ && "$cell_h" -ge 8 ]] || { echo "Error: --cell-height invalid." >&2; exit 1; }
[[ "$fps" =~ ^[0-9]+$ && "$fps" -ge 1 ]] || { echo "Error: --fps invalid." >&2; exit 1; }
[[ "$crf" =~ ^[0-9]+$ && "$crf" -ge 0 && "$crf" -le 51 ]] || { echo "Error: --crf invalid." >&2; exit 1; }
case "$preset" in ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow) ;; *) echo "Warning: unusual --preset '$preset'." >&2 ;; esac

command -v ffmpeg  >/dev/null 2>&1 || { echo "Error: ffmpeg not found in PATH." >&2; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo "Error: ffprobe not found in PATH." >&2; exit 1; }

# Compute default output path
if [[ -z "$output_mp4" ]]; then
  output_mp4="${input_dir%/}/grid_${rows}x${cols}.mp4"
fi

# Max inputs default
grid_cap=$((rows * cols))
if [[ -z "$limit" ]]; then
  limit="$grid_cap"
fi
[[ "$limit" =~ ^[0-9]+$ && "$limit" -ge 1 ]] || { echo "Error: --limit invalid." >&2; exit 1; }

# ------------------------------ Gather files (robust) ------------------------
# Build find predicates for extensions (case-insensitive)
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

# Read file names safely with NUL separators (handles spaces/UTF-8 correctly)
files=()
while IFS= read -r -d '' f; do
  files+=("$f")
done < <(eval "find \"\$input_dir\" -maxdepth 1 -type f \( $pred \) -print0 | sort -z")

if (( ${#files[@]} == 0 )); then
  echo "No input videos found in: $input_dir (exts: $exts)" >&2
  exit 1
fi
if (( ${#files[@]} > limit )); then
  files=( "${files[@]:0:limit}" )
fi
inputs_count=${#files[@]}

# ------------------------------ Auto cell size -------------------------------
# If the user did NOT explicitly set cell width/height, adopt the FIRST video’s native resolution.
if (( user_set_cell_w == 0 || user_set_cell_h == 0 )); then
  first_w=$(ffprobe -v error -select_streams v:0 -show_entries stream=width  -of csv=p=0 "${files[0]}" | head -n1 || true)
  first_h=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "${files[0]}" | head -n1 || true)
  if [[ "$first_w" =~ ^[0-9]+$ && "$first_h" =~ ^[0-9]+$ && "$first_w" -gt 0 && "$first_h" -gt 0 ]]; then
    if (( user_set_cell_w == 0 )); then cell_w="$first_w"; fi
    if (( user_set_cell_h == 0  )); then cell_h="$first_h"; fi
    echo "[INFO] Auto cell size from first video: ${cell_w}x${cell_h}"
  else
    echo "[WARN] Failed to probe first video size; keep default cell ${cell_w}x${cell_h}"
  fi
fi

# ------------------------------ Probe durations ------------------------------
durations=()
max_dur=0
for f in "${files[@]}"; do
  dur=$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$f" 2>/dev/null | head -n1)
  [[ -n "$dur" ]] || dur="0"
  durations+=( "$dur" )
  mx=$(awk -v a="$max_dur" -v b="$dur" 'BEGIN{ if (a>b) print a; else print b }')
  max_dur="$mx"
done

# ------------------------------ Build filter graph ---------------------------
ff_loglevel=info
(( verbose == 0 )) && ff_loglevel=error

filter_parts=()      # pieces of filter_complex joined by ';'
in_opts=()           # repeated -i inputs
layout_elems=()      # xstack layout strings x_y per tile

for ((k=0; k<inputs_count; k++)); do
  f="${files[$k]}"
  in_opts+=( -i "$f" )

  # Input video label for kth input is "[k:v]". We will produce "[vs{k}]".
  vin="[${k}:v]"
  vout="[vs$k]"

  # Per-tile preprocess: fps -> scale (keep AR) -> pad -> setsar -> format
  vchain="$vin fps=fps=${fps},scale=${cell_w}:${cell_h}:force_original_aspect_ratio=decrease,pad=${cell_w}:${cell_h}:(ow-iw)/2:(oh-ih)/2,setsar=1"

  # Extend to longest: clone last frame for missing tail (if requested)
  if [[ "$fit_duration" == "longest" ]]; then
    pad_sec=$(awk -v mx="$max_dur" -v d="${durations[$k]}" 'BEGIN{v=mx-d; if (v<0) v=0; printf "%.6f", v}')
    if awk -v v="$pad_sec" 'BEGIN{exit !(v>0.0005)}'; then
      vchain="${vchain},tpad=stop_mode=clone:stop_duration=${pad_sec}"
    fi
  fi

  vchain="${vchain},format=yuv420p${vout}"
  filter_parts+=( "$vchain" )

  # Tile layout position
  row=$(( k / cols ))
  col=$(( k % cols ))
  x=$(( col * cell_w ))
  y=$(( row * cell_h ))
  layout_elems+=( "${x}_${y}" )
done

# If only one input, bypass xstack for a simpler graph
stack_out="[stackout]"
if (( inputs_count == 1 )); then
  filter_parts+=( "[vs0]${stack_out}" )
else
  vouts_joined=""
  for ((k=0; k<inputs_count; k++)); do
    vouts_joined="${vouts_joined}[vs${k}]"
  done
  layout_joined=$(IFS='|'; echo "${layout_elems[*]}")
  stack_filter="${vouts_joined}xstack=inputs=${inputs_count}:layout=${layout_joined}${stack_out}"
  filter_parts+=( "$stack_filter" )
fi

# ------------------------------ Audio handling -------------------------------
# Detect which inputs have audio; amix input pins need bracketed labels like [0:a]
has_audio_any=0
audio_labels=()
for ((k=0; k<inputs_count; k++)); do
  f="${files[$k]}"
  a_streams=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$f" | wc -l | tr -d ' ')
  if (( a_streams > 0 )); then
    has_audio_any=1
    audio_labels+=( "[$k:a]" )
  fi
done

# Join all filter parts
filter_complex=$(IFS=';'; echo "${filter_parts[*]}")

# ------------------------------ Build command --------------------------------
cmd=( ffmpeg -v "$ff_loglevel" -y )
cmd+=( "${in_opts[@]}" )
cmd+=( -filter_complex "$filter_complex" )
cmd+=( -map "$stack_out" -c:v libx264 -crf "$crf" -preset "$preset" -movflags +faststart )

case "$audio_mode" in
  none)
    # Drop audio explicitly
    cmd+=( -an )
    ;;
  first)
    # Keep audio from the first input that actually has an audio stream.
    if (( has_audio_any == 1 )); then
      first_a=""
      for ((k=0; k<inputs_count; k++)); do
        f="${files[$k]}"
        a_streams=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$f" | wc -l | tr -d ' ')
        if (( a_streams > 0 )); then
          first_a="${k}:a"   # IMPORTANT: map input stream (no brackets)
          break
        fi
      done
      if [[ -n "$first_a" ]]; then
        cmd+=( -map "$first_a" -c:a aac )
      else
        cmd+=( -an )
      fi
    else
      cmd+=( -an )
    fi
    ;;
  mix)
    # Mix all available audio streams using amix (needs bracketed pins in filtergraph).
    if (( has_audio_any == 1 )); then
      n_inputs=${#audio_labels[@]}
      amix_in=$(IFS=''; echo "${audio_labels[*]}")   # e.g., [0:a][1:a]...
      amix_out="[amixed]"
      # Append amix to filter graph
      filter_complex="${filter_complex};${amix_in}amix=inputs=${n_inputs}:dropout_transition=0:normalize=0${amix_out}"
      # Rebuild cmd to use updated filter_complex
      cmd=( ffmpeg -v "$ff_loglevel" -y "${in_opts[@]}" -filter_complex "$filter_complex" )
      cmd+=( -map "$stack_out" -c:v libx264 -crf "$crf" -preset "$preset" -movflags +faststart )
      cmd+=( -map "$amix_out" -c:a aac )
    else
      cmd+=( -an )
    fi
    ;;
esac

# For shortest policy we can end output when the shortest stream ends.
[[ "$fit_duration" == "shortest" ]] && cmd+=( -shortest )

# Final common output opts
cmd+=( -map_metadata -1 -pix_fmt yuv420p "$output_mp4" )

# ------------------------------ Run ------------------------------------------
echo "[INFO] Grid: ${rows}x${cols}  Inputs: ${inputs_count}  Cell: ${cell_w}x${cell_h}  FPS: ${fps}"
echo "[INFO] Fit-duration: ${fit_duration}  Audio: ${audio_mode}  Output: ${output_mp4}"
if [[ "$fit_duration" == "longest" ]]; then
  echo "[INFO] Max duration (s): ${max_dur}"
fi
if (( verbose == 1 )); then
  echo "[INFO] Running ffmpeg command:"
  printf ' %q' "${cmd[@]}"; echo
fi

"${cmd[@]}"
echo "[OK] Wrote: $output_mp4"
