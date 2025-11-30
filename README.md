# ViCo - Recursive Video Compressor & Optimizer

**ViCo** (`vicomp.sh`) is a powerful command-line and menu-driven tool for recursively optimizing video collections. It intelligently handles resolution scaling, hardware acceleration (NVENC, QSV, VAAPI), and audio processing while offering robust reporting capabilities.

## Features

* **Interactive Menu:** Run without arguments to open a TUI menu to configure all settings easily.
* **Hardware Acceleration:** Auto-detects and uses NVIDIA NVENC, Intel QSV, or generic VAAPI.
* **Smart Audio:** * Defaults to **Copying** audio streams intact.
    * Optional **Downmix** mode converts surround sound to Stereo AAC for compatibility.
* **Subtitles:** Automatically downloads subtitles matching your system language (if none exist in the file). Includes timeout protection.
* **Reporting:** Generates a clean HTML report showing file size reduction percentages and **average encoding FPS**.

## Prerequisites

* `ffmpeg`
* `ffprobe`
* `subliminal` (Optional, for subtitles)

## Usage

### 1. Interactive Menu
Simply run the script with no arguments:
```bash
./vicomp.sh
```

### 2. Command Line
```bash
./vicomp.sh [FLAGS] [DIRECTORY]
```

#### Flags
| Flag | Description |
| :--- | :--- |
| `--menu` | Force open the interactive menu. |
| `-r`, `--res <720\|1080\|2160>` | Set target resolution (Default: 1080). |
| `--downmix` | Re-encode audio and downmix to Stereo (Default: Copy audio). |
| `--html` | Generate `vico_report.html` with compression & FPS stats. |
| `-k`, `--keep` | Keep original files (save as `_optimized.mp4`). |
| `-s`, `--subs` | Download subtitles if missing (matches system language). |
| `--no-hw` | Force CPU encoding. |

#### Examples

**Standard 1080p Optimization (Overwrite, Copy Audio):**
```bash
./vicomp.sh /media/movies
```

**Generate Report + Downmix Audio to Stereo:**
```bash
./vicomp.sh --html --downmix /media/tv
```

**Force CPU, Keep Originals, 720p:**
```bash
./vicomp.sh --no-hw -k -r 720 /media/archive
```