#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# imgstack.sh — Spatially stack many images into an N×M grid using ffmpeg
#
# Features
#   - Input is a folder (sorted by filename). Supports both `-i DIR` and a
#     positional DIR argument (e.g., `imgstack.sh -n 2 -m 3 ./images`).
#   - Arrange images into an N×M grid (row-major): top-left to bottom-right.
#   - Per-cell resize with aspect-ratio preserved, two fit modes:
#       * contain (default): letterbox pad to cell size (no crop, may show borders)
#       * cover            : center-crop to fill cell (no borders, may crop edges)
#   - Cell size:
#       * Default 640×360.
#       * If user did NOT set --cell-width/--cell-height, the script auto-detects
#         from the FIRST image’s native resolution.
#   - Output: a single PNG image, named grid_{ROWS}x{COLS}.png by default.
#   - Robust filename handling (spaces/UTF-8) via -print0.
#   - Requires: ffmpeg
#
# Usage
#   imgstack.sh -n ROWS -m COLS [-i INPUT_DIR | INPUT_DIR]
#               [-o OUTPUT_PNG]
#               [--cell-width W] [--cell-height H]
#               [--fit-mode contain|cover]
#               [--exts "png,jpg,jpeg,webp"] [--limit K]
#               [--quiet]
#
# Examples
#   # 1) 2×4 grid, default contain mode
#   ./imgstack.sh -n 2 -m 4 "/path/to/image_folder"
#
#   # 2) 3×2 grid, cover mode (fill by cropping), cell auto from first image
#   ./imgstack.sh -n 3 -m 2 ./imgs --fit-mode cover
#
#   # 3) Manually set cell size to 512×512 and custom output file
#   ./imgstack.sh -n 2 -m 3 ./imgs --cell-width 512 --cell-height 512 -o out/grid.png
#
#   # 4) Only use the first 6 images (row-major fill)
#   ./imgstack.sh -n 2 -m 3 ./imgs --limit 6
# -----------------------------------------------------------------------------

set -euo pipefail

print_usage() { sed -n '1,200p' "$0"; exit "${1:-1}"; }

# ------------------------------- Defaults ------------------------------------
rows=""
cols=""
input_dir=""
output_png=""
cell_w=640
cell_h=360
fit_mode="contain"          # contain | cover
exts="png,jpg,jpeg,webp"
limit=""                    # default: N*M
verbose=1

# Track whether user explicitly set cell size (for auto-detect behavior)
user_set_cell_w=0
user_set_cell_h=0

# ---------------------------- Parse arguments --------------------------------
positional_dirs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--rows)        rows="${2:?}"; shift 2 ;;
    -m|--cols)        cols="${2:?}"; shift 2 ;;
    -i|--input-dir)   input_dir="${2:?}"; shift 2 ;;
    -o|--output)      output_png="${2:?}"; shift 2 ;;
    --cell-width)     cell_w="${2:?}"; user_set_cell_w=1; shift 2 ;;
    --cell-height)    cell_h="${2:?}"; user_set_cell_h=1; shift 2 ;;
    --fit-mode)       fit_mode="${2:?}"; shift 2 ;;
    --exts)           exts="${2:?}"; shift 2 ;;
    --limit)          limit="${2:?}"; shift 2 ;;
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
case "$fit_mode" in contain|cover) ;; *) echo "Error: --fit-mode must be contain|cover." >&2; exit 1 ;; esac
[[ "$cell_w" =~ ^[0-9]+$ && "$cell_w" -ge 2 ]] || { echo "Error: --cell-width invalid." >&2; exit 1; }
[[ "$cell_h" =~ ^[0-9]+$ && "$cell_h" -ge 2 ]] || { echo "Error: --cell-height invalid." >&2; exit 1; }

command -v ffmpeg  >/dev/null 2>&1 || { echo "Error: ffmpeg not found in PATH." >&2; exit 1; }

# Compute default output path
if [[ -z "$output_png" ]]; then
  output_png="${input_dir%/}/grid_${rows}x${cols}.png"
fi

# Max inputs default
grid_cap=$((rows * cols))
if [[ -z "$limit" ]]; then
  limit="$grid_cap"
fi
[[ "$limit" =~ ^[0-9]+$ && "$limit" -ge 1 ]] || { echo "Error: --limit invalid." >&2; exit 1; }

# ------------------------------ Gather files (robust) ------------------------
# Build case-insensitive predicates for extensions
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
  echo "No input images found in: $input_dir (exts: $exts)" >&2
  exit 1
fi
if (( ${#files[@]} > limit )); then
  files=( "${files[@]:0:limit}" )
fi
inputs_count=${#files[@]}

# ------------------------------ Auto cell size -------------------------------
# If user did NOT explicitly set cell size, adopt FIRST image’s native size.
if (( user_set_cell_w == 0 || user_set_cell_h == 0 )); then
  # Use ffmpeg to probe width/height; images are supported by demuxers.
  first_w=$(ffmpeg -v error -i "${files[0]}" -f null - 2>&1 | awk -F'[, ]+' '/, [0-9]+x[0-9]+/ { for(i=1;i<=NF;i++) if ($i ~ /[0-9]+x[0-9]+/) {print $i; exit}}' | cut -dx -f1 || true)
  first_h=$(ffmpeg -v error -i "${files[0]}" -f null - 2>&1 | awk -F'[, ]+' '/, [0-9]+x[0-9]+/ { for(i=1;i<=NF;i++) if ($i ~ /[0-9]+x[0-9]+/) {print $i; exit}}' | cut -dx -f2 || true)
  if [[ "$first_w" =~ ^[0-9]+$ && "$first_h" =~ ^[0-9]+$ && "$first_w" -gt 0 && "$first_h" -gt 0 ]]; then
    if (( user_set_cell_w == 0 )); then cell_w="$first_w"; fi
    if (( user_set_cell_h == 0 )); then cell_h="$first_h"; fi
    echo "[INFO] Auto cell size from first image: ${cell_w}x${cell_h}"
  else
    echo "[WARN] Failed to probe first image size; keep default cell ${cell_w}x${cell_h}"
  fi
fi

# ------------------------------ Build filter graph ---------------------------
ff_loglevel=info
(( verbose == 0 )) && ff_loglevel=error

filter_parts=()      # pieces of filter_complex joined by ';'
in_opts=()           # repeated -i inputs
layout_elems=()      # xstack layout strings x_y per tile

for ((k=0; k<inputs_count; k++)); do
  f="${files[$k]}"

  # For images, feed them as 1-second looping videos so filters work uniformly.
  # -loop 1: loop the image; -t 1: limit to 1 second; we will output a single frame.
  in_opts+=( -loop 1 -t 1 -i "$f" )

  vin="[${k}:v]"     # input label
  vout="[vs$k]"      # preprocessed output label

  # Choose per-cell fit mode
  if [[ "$fit_mode" == "contain" ]]; then
    # Keep AR, pad to cell size (may show borders)
    vchain="$vin scale=${cell_w}:${cell_h}:force_original_aspect_ratio=decrease,pad=${cell_w}:${cell_h}:(ow-iw)/2:(oh-ih)/2,setsar=1,format=rgba${vout}"
  else
    # Scale up to fill cell then center-crop (no borders, may crop edges)
    vchain="$vin scale=${cell_w}:${cell_h}:force_original_aspect_ratio=increase,crop=${cell_w}:${cell_h},setsar=1,format=rgba${vout}"
  fi
  filter_parts+=( "$vchain" )

  # Compute position in the grid
  row=$(( k / cols ))
  col=$(( k % cols ))
  x=$(( col * cell_w ))
  y=$(( row * cell_h ))
  layout_elems+=( "${x}_${y}" )
done

# Compose the grid with xstack
stack_out="[stackout]"
if (( inputs_count == 1 )); then
  # Single input: skip xstack
  filter_parts+=( "[vs0]${stack_out}" )
else
  # Multiple inputs: feed all [vs*] into xstack explicitly
  vouts_joined=""
  for ((k=0; k<inputs_count; k++)); do
    vouts_joined="${vouts_joined}[vs${k}]"
  done
  layout_joined=$(IFS='|'; echo "${layout_elems[*]}")
  stack_filter="${vouts_joined}xstack=inputs=${inputs_count}:layout=${layout_joined}${stack_out}"
  filter_parts+=( "$stack_filter" )
fi

# Join all filter nodes
filter_complex=$(IFS=';'; echo "${filter_parts[*]}")

# ------------------------------ Build command --------------------------------
# Output a single PNG frame from the stacked stream.
cmd=( ffmpeg -v "$ff_loglevel" -y )
cmd+=( "${in_opts[@]}" )
cmd+=( -filter_complex "$filter_complex" )
cmd+=( -map "$stack_out" -frames:v 1 -f image2 -pix_fmt rgba "$output_png" )

echo "[INFO] Grid: ${rows}x${cols}  Inputs: ${inputs_count}  Cell: ${cell_w}x${cell_h}  Fit: ${fit_mode}"
echo "[INFO] Output: ${output_png}"
if (( verbose == 1 )); then
  echo "[INFO] Running ffmpeg command:"
  printf ' %q' "${cmd[@]}"; echo
fi

"${cmd[@]}"
echo "[OK] Wrote: $output_png"
