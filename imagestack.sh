#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# imagestackn.sh — Stack images into an N×M grid (tight/contain/cover) using ffmpeg
#
# Highlights
#   - New "tight" mode: compute canvas from the ORIGINAL image sizes (no scaling),
#     then place images row-major with optional horizontal alignment per row.
#   - "contain"/"cover" modes keep existing behavior with per-cell resizing.
#   - Background color: white / black / transparent / #RRGGBB (e.g., "#202020").
#   - Robust size probing: ffprobe -> (fallback) ImageMagick identify.
#
# Usage
#   imagestackn.sh -n ROWS -m COLS [-i INPUT_DIR | INPUT_DIR]
#                  [-o OUTPUT_PNG]
#                  [--fit-mode tight|contain|cover]
#                  [--cell-width W] [--cell-height H]         # for contain/cover
#                  [--gutter PX] [--align left|center|right]  # tight/contain/cover
#                  [--exts "png,jpg,jpeg,webp"] [--limit K]
#                  [--bg-color white|black|transparent|#RRGGBB]
#                  [--quiet]
#
# Examples
#   # Tight canvas from native sizes, 2 rows × 1 col, no gaps, white bg
#   ./imagestackn.sh -n 2 -m 1 ./imgs --fit-mode tight --gutter 0 --bg-color white
#
#   # Same but transparent background
#   ./imagestackn.sh -n 2 -m 1 ./imgs --fit-mode tight --bg-color transparent
#
#   # Fixed cells 5120×756, cover (no borders, may crop), centered rows
#   ./imagestackn.sh -n 2 -m 1 ./imgs --fit-mode cover --cell-width 5120 --cell-height 756 --align center
# -----------------------------------------------------------------------------

set -euo pipefail

print_usage() { sed -n '1,200p' "$0"; exit "${1:-1}"; }

# ------------------------------- Defaults ------------------------------------
rows=""
cols=""
input_dir=""
output_png=""
fit_mode="tight"          # tight | contain | cover
cell_w=640                  # used in contain/cover
cell_h=360
exts="png,jpg,jpeg,webp"
limit=""                    # default: N*M
gutter=0
align="left"                # left | center | right (per row)
bg_color="transparent"            # black | white | transparent | #RRGGBB
verbose=1

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
    --fit-mode)       fit_mode="${2:?}"; shift 2 ;;
    --cell-width)     cell_w="${2:?}"; user_set_cell_w=1; shift 2 ;;
    --cell-height)    cell_h="${2:?}"; user_set_cell_h=1; shift 2 ;;
    --exts)           exts="${2:?}"; shift 2 ;;
    --limit)          limit="${2:?}"; shift 2 ;;
    --gutter)         gutter="${2:?}"; shift 2 ;;
    --align)          align="${2:?}"; shift 2 ;;
    --bg-color)       bg_color="${2:?}"; shift 2 ;;
    --quiet)          verbose=0; shift ;;
    -h|--help)        print_usage 0 ;;
    -*)
      echo "Error: unknown option: $1" >&2; print_usage 2 ;;
    *)
      positional_dirs+=("$1"); shift ;;
  esac
done

# Derive input_dir from positional
if [[ -z "$input_dir" ]]; then
  if   [[ ${#positional_dirs[@]} -eq 1 ]]; then input_dir="${positional_dirs[0]}"
  elif [[ ${#positional_dirs[@]} -gt 1 ]]; then
    echo "Error: multiple positional directories provided; use -i/--input-dir." >&2; exit 1
  fi
fi

# ------------------------------ Validation -----------------------------------
[[ -n "$rows" && "$rows" =~ ^[0-9]+$ && "$rows" -ge 1 ]] || { echo "Error: --rows must be >=1." >&2; exit 1; }
[[ -n "$cols" && "$cols" =~ ^[0-9]+$ && "$cols" -ge 1 ]] || { echo "Error: --cols must be >=1." >&2; exit 1; }
[[ -n "$input_dir" && -d "$input_dir" ]] || { echo "Error: INPUT_DIR must be an existing directory." >&2; exit 1; }
case "$fit_mode" in tight|contain|cover) ;; *) echo "Error: --fit-mode must be tight|contain|cover." >&2; exit 1 ;; esac
[[ "$cell_w" =~ ^[0-9]+$ && "$cell_w" -ge 2 ]] || true
[[ "$cell_h" =~ ^[0-9]+$ && "$cell_h" -ge 2 ]] || true
[[ "$gutter" =~ ^[0-9]+$ && "$gutter" -ge 0 ]] || { echo "Error: --gutter must be >=0." >&2; exit 1; }
case "$align" in left|center|right) ;; *) echo "Error: --align must be left|center|right." >&2; exit 1 ;; esac
command -v ffmpeg  >/dev/null 2>&1 || { echo "Error: ffmpeg not found in PATH." >&2; exit 1; }

# Output path default
if [[ -z "$output_png" ]]; then
  output_png="${input_dir%/}/grid_${rows}x${cols}.png"
fi

# Ext filter
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

# Gather files
files=()
while IFS= read -r -d '' f; do files+=("$f"); done \
  < <(eval "find \"\$input_dir\" -maxdepth 1 -type f \( $pred \) -print0 | sort -z")

(( ${#files[@]} > 0 )) || { echo "No input images found in: $input_dir (exts: $exts)" >&2; exit 1; }

grid_cap=$((rows * cols))
if [[ -z "$limit" ]]; then limit="$grid_cap"; fi
[[ "$limit" =~ ^[0-9]+$ && "$limit" -ge 1 ]] || { echo "Error: --limit invalid." >&2; exit 1; }
if (( ${#files[@]} > limit )); then files=( "${files[@]:0:limit}" ); fi
inputs_count=${#files[@]}

# ------------------------------ Probe sizes ----------------------------------
probe_img_wh() {
  # Echo: "<w> <h>" (space separated), or empty on failure
  local f="$1"
  local wh=""
  wh="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
        -of csv=p=0:s=' ' "$f" 2>/dev/null || true)"
  if [[ -z "$wh" ]]; then
    if command -v identify >/dev/null 2>&1; then
      wh="$(identify -format '%w %h' "$f" 2>/dev/null || true)"
    fi
  fi
  echo "$wh"
}

img_w=()
img_h=()
for f in "${files[@]}"; do
  wh="$(probe_img_wh "$f")"
  if [[ -z "$wh" ]]; then
    echo "Error: probe size failed: $f" >&2
    exit 1
  fi
  img_w+=( "${wh%% *}" )
  img_h+=( "${wh##* }" )
done

# ------------------------------ Layout compute -------------------------------
canvas_w=0
canvas_h=0
x_pos=()
y_pos=()

if [[ "$fit_mode" == "tight" ]]; then
  # Row-wise: compute sum of widths and max height per row
  row_sum_w=()
  row_max_h=()
  for ((r=0; r<rows; r++)); do
    sum=0; maxh=0
    for ((c=0; c<cols; c++)); do
      idx=$(( r*cols + c ))
      (( idx >= inputs_count )) && break
      sum=$(( sum + img_w[idx] ))
      (( img_h[idx] > maxh )) && maxh=${img_h[idx]}
    done
    # add gutters between cells in a row
    used_cols=$(( idx >= inputs_count ? (inputs_count - r*cols) : cols ))
    if (( used_cols > 1 )); then sum=$(( sum + gutter*(used_cols-1) )); fi
    row_sum_w+=( "$sum" )
    row_max_h+=( "$maxh" )
    (( sum > canvas_w )) && canvas_w=$sum
  done
  # total height with gutters between rows
  for ((r=0; r<rows; r++)); do
    canvas_h=$(( canvas_h + (row_max_h[r]) ))
  done
  if (( rows > 1 )); then canvas_h=$(( canvas_h + gutter*(rows-1) )); fi

  # Now positions with per-row horizontal alignment
  y=0
  for ((r=0; r<rows; r++)); do
    row_y=$y
    # horizontal start x based on alignment
    case "$align" in
      left)   start_x=0 ;;
      center) start_x=$(( (canvas_w - row_sum_w[r]) / 2 )) ;;
      right)  start_x=$((  canvas_w - row_sum_w[r] )) ;;
    esac
    x=$start_x
    for ((c=0; c<cols; c++)); do
      idx=$(( r*cols + c ))
      (( idx >= inputs_count )) && break
      x_pos[idx]=$x; y_pos[idx]=$row_y
      x=$(( x + img_w[idx] + gutter ))
    done
    y=$(( y + row_max_h[r] + gutter ))
  done
else
  # contain/cover: uniform cell size
  if (( user_set_cell_w == 0 || user_set_cell_h == 0 )); then
    # If user didn't set, adopt FIRST image size as cell
    cell_w=${img_w[0]}
    cell_h=${img_h[0]}
    echo "[INFO] Auto cell size from first image: ${cell_w}x${cell_h}"
  fi
  canvas_w=$(( cols*cell_w + gutter*(cols-1) ))
  canvas_h=$(( rows*cell_h + gutter*(rows-1) ))

  for ((k=0; k<inputs_count; k++)); do
    r=$(( k / cols ))
    c=$(( k % cols ))
    base_x=$(( c*cell_w + gutter*c ))
    base_y=$(( r*cell_h + gutter*r ))

    if [[ "$fit_mode" == "contain" ]]; then
      # Keep AR; compute scale result to place centered
      # We will still use ffmpeg to scale/pad; here we only store the cell top-left.
      x_pos[k]=$base_x; y_pos[k]=$base_y
    else # cover
      x_pos[k]=$base_x; y_pos[k]=$base_y
    fi
  done
fi

# ------------------------------ BG color & source -----------------------------
# Convert bg_color to ffmpeg "color" + alpha
bg_ff="black"
case "$bg_color" in
  black)       bg_ff="black" ;;
  white)       bg_ff="white" ;;
  transparent) bg_ff="black@0" ;;   # transparent via 0 alpha
  \#*)         bg_ff="${bg_color#\#}"; bg_ff="0x$bg_ff" ;;  # hex
  *)           bg_ff="$bg_color" ;;
esac

# ------------------------------ Build filtergraph ----------------------------
ff_loglevel=info; (( verbose == 0 )) && ff_loglevel=error

# Inputs: first is a color canvas; then each image as a one-second loop
in_opts=( -f lavfi -i "color=c=${bg_ff}:s=${canvas_w}x${canvas_h}:r=1,format=rgba" )
for f in "${files[@]}"; do
  in_opts+=( -loop 1 -t 1 -i "$f" )
done

# Prepare per-image preprocess labels
filter_parts=()
vlabels=()
# Base is [0:v]
base="[base0]"
filter_parts+=( "[0:v]format=rgba${base}" )

for ((k=0; k<inputs_count; k++)); do
  vin="[$((k+1)):v]"
  vout="[im$k]"

  if [[ "$fit_mode" == "tight" ]]; then
    # No scaling; ensure RGBA
    filter_parts+=( "$vin format=rgba${vout}" )
  elif [[ "$fit_mode" == "contain" ]]; then
    # Scale inside cell, pad to exact cell size, then overlay at cell topleft
    filter_parts+=( "$vin scale=${cell_w}:${cell_h}:force_original_aspect_ratio=decrease,\
pad=${cell_w}:${cell_h}:(ow-iw)/2:(oh-ih)/2:color=${bg_ff},format=rgba${vout}" )
  else
    # cover: fill cell with possible crop
    filter_parts+=( "$vin scale=${cell_w}:${cell_h}:force_original_aspect_ratio=increase,\
crop=${cell_w}:${cell_h},format=rgba${vout}" )
  fi
done

# Chain overlays: base + im0 -> base1, base1 + im1 -> base2, ...
prev="$base"
for ((k=0; k<inputs_count; k++)); do
  next="[base$((k+1))]"
  ox=${x_pos[$k]:-0}; oy=${y_pos[$k]:-0}
  filter_parts+=( "${prev}[im$k]overlay=x=${ox}:y=${oy}:format=auto${next}" )
  prev="$next"
done

final_label="$prev"
filter_complex=$(IFS=';'; echo "${filter_parts[*]}")

# ------------------------------ Build command --------------------------------
cmd=( ffmpeg -v "$ff_loglevel" -y )
cmd+=( "${in_opts[@]}" )
cmd+=( -filter_complex "$filter_complex" )
cmd+=( -map "$final_label" -frames:v 1 -f image2 -pix_fmt rgba "$output_png" )

echo "[INFO] Mode=${fit_mode}  Align=${align}  Gutter=${gutter}  BG=${bg_color}"
echo "[INFO] Canvas=${canvas_w}x${canvas_h}  Grid=${rows}x${cols}  Inputs=${inputs_count}"
echo "[INFO] Output: ${output_png}"
if (( verbose == 1 )); then
  echo "[INFO] Running ffmpeg command:"; printf ' %q' "${cmd[@]}"; echo
fi

"${cmd[@]}"
echo "[OK] Wrote: $output_png"
