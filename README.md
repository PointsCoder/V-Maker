# 🎬 V-Maker: Lightweight Video & Image Utility Suite

A collection of high-quality, portable **Bash utilities** built on **FFmpeg** for flexible video and image manipulation.  
All tools are self-contained, dependency-minimal, and rigorously documented — ideal for automation, data processing, and research visualization.

---

## 📋 Requirements

- **bash** ≥ 4.0  
- **ffmpeg** ≥ 4.2  
- **ffprobe** (for scripts that probe metadata)
- **imagemagick**

Install on Linux/macOS:

    sudo apt install ffmpeg
    sudo apt-get install imagemagick
---

## 🧩 Included Tools

| Script | Description |
|:--|:--|
| [`imgstack.sh`](#imgstacksh) | Stack multiple images into an N×M grid (contain/cover mode). |
| [`mp4stack.sh`](#mp4stacksh) | Arrange videos spatially into an N×M grid (row-major). |
| [`mp4concat.sh`](#mp4concatsh) | Concatenate videos in time (match resolution, optional audio). |
| [`mp4trim.sh`](#mp4trimsh) | Trim videos by start/end or duration (copy or re-encode). |
| [`mp4speed.sh`](#mp4speedsh) | Speed up or slow down video + audio by any factor. |
| [`mp4flip.sh`](#mp4flipsh) | Flip videos horizontally, vertically, or both. |
| [`mp4frame.sh`](#mp4framesh) | Extract frames from videos as images. |
| [`webm2mp4.sh`](#webm2mp4sh) | Convert WEBM → MP4 (H.264 + AAC). |
| [`png2jpg.sh`](#png2jpgsh) | Convert PNG → JPG with configurable quality. |

---

## 🛠️ Installation

    # Clone the repository and make scripts executable
    git clone https://github.com/<yourname>/v-maker.git
    cd v-maker
    chmod +x *.sh

Optionally add them to your PATH:

    export PATH="$PATH:$(pwd)"

---

## 🖼️ imgstack.sh

Spatially stack multiple images into an N×M grid.

    ./imgstack.sh -n 2 -m 3 ./images --fit-mode cover

**Features**
- Preserve or crop aspect ratio (`contain` / `cover`)
- Auto-detect cell size from the first image
- Output a single PNG (`grid_{ROWS}x{COLS}.png`)

**Usage**

    imgstack.sh -n ROWS -m COLS [-i INPUT_DIR | INPUT_DIR]
                [-o OUTPUT_PNG]
                [--cell-width W] [--cell-height H]
                [--fit-mode contain|cover]
                [--exts "png,jpg,jpeg,webp"] [--limit K]
                [--quiet]

**Examples**

    # 2×4 grid, default contain mode
    ./imgstack.sh -n 2 -m 4 "/path/to/image_folder"

    # 3×2 grid, cover mode, auto cell from first image
    ./imgstack.sh -n 3 -m 2 ./imgs --fit-mode cover

    # Manually set cell size and custom output
    ./imgstack.sh -n 2 -m 3 ./imgs --cell-width 512 --cell-height 512 -o out/grid.png

    # Only use the first 6 images
    ./imgstack.sh -n 2 -m 3 ./imgs --limit 6

---

## 🎞️ mp4stack.sh

Combine several videos spatially into an N×M grid.

    ./mp4stack.sh -n 2 -m 3 ./clips --fit-duration longest

**Highlights**
- Auto cell-size detection (falls back to 640×360)
- Flexible duration policy: `shortest` or `longest`
- Audio policy: `first`, `mix`, or `none` (default)
- Configurable `--fps`, `--crf`, `--preset`

**Usage**

    mp4stack.sh -n ROWS -m COLS [-i INPUT_DIR | INPUT_DIR]
                [-o OUTPUT_MP4]
                [--fit-duration shortest|longest]
                [--audio first|mix|none]
                [--cell-width W] [--cell-height H]
                [--exts "mp4,mov,mkv,webm"] [--limit K]
                [--fps 30] [--crf 23] [--preset medium] [--quiet]

---

## ⏩ mp4concat.sh

Concatenate multiple videos in time (resolution normalized to the first input).

    ./mp4concat.sh --fps 30 --unmute clips/

**Highlights**
- Auto-scale/pad to the first video’s resolution
- Optional CFR (`--fps`)
- Works with files and directories; filename-sorted

**Usage**

    mp4concat.sh [-c CRF] [-p PRESET] [--fps FPS] [--unmute|--mute]
                 [-o OUTPUT_DIR] [--quiet] <input_path>...

**Examples**

    # Concatenate files (video-only by default), force 30 fps
    ./mp4concat.sh --fps 30 a.mp4 b.mp4 c.mp4

    # Concatenate all MP4s in a folder, keep audio if possible
    ./mp4concat.sh --unmute /path/to/folder

    # Higher quality, slower preset, write to a directory
    ./mp4concat.sh -c 20 -p slow -o out_dir clips1/ clips2/

---

## ✂️ mp4trim.sh

Trim video by start/end or duration.

    ./mp4trim.sh -s 10 -e 25 --reencode -c 22 -p fast input.mp4

**Highlights**
- Accurate `--reencode` (enforce FPS) or fast `--copy` (keyframe aligned)
- Default muted; use `--audio` to keep audio
- Outputs use `yuv420p` and `+faststart` in re-encode mode

**Usage**

    mp4trim.sh -s START -e END  [--copy|--reencode] [-c CRF] [-p PRESET] [-a AUDIO_BITRATE]
               [-o OUTPUT_DIR] [--fps N] [--audio] [--quiet] <input_path>...
    mp4trim.sh -s START -d DURATION  [--copy|--reencode] [...]

**Notes**
- Copy mode: `-ss` before `-i` (fast), FPS unchanged.
- Re-encode: `-ss` after `-i` (accurate), FPS enforced with `-vf "fps=N"`.

---

## ⚡ mp4speed.sh

Speed up or slow down MP4s (video + audio).

    ./mp4speed.sh -n 2 --fps 30 --unmute /path/video.mp4

**Highlights**
- Video: `setpts = PTS / N`
- Audio: automatic `atempo` chaining within [0.5, 2.0] per stage
- Batch files or directories; web-friendly output (`yuv420p`, `+faststart`)

**Usage**

    mp4speed.sh -n SPEED [-c CRF] [-p PRESET] [-o OUTPUT_DIR] [--quiet]
                [--fps FPS] [--unmute|--mute] <input_path>...

**Examples**

    # 2× speed, default quality, force 30 fps
    ./mp4speed.sh -n 2 --fps 30 /path/video.mp4

    # 1.25× speed, higher quality, keep audio
    ./mp4speed.sh -n 1.25 --unmute -c 20 -p slow /path/video.mp4

    # Batch: 4× speed, quiet logs, force 60 fps
    ./mp4speed.sh -n 4 --fps 60 --quiet /path/to/folder

    # Slow down to 0.5×, keep audio
    ./mp4speed.sh -n 0.5 --unmute /path/video.mp4

---

## 🔄 mp4flip.sh

Flip videos horizontally, vertically, or both.

    ./mp4flip.sh --hflip --vflip -c 20 -p slow ./video.mp4

**Highlights**
- Optional constant FPS (`--fps`)
- Toggle audio (`--unmute` / default muted)
- Stable timestamps; CFR-friendly for the web

**Usage**

    mp4flip.sh [--vflip] [--hflip] [-c CRF] [-p PRESET] [--fps FPS]
               [-o OUTPUT_DIR] [--unmute|--mute] [--quiet] <input_path>...

---

## 🔁 webm2mp4.sh

Convert WEBM → MP4 (H.264 + AAC).

    ./webm2mp4.sh --video-codec h264_nvenc ./videos

**Highlights**
- Adjustable CRF, preset, audio bitrate
- GPU acceleration via `h264_nvenc`
- Recursive directory support

**Usage**

    webm2mp4.sh [-c CRF] [-p PRESET] [-a AUDIO_BITRATE]
                [--video-codec {libx264|h264_nvenc}] [--quiet] <input_path>...

**Examples**

    # Defaults (crf=23, preset=medium, aac=128k)
    ./webm2mp4.sh /path/to/clip.webm

    # Higher quality: lower CRF, slower preset
    ./webm2mp4.sh -c 18 -p slow /path/to/clip.webm

    # Faster encode for previews
    ./webm2mp4.sh -p veryfast /path/to/clip.webm

    # Recursively convert with NVIDIA encoder
    ./webm2mp4.sh --video-codec h264_nvenc /path/to/dir

---

## 🖼️ png2jpg.sh

Convert PNG images to JPG with controllable quality.

    ./png2jpg.sh -q 3 ./images

**Highlights**
- Files and/or directories (recursive `*.png`)
- Strips metadata for compact output
- Uses `format=yuvj420p` (broad compatibility)

**Usage**

    png2jpg.sh [-q QUALITY] <input_path> [<input_path> ...]

**Examples**

    # Single PNG, default quality
    ./png2jpg.sh /path/to/image.png

    # Higher quality (smaller q => higher quality)
    ./png2jpg.sh -q 3 /path/to/image.png

    # Recursively convert a directory (q=5)
    ./png2jpg.sh -q 5 /path/to/dir

---

## 📦 Example Workflow

    # 1) Convert raw WEBMs → MP4
    ./webm2mp4.sh ./raw/

    # 2) Trim segments
    ./mp4trim.sh -s 3 -e 15 ./raw/*.mp4

    # 3) Accelerate playback for preview
    ./mp4speed.sh -n 2 ./trimmed/

    # 4) Stack results into a comparison grid
    ./mp4stack.sh -n 2 -m 2 ./speeded/


