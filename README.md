# ViCo - Recursive Video Compressor

**ViCo** (`vicomp.sh`) is a robust Bash utility for recursively finding, validating, and compressing video files within a directory. It leverages `ffmpeg` for encoding and automatically detects available hardware acceleration (NVIDIA NVENC, Intel QSV, or VAAPI) to significantly speed up the process.

## Features

* **Recursive Scanning:** Processes video files in the specified directory and all subdirectories.
* **Hardware Acceleration:** Automatically detects and prioritizes:
  1. **NVIDIA NVENC**
  2. **Intel QSV (Quick Sync Video)**
  3. **VAAPI (Intel/AMD Generic)**
  4. **CPU (Software Fallback)**
* **Resolution Scaling:** Options to scale videos to 720p, 1080p (default), or 2160p (4K).
* **Smart Overwriting:** Choose to overwrite original files or keep separate optimized versions.
* **Subtitle Support:** Optionally downloads English subtitles using `subliminal`.
* **Format Support:** Handles MP4, MKV, MOV, and AVI containers.

## Prerequisites

The script will attempt to auto-install dependencies if they are missing (supports Debian/Ubuntu, Fedora/RHEL, Arch, OpenSUSE, Alpine).

* **ffmpeg** (Required): For video encoding.
* **ffprobe** (Required): For video stream validation.
* **subliminal** (Optional): Required only if using the `-s` flag for subtitles.

## Usage

```bash
./vicomp.sh [FLAGS] [DIRECTORY] [CODEC] [CRF]
```

### Flags

| Flag | Description |
| :--- | :--- |
| `-h`, `--help` | Show the help message and exit. |
| `-k`, `--keep` | **Keep Mode:** Do NOT overwrite original files. Saves as `filename_optimized.mp4`. |
| `-s`, `--subs` | **Subtitles:** Attempt to download English subtitles for the video. |
| `-r`, `--res VAL` | **Resolution:** Target vertical resolution. Options: `720`, `1080` (default), `2160`. |
| `--no-hw` | **Force Software:** Disable hardware acceleration and force CPU encoding. |

### Positional Arguments

1.  **DIRECTORY** (Optional): The target directory to scan. Defaults to the current directory (`.`).
2.  **CODEC** (Optional): Video codec to use.
    * `264` (Default): H.264 / AVC
    * `265` (or `hevc`): H.265 / HEVC
3.  **CRF** (Optional): Constant Rate Factor (Quality). Lower is better quality, higher is lower file size.
    * Default: `23`
    * Range: Typically 18-28.

## Examples

**1. Standard compression (Overwrite originals, 1080p, H.264):**
```bash
./vicomp.sh /path/to/movies
```

**2. Compress to H.265, Keep originals, High Quality (CRF 20):**
```bash
./vicomp.sh -k /path/to/movies 265 20
```

**3. Downscale to 720p and download subtitles:**
```bash
./vicomp.sh -r 720 -s /path/to/tv_shows
```

**4. Force CPU encoding (ignore GPU) for 4K:**
```bash
./vicomp.sh --no-hw -r 2160 /path/to/videos 265 24
```

## Installation

1.  Save the script code to a file named `vicomp.sh`.
2.  Make the script executable:
    ```bash
    chmod +x vicomp.sh
    ```
3.  Run it:
    ```bash
    ./vicomp.sh --help
    ```