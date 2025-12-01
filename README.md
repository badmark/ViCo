# ViCo - Recursive Video Compressor (TUI Edition)

**ViCo** (`vicomp.sh`) is a robust, menu-driven Bash utility for recursively optimizing video collections. It features a text-based user interface (TUI) for easy configuration, automatic hardware acceleration detection (NVENC, QSV, VAAPI), and intelligent error handling for robust batch processing.

## Features

* **Interactive Menu (TUI):** A user-friendly text interface to browse directories and toggle settings without memorizing flags.
* **Hardware Acceleration:** Automatically detects and prioritizes:
  1. **NVIDIA NVENC**
  2. **Intel QSV (Quick Sync Video)** - *Uses explicit `iHD` driver handling.*
  3. **VAAPI (Intel/AMD Generic)**
  4. **CPU (Software Fallback)**
* **Robust Path Handling:** Safely handles filenames with spaces, special characters, and executes reliably even if the shell environment is unstable.
* **Smart Audio:** * **Default:** Copies audio streams bit-for-bit (no quality loss). 
    * **Downmix:** Optional mode to re-encode and downmix multi-channel audio to Stereo AAC.
* **Live Reporting:** Generates a detailed HTML report (`vico_report.html`) that:
    * **Auto-refreshes** every 5 seconds during processing.
    * Tracks Original Size, New Size, Percentage Reduced, and Encoding FPS.
    * **Summary:** Displays total storage space saved (MB/GB) and total execution time upon completion.
* **Safety:** Includes signal trapping to clean up temporary files if the script is interrupted (Ctrl+C).

## Prerequisites

The script will attempt to auto-install dependencies if they are missing (supports Debian/Ubuntu, Fedora/RHEL, Arch, OpenSUSE).

* **bash**
* **ffmpeg** (Required): For video encoding.
* **ffprobe** (Required): For video stream validation.
* **dialog** (Required): For the interactive menu interface.
* **subliminal** (Optional): Required only if using the `-s` flag for subtitles.

## Usage

### 1. Interactive Mode (Recommended)
Simply run the script. It will launch a graphical menu in the terminal allowing you to browse for a folder and configure settings.
```bash
./vicomp.sh
```

### 2. Command Line / Headless
You can bypass the menu by providing flags or a directory argument.

```bash
./vicomp.sh [FLAGS] [DIRECTORY]
```

#### Flags
| Flag | Description |
| :--- | :--- |
| `-h`, `--help` | Show help message. |
| `--menu` | Force launch of the interactive configuration menu. |
| `-k`, `--keep` | **Keep Mode:** Do NOT overwrite original files. Saves as `_optimized.mp4`. |
| `-s`, `--subs` | **Subtitles:** Download subtitles matching system language. |
| `-r`, `--res VAL` | **Resolution:** Target vertical resolution (720, 1080, 2160). |
| `--no-hw` | **Force Software:** Disable hardware acceleration. |
| `--downmix` | **Downmix Audio:** Re-encode audio to Stereo AAC (Default is Copy). |
| `--no-recursive` | **Flat Scan:** Process only the target folder, ignoring subdirectories. |
| `--html` | **Report:** Generate `vico_report.html` with live stats. |

### Examples

**Open the Menu for the current directory:**
```bash
./vicomp.sh
```

**Headless 1080p compression (Overwrite originals, Copy Audio):**
```bash
./vicomp.sh /media/movies
```

**Process current folder only (no subfolders), Downmix audio:**
```bash
./vicomp.sh --no-recursive --downmix .
```

**Force CPU encoding for 4K files with HTML report:**
```bash
./vicomp.sh --no-hw --html -r 2160 /path/to/videos 265 24
```

## Installation

1.  Save the script code to a file named `vicomp.sh`.
2.  Make the script executable:
    ```bash
    chmod +x vicomp.sh
    ```
3.  Run it:
    ```bash
    ./vicomp.sh
    ```