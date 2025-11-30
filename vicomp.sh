#!/bin/bash

# ==============================================================================
# Title: ViCo - Recursive Video Compressor
# Description: Recursively finds video files, validates them, compresses them
#              using ffmpeg, converts to MP4. Optionally downloads subtitles.
#              Auto-detects hardware acceleration (NVENC, VAAPI, QSV).
#
# Usage: ./vicomp.sh [flags] [directory] [codec] [crf]
#
# Arguments:
#   -h, --help       Show help message and exit.
#   -k, --keep       Do NOT overwrite original files. Appends "_optimized".
#   -s, --subs       Download subtitles (English) using 'subliminal'.
#   -r, --res VAL    Set resolution: 720, 1080 (default), or 2160.
#   --no-hw          Force software encoding (disable hardware acceleration).
#
#   directory        Target directory (default: current)
#   codec            264 (default) or 265
#   crf              Quality (default: 23)
#
# Example (Overwrite): ./vicomp.sh /videos 265 26
# Example (With Subs): ./vicomp.sh -s /videos 265 26
# Example (720p, No HW): ./vicomp.sh -r 720 --no-hw /videos
# ==============================================================================

# --- Defaults ---
DEFAULT_CRF=23
DEFAULT_PRESET="medium" # Changed from slow to medium for better HW compat
DEFAULT_CODEC="264"
TARGET_RES=1080

# Audio Settings
AUDIO_CODEC="aac"
AUDIO_BITRATE="128k"

# Suffix for kept files
SUFFIX="_optimized"

# Default Behavior
OVERWRITE=true
DOWNLOAD_SUBS=false
DISABLE_HW=false

# ------------------------------------------------------------------------------

# Helper function for help message
usage() {
    echo "Usage: $0 [flags] [directory] [codec] [crf]"
    echo ""
    echo "Flags:"
    echo "  -h, --help       Show this help message and exit."
    echo "  -k, --keep       Do NOT overwrite original files. Appends \"${SUFFIX}\"."
    echo "  -s, --subs       Download subtitles (English) using 'subliminal'."
    echo "  -r, --res VAL    Resolution (720, 1080, 2160). Default: 1080."
    echo "  --no-hw          Disable hardware acceleration."
    echo ""
    echo "Positional Arguments:"
    echo "  directory        Target directory (default: current)"
    echo "  codec            264 (default) or 265"
    echo "  crf              Quality (default: 23)"
    echo ""
    echo "Examples:"
    echo "  $0 -r 720 /videos 265 28"
    echo "  $0 --no-hw -k /videos"
}

# 1. Parse Arguments (Flag extraction)
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      usage
      exit 0
      ;;
    -k|--keep)
      OVERWRITE=false
      shift # past argument
      ;;
    -s|--subs)
      DOWNLOAD_SUBS=true
      shift # past argument
      ;;
    -r|--res)
      TARGET_RES="$2"
      shift 2 # past argument and value
      ;;
    --no-hw)
      DISABLE_HW=true
      shift # past argument
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

# Validate Resolution
if [[ ! "$TARGET_RES" =~ ^(720|1080|2160)$ ]]; then
    echo "Invalid resolution '$TARGET_RES'. Defaulting to 1080."
    TARGET_RES=1080
fi

# ------------------------------------------------------------------------------
# 2. Dependency Management & Auto-Installation
# ------------------------------------------------------------------------------

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

install_ffmpeg() {
    DISTRO=$(detect_distro)
    echo "Detected distribution: $DISTRO"
    CMD=""

    case "$DISTRO" in
        ubuntu|debian|linuxmint|pop|kali|raspbian)
            CMD="sudo apt-get update && sudo apt-get install -y ffmpeg"
            ;;
        fedora|centos|rhel|almalinux|rocky)
            CMD="sudo dnf install -y ffmpeg"
            ;;
        arch|manjaro|endeavouros)
            CMD="sudo pacman -S --noconfirm ffmpeg"
            ;;
        opensuse*|suse)
            CMD="sudo zypper install -y ffmpeg"
            ;;
        alpine)
            CMD="sudo apk add ffmpeg"
            ;;
        *)
            echo "Unsupported distribution for auto-install ($DISTRO). Please install 'ffmpeg' manually."
            exit 1
            ;;
    esac

    echo "Proposed install command: $CMD"
    read -p "Do you want to run this command to install ffmpeg? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        eval "$CMD"
        if ! command -v ffmpeg &> /dev/null; then
             echo "Installation failed. Please check your package manager."
             exit 1
        fi
    else
        echo "ffmpeg is required to run this script. Exiting."
        exit 1
    fi
}

install_subliminal() {
    DISTRO=$(detect_distro)
    echo "Detected distribution: $DISTRO"
    echo "Checking for 'subliminal' package in system repositories..."
    CMD=""

    case "$DISTRO" in
        ubuntu|debian|linuxmint|pop|kali|raspbian)
            CMD="sudo apt-get update && sudo apt-get install -y subliminal"
            ;;
        fedora|centos|rhel|almalinux|rocky)
            CMD="sudo dnf install -y subliminal"
            ;;
        arch|manjaro|endeavouros)
            CMD="sudo pacman -S --noconfirm subliminal"
            ;;
        opensuse*|suse)
            CMD="sudo zypper install -y subliminal"
            ;;
        alpine)
            CMD="sudo apk add subliminal"
            ;;
        *)
            echo "Unsupported distribution for auto-install ($DISTRO). Please install 'subliminal' manually via your package manager."
            exit 1
            ;;
    esac

    echo "Proposed install command: $CMD"
    read -p "Do you want to run this command to install subliminal? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        eval "$CMD"
        if ! command -v subliminal &> /dev/null; then
             echo "Installation failed. The package 'subliminal' might not be in your default repositories."
             echo "Please check your package manager settings or install manually."
             exit 1
        fi
    else
        echo "Subtitle download requested but subliminal missing. Exiting."
        exit 1
    fi
}

# Check ffmpeg
if ! command -v ffmpeg &> /dev/null; then
    echo "Required tool 'ffmpeg' is not installed."
    install_ffmpeg
fi

# Check ffprobe (usually comes with ffmpeg)
if ! command -v ffprobe &> /dev/null; then
    echo "Required tool 'ffprobe' is missing."
    install_ffmpeg
fi

# Check subliminal (only if requested)
if [ "$DOWNLOAD_SUBS" = true ]; then
    if ! command -v subliminal &> /dev/null; then
        install_subliminal
    fi
fi

# ------------------------------------------------------------------------------
# 3. Hardware Detection
# ------------------------------------------------------------------------------

HW_TYPE="cpu"
HW_DEVICE=""

detect_hardware() {
    if [ "$DISABLE_HW" = true ]; then
        echo "Hardware encoding disabled by user flag."
        return
    fi

    echo "Querying system for hardware encoders..."
    ENCODERS=$(ffmpeg -hide_banner -encoders 2>/dev/null)

    # 1. Check for NVIDIA NVENC
    if echo "$ENCODERS" | grep -q "nvenc"; then
        # Verify device presence (rudimentary check)
        if ls /dev/nvidia* 1> /dev/null 2>&1 || command -v nvidia-smi &> /dev/null; then
            echo "Found: NVIDIA NVENC"
            HW_TYPE="nvenc"
            return
        fi
    fi

    # 2. Check for Intel QSV (Quick Sync Video) - Check BEFORE VAAPI for Intel preference
    if echo "$ENCODERS" | grep -q "qsv"; then
        if ls /dev/dri/renderD128 1> /dev/null 2>&1; then
            echo "Found: Intel QSV"
            HW_TYPE="qsv"
            HW_DEVICE="/dev/dri/renderD128"
            return
        fi
    fi
    
    # 3. Check for VAAPI (Intel / AMD)
    if echo "$ENCODERS" | grep -q "vaapi"; then
        # Common render device path
        if ls /dev/dri/renderD128 1> /dev/null 2>&1; then
            echo "Found: VAAPI (Intel/AMD)"
            HW_TYPE="vaapi"
            HW_DEVICE="/dev/dri/renderD128"
            return
        fi
    fi

    echo "No supported hardware encoder detected (or drivers missing). Falling back to CPU."
}

detect_hardware

# ------------------------------------------------------------------------------
# 4. Main Script Logic
# ------------------------------------------------------------------------------

# Assign Positional Arguments
TARGET_DIR="${1:-.}"
ARG_CODEC="${2:-264}"
ARG_CRF="${3:-$DEFAULT_CRF}"

# Validate Directory
if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Directory '$TARGET_DIR' does not exist."
    exit 1
fi

# Validate CRF
if [[ "$ARG_CRF" =~ ^[0-9]+$ ]]; then
    CRF_VALUE="$ARG_CRF"
else
    echo "Warning: Invalid CRF '$ARG_CRF'. Using default $DEFAULT_CRF."
    CRF_VALUE="$DEFAULT_CRF"
fi

PRESET="$DEFAULT_PRESET"

echo "Scanning '$TARGET_DIR' for video files..."
echo "Settings: Target Res=${TARGET_RES}p, CRF/Quality=$CRF_VALUE"
if [ "$OVERWRITE" = true ]; then
    echo "Mode: OVERWRITE"
else
    echo "Mode: KEEP"
fi
echo "Hardware Acceleration: $HW_TYPE"
echo "--------------------------------------------------------"

# Find and Process Files
find "$TARGET_DIR" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.avi" \) -print0 | while IFS= read -r -d '' file; do

    # Skip processed files
    if [[ "$file" == *"$SUFFIX.mp4" ]]; then continue; fi
    if [[ "$file" == *".temp_optim.mp4" ]]; then continue; fi

    echo "Checking: $file"

    # Validate Video Stream
    if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type "$file" 2>/dev/null | grep -q "codec_type=video"; then
        echo "Skipping: Not a valid video file."
        echo "--------------------------------------------------------"
        continue
    fi

    # --- Subtitle Download Step ---
    if [ "$DOWNLOAD_SUBS" = true ]; then
        echo "Downloading subtitles..."
        subliminal download -l en "$file" || echo "Subtitle download warning (skipping)"
    fi

    # Prepare Paths
    filename_no_ext="${file%.*}"
    temp_file="${filename_no_ext}.temp_optim.mp4"
    if [ "$OVERWRITE" = true ]; then
        final_file="${filename_no_ext}.mp4"
    else
        final_file="${filename_no_ext}${SUFFIX}.mp4"
    fi

    if [ "$OVERWRITE" = false ] && [ -f "$final_file" ]; then
        echo "Skipping: Optimized file already exists ($final_file)"
        continue
    fi

    echo "Processing video using $HW_TYPE..."

    # --- Construct FFmpeg Command based on HW_TYPE ---
    
    # Common Scale Filter: Scale to Target Res, maintain aspect ratio, ensure dimensions are divisible by 2
    SCALE_FILTER="scale=-2:$TARGET_RES"

    # Common Audio Flags
    AUDIO_FLAGS="-c:a $AUDIO_CODEC -b:a $AUDIO_BITRATE"

    if [ "$HW_TYPE" == "nvenc" ]; then
        # NVIDIA NVENC Settings
        if [[ "$ARG_CODEC" == *"265"* || "$ARG_CODEC" == *"hevc"* ]]; then
            V_CODEC="hevc_nvenc"
        else
            V_CODEC="h264_nvenc"
        fi
        
        # NVENC uses -cq for VBR quality, similar to CRF
        # Software scaling (CPU) -> HW encoding is usually most compatible
        CMD="ffmpeg -n -v error -stats -i \"$file\" \
             -c:v $V_CODEC -preset p4 -cq $CRF_VALUE \
             -vf \"$SCALE_FILTER\" \
             $AUDIO_FLAGS -movflags +faststart \"$temp_file\""

    elif [ "$HW_TYPE" == "qsv" ]; then
        # Intel QSV Settings
        if [[ "$ARG_CODEC" == *"265"* || "$ARG_CODEC" == *"hevc"* ]]; then
            V_CODEC="hevc_qsv"
        else
            V_CODEC="h264_qsv"
        fi
        
        # QSV often uses -global_quality or -q:v
        CMD="ffmpeg -n -v error -stats \
             -init_hw_device qsv=hw -filter_hw_device hw -i \"$file\" \
             -vf \"$SCALE_FILTER,format=nv12,hwupload=extra_hw_frames=64,format=qsv\" \
             -c:v $V_CODEC -global_quality $CRF_VALUE -preset medium \
             $AUDIO_FLAGS -movflags +faststart \"$temp_file\""

    elif [ "$HW_TYPE" == "vaapi" ]; then
        # VAAPI Settings (Intel/AMD)
        if [[ "$ARG_CODEC" == *"265"* || "$ARG_CODEC" == *"hevc"* ]]; then
            V_CODEC="hevc_vaapi"
        else
            V_CODEC="h264_vaapi"
        fi
        
        # VAAPI requires scaling AND format conversion to nv12 AND uploading to GPU
        # Complex filter chain: scale(sw) -> format -> hwupload
        # Mapping CRF to -qp (Constant Quantization) roughly equivalent for script usage
        CMD="ffmpeg -n -v error -stats \
             -vaapi_device $HW_DEVICE -i \"$file\" \
             -vf \"$SCALE_FILTER,format=nv12,hwupload\" \
             -c:v $V_CODEC -qp $CRF_VALUE \
             $AUDIO_FLAGS -movflags +faststart \"$temp_file\""
             
    else
        # CPU / Software Fallback
        if [[ "$ARG_CODEC" == *"265"* || "$ARG_CODEC" == *"hevc"* ]]; then
            V_CODEC="libx265"
        else
            V_CODEC="libx264"
        fi

        CMD="ffmpeg -n -v error -stats -i \"$file\" \
             -c:v $V_CODEC -crf $CRF_VALUE -preset $PRESET \
             -vf \"$SCALE_FILTER\" \
             $AUDIO_FLAGS -movflags +faststart \"$temp_file\""
    fi

    # Execute Command
    eval "$CMD" < /dev/null

    # Verify and Finalize
    if [ $? -eq 0 ] && [ -s "$temp_file" ]; then
        orig_size=$(du -h "$file" | cut -f1)
        new_size=$(du -h "$temp_file" | cut -f1)
        
        mv "$temp_file" "$final_file"
        
        if [ "$OVERWRITE" = true ] && [ "$file" != "$final_file" ]; then
            rm "$file"
        fi
        
        echo "Success! $orig_size -> $new_size"
    else
        echo "Error processing file. Cleaning up."
        [ -f "$temp_file" ] && rm "$temp_file"
    fi

    echo "--------------------------------------------------------"

done

echo "Compression Job Complete."