#!/bin/bash

# ==============================================================================
# Title: ViCo - Recursive Video Compressor
# Description: Recursively finds video files, validates them, compresses them
#              using ffmpeg. Auto-detects hardware acceleration.
#              Includes Interactive Menu and HTML Reporting.
#              (Safe for filenames with spaces and special characters)
#
# Usage: ./vicomp.sh [flags] [directory]
#
# Arguments:
#   -h, --help       Show help message.
#   --menu           Launch interactive configuration menu.
#   -k, --keep       Keep original files (don't overwrite).
#   -s, --subs       Download subtitles.
#   -r, --res VAL    Resolution (720, 1080, 2160).
#   --no-hw          Disable hardware acceleration.
#   --downmix        Downmix audio to Stereo.
#   --html           Generate HTML report of results.
# ==============================================================================

# --- Context Check ---
# Robustly handle execution from unstable/deleted directories.
# If `pwd` fails, we must cd to a valid location to prevent "shell-init" errors
# in subsequent subshells.
if ! pwd >/dev/null 2>&1; then
    if [[ -n "$PWD" && -d "$PWD" ]]; then
        # Try to re-enter the path the shell thinks we are in
        cd "$PWD" 2>/dev/null || cd "$HOME"
    else
        # Fallback to HOME
        echo "Warning: Current directory inaccessible. Switching context to HOME." >&2
        cd "$HOME"
    fi
fi
CWD_OUTPUT=$(pwd)

# Set default target
TARGET_DIR="$CWD_OUTPUT"

# --- Defaults ---
DEFAULT_CRF=23
DEFAULT_PRESET="medium"
TARGET_RES=1080

# Audio
AUDIO_CODEC="aac"
AUDIO_BITRATE="128k"
AUDIO_BITRATE_SURROUND="384k"

# Files
SUFFIX="_optimized"
REPORT_FILENAME="vico_report.html"
# Anchor report to the detected CWD
REPORT_FILE="$TARGET_DIR/$REPORT_FILENAME"

# Toggles
OVERWRITE=true
DOWNLOAD_SUBS=false
DISABLE_HW=false
DOWNMIX_AUDIO=false
RECODE_AUDIO=false
GENERATE_HTML=false

CODEC="264"
CRF_VALUE="$DEFAULT_CRF"

# Data for Report
declare -a REPORT_DATA

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

usage() {
    echo "Usage: $0 [flags] [directory]"
    echo ""
    echo "Flags:"
    echo "  -h, --help       Show this help message and exit."
    echo "  --menu           Launch interactive configuration menu."
    echo "  -k, --keep       Do NOT overwrite original files."
    echo "  -s, --subs       Download subtitles (matches system language)."
    echo "  -r, --res VAL    Set resolution: 720, 1080 (default), or 2160."
    echo "  --no-hw          Force software encoding."
    echo "  --downmix        Re-encode audio and downmix to Stereo."
    echo "  --html           Generate HTML report."
    echo ""
    echo "Positional Arguments:"
    echo "  directory        Target directory (default: current: $TARGET_DIR)"
    echo ""
}

detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    else
        echo "unknown"
    fi
}

check_dependencies() {
    for tool in ffmpeg ffprobe; do
        if ! command -v "$tool" &> /dev/null; then
            echo "Missing required tool: $tool"
            read -p "Attempt to auto-install? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                install_ffmpeg
            else
                exit 1
            fi
        fi
    done
}

install_ffmpeg() {
    DISTRO=$(detect_distro)
    case "$DISTRO" in
        ubuntu|debian|pop|kali|raspbian) CMD="sudo apt-get update && sudo apt-get install -y ffmpeg" ;;
        fedora|centos|rhel|almalinux)    CMD="sudo dnf install -y ffmpeg" ;;
        arch|manjaro|endeavouros)        CMD="sudo pacman -S --noconfirm ffmpeg" ;;
        *) echo "Manual install required for $DISTRO"; exit 1 ;;
    esac
    eval "$CMD"
}

get_file_size() {
    stat -c%s "$1" 2>/dev/null || echo 0
}

format_size() {
    numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1"
}

# Clean quotes from path string if user pasted them
clean_path_string() {
    local p="$1"
    p="${p%\"}"
    p="${p#\"}"
    p="${p%\'}"
    p="${p#\'}"
    echo "$p"
}

# Resolve absolute path
resolve_path() {
    local path="$1"
    
    # Trim whitespace
    path="${path#"${path%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"

    path=$(clean_path_string "$path")

    # Default to known valid CWD if empty or dot
    if [ -z "$path" ] || [ "$path" = "." ]; then
        echo "$CWD_OUTPUT"
        return
    fi

    # 1. Expand tilde
    if [[ "$path" == "~"* ]]; then
        path="${path/#\~/$HOME}"
    fi
    
    # 2. Resolve absolute path
    if command -v realpath &> /dev/null; then
        RESOLVED=$(realpath -q "$path")
        if [ -n "$RESOLVED" ]; then
            echo "$RESOLVED"
        else
            echo "$path" # Return input if realpath fails (e.g. new dir)
        fi
    else
        # Fallback logic
        if [ -d "$path" ]; then
            # Use cd in subshell to resolve, rely on $PWD if pwd fails
            (cd "$path" >/dev/null 2>&1 && echo "$PWD") || echo "$path"
        else
            echo "$path"
        fi
    fi
}

generate_html_report() {
    echo "Generating HTML Report: $REPORT_FILE"
    cat <<EOF > "$REPORT_FILE"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>ViCo Compression Report</title>
<style>
    body { font-family: sans-serif; padding: 20px; background: #f4f4f9; }
    table { border-collapse: collapse; width: 100%; background: white; box-shadow: 0 1px 3px rgba(0,0,0,0.2); }
    th, td { padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }
    th { background-color: #4CAF50; color: white; }
    tr:hover { background-color: #f5f5f5; }
    .success { color: green; font-weight: bold; }
    .error { color: red; }
    .stats { font-family: monospace; color: #555; }
</style>
</head>
<body>
    <h1>Compression Report</h1>
    <p>Generated on $(date)</p>
    <table>
        <tr>
            <th>File</th>
            <th>Original Size</th>
            <th>New Size</th>
            <th>Reduction</th>
            <th>Avg FPS</th>
            <th>Status</th>
        </tr>
EOF

    for row in "${REPORT_DATA[@]}"; do
        echo "$row" >> "$REPORT_FILE"
    done

    cat <<EOF >> "$REPORT_FILE"
    </table>
</body>
</html>
EOF
    echo "Report saved to $REPORT_FILE"
}

detect_hardware() {
    if [ "$DISABLE_HW" = true ]; then
        HW_TYPE="cpu"
        return
    fi

    ENCODERS=$(ffmpeg -hide_banner -encoders 2>/dev/null)

    # NVIDIA
    if echo "$ENCODERS" | grep -q "nvenc"; then
        if ls /dev/nvidia* 1> /dev/null 2>&1; then
            HW_TYPE="nvenc"
            return
        fi
    fi

    find_render_device() {
        local vendor="$1"
        for dev in /sys/class/drm/renderD*; do
            if [ -e "$dev/device/vendor" ] && grep -q "$vendor" "$dev/device/vendor"; then
                 echo "/dev/dri/$(basename "$dev")"
                 return 0
            fi
        done
        return 1
    }

    # Intel QSV (0x8086)
    if echo "$ENCODERS" | grep -q "qsv"; then
        INTEL_DEV=$(find_render_device "0x8086")
        if [ -n "$INTEL_DEV" ]; then
            HW_TYPE="qsv"
            HW_DEVICE="$INTEL_DEV"
            return
        fi
    fi

    # VAAPI (AMD/Intel Fallback)
    if echo "$ENCODERS" | grep -q "vaapi"; then
        if ls /dev/dri/renderD* 1> /dev/null 2>&1; then
            # Safe way to get first device
            HW_DEVICE=$(ls /dev/dri/renderD* | head -n 1)
            HW_TYPE="vaapi"
            return
        fi
    fi

    HW_TYPE="cpu"
}

# ------------------------------------------------------------------------------
# Menu System
# ------------------------------------------------------------------------------

show_menu() {
    while true; do
        clear
        DISPLAY_DIR=$(resolve_path "$TARGET_DIR")
        
        if [ -z "$DISPLAY_DIR" ]; then
            DISPLAY_DIR="$TARGET_DIR (Invalid/Not Found)"
            DIR_VALID=false
        else
            DIR_VALID=true
        fi

        echo "=========================================="
        echo "   ViCo - Video Compressor Configurator   "
        echo "=========================================="
        echo "1.  Target Directory    [$DISPLAY_DIR]"
        echo "2.  Resolution          [${TARGET_RES}p]"
        echo "3.  Codec               [H.$CODEC]"
        echo "4.  CRF (Quality)       [$CRF_VALUE]"
        echo "------------------------------------------"
        echo "5.  Audio Mode          [$( [ "$RECODE_AUDIO" = true ] && ([ "$DOWNMIX_AUDIO" = true ] && echo "Downmix Stereo" || echo "Re-encode Multi") || echo "Copy Intact" )]"
        echo "6.  Hardware Accel      [$( [ "$DISABLE_HW" = true ] && echo "Disabled (CPU)" || echo "Auto-Detect" )]"
        echo "7.  Subtitles           [$( [ "$DOWNLOAD_SUBS" = true ] && echo "Download" || echo "Skip" )]"
        echo "8.  Overwrite Files     [$( [ "$OVERWRITE" = true ] && echo "Yes" || echo "No (Keep Original)" )]"
        echo "9.  HTML Report         [$( [ "$GENERATE_HTML" = true ] && echo "Yes" || echo "No" )]"
        echo "------------------------------------------"
        echo "P.  Proceed / Start"
        echo "Q.  Quit"
        echo "=========================================="
        read -p "Select Option: " OPT

        case $OPT in
            1) 
               read -p "Enter Path: " -e NEW_PATH 
               NEW_PATH=$(clean_path_string "$NEW_PATH")
               if [ -n "$NEW_PATH" ]; then TARGET_DIR="$NEW_PATH"; fi
               ;;
            2) 
                echo "Select Resolution: 1) 720p  2) 1080p  3) 2160p"
                read -r r_opt
                case $r_opt in
                    1) TARGET_RES=720 ;;
                    2) TARGET_RES=1080 ;;
                    3) TARGET_RES=2160 ;;
                esac
                ;;
            3)
                echo "Select Codec: 1) H.264  2) H.265 (HEVC)"
                read -r c_opt
                [[ "$c_opt" == "2" ]] && CODEC="265" || CODEC="264"
                ;;
            4) read -p "Enter CRF (18-28, lower is better): " CRF_VALUE ;;
            5)
                echo "Audio Mode: 1) Copy Intact (Default)  2) Re-encode (Keep Channels)  3) Downmix to Stereo"
                read -r a_opt
                case $a_opt in
                    1) RECODE_AUDIO=false; DOWNMIX_AUDIO=false ;;
                    2) RECODE_AUDIO=true; DOWNMIX_AUDIO=false ;;
                    3) RECODE_AUDIO=true; DOWNMIX_AUDIO=true ;;
                esac
                ;;
            6) 
                if [ "$DISABLE_HW" = true ]; then DISABLE_HW=false; else DISABLE_HW=true; fi
                ;;
            7) 
                if [ "$DOWNLOAD_SUBS" = true ]; then DOWNLOAD_SUBS=false; else DOWNLOAD_SUBS=true; fi
                ;;
            8) 
                if [ "$OVERWRITE" = true ]; then OVERWRITE=false; else OVERWRITE=true; fi
                ;;
            9)
                if [ "$GENERATE_HTML" = true ]; then GENERATE_HTML=false; else GENERATE_HTML=true; fi
                ;;
            [Pp]) 
                if [ "$DIR_VALID" = true ]; then
                    break
                else
                    echo "Error: Invalid directory. Please select a valid path."
                    sleep 2
                fi
                ;;
            [Qq]) exit 0 ;;
            *) echo "Invalid option." ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Processing Logic
# ------------------------------------------------------------------------------

process_videos() {
    ABS_TARGET_DIR=$(resolve_path "$TARGET_DIR")
    
    detect_hardware
    
    echo ""
    echo "--- Job Configuration ---"
    echo "Directory: '$ABS_TARGET_DIR'"
    echo "Target:    ${TARGET_RES}p / H.${CODEC} / CRF $CRF_VALUE"
    echo "Hardware:  $HW_TYPE"
    echo "Audio:     $( [ "$RECODE_AUDIO" = true ] && echo "Re-encode" || echo "Copy" ) $( [ "$DOWNMIX_AUDIO" = true ] && echo "+ Downmix" )"
    echo "Report:    $GENERATE_HTML"
    echo "-------------------------"
    sleep 1

    if [ -z "$ABS_TARGET_DIR" ] || [ ! -d "$ABS_TARGET_DIR" ]; then
        echo "Error: Directory not found or not accessible: '$TARGET_DIR'"
        exit 1
    fi
    
    # Global flags for all ffmpeg commands to prevent stalling and excessive logging
    # -nostdin: Critical for running inside loops/scripts to prevent reading from stdin
    FF_FLAGS="-nostdin -n -v error -stats"

    # Use process substitution to avoid subshell variable scope issues
    while IFS= read -r -d '' file; do
        
        if [[ "$file" == *"$SUFFIX.mp4" ]]; then continue; fi
        if [[ "$file" == *".temp_optim.mp4" ]]; then continue; fi

        echo "Processing: $file"
        START_SIZE=$(get_file_size "$file")

        # Validate
        if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type "$file" 2>/dev/null | grep -q "codec_type=video"; then
            echo "  > Invalid video file. Skipping."
            continue
        fi

        # Subtitles
        if [ "$DOWNLOAD_SUBS" = true ]; then
            HAS_SUBS=$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$file")
            if [ -n "$HAS_SUBS" ]; then
                echo "  > Subtitles present. Skipping download."
            else
                SYS_LANG="${LANG%%_*}"; [ -z "$SYS_LANG" ] && SYS_LANG="en"
                timeout 30s subliminal download -l "$SYS_LANG" "$file"
            fi
        fi

        # Audio Logic
        declare -a A_FLAGS
        if [ "$RECODE_AUDIO" = true ]; then
            CHANNELS=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$file" | head -n 1)
            if [[ -z "$CHANNELS" || "$CHANNELS" == "N/A" ]]; then
                A_FLAGS=(-an)
            elif [ "$DOWNMIX_AUDIO" = true ] && [ "$CHANNELS" -gt 2 ]; then
                echo "  > Downmixing $CHANNELS channels to Stereo."
                A_FLAGS=(-c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE" -ac 2)
            else
                echo "  > Keeping audio channels."
                A_FLAGS=(-c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE")
                if [ "$CHANNELS" -gt 2 ]; then
                     A_FLAGS=(-c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE_SURROUND" -ac "$CHANNELS")
                fi
            fi
        else
            echo "  > Copying audio stream."
            A_FLAGS=(-c:a copy)
        fi

        # Video Logic
        SCALE_FILTER="scale=-2:$TARGET_RES"
        declare -a V_FLAGS
        declare -a HW_FLAGS
        
        TEMP_FILE="${file%.*}.temp_optim.mp4"

        if [ "$HW_TYPE" == "nvenc" ]; then
            if [[ "$CODEC" == "265" ]]; then ENC="hevc_nvenc"; else ENC="h264_nvenc"; fi
            V_FLAGS=(-c:v "$ENC" -preset p4 -cq "$CRF_VALUE" -vf "$SCALE_FILTER")
            
        elif [ "$HW_TYPE" == "qsv" ]; then
            if [[ "$CODEC" == "265" ]]; then ENC="hevc_qsv"; else ENC="h264_qsv"; fi
            export LIBVA_DRIVER_NAME=iHD
            HW_FLAGS=(-init_hw_device "vaapi=va:$HW_DEVICE" -init_hw_device "qsv=hw@va" -filter_hw_device hw)
            V_FLAGS=(-vf "${SCALE_FILTER},format=nv12,hwupload=extra_hw_frames=64,format=qsv" -c:v "$ENC" -global_quality "$CRF_VALUE" -preset medium)
            
        elif [ "$HW_TYPE" == "vaapi" ]; then
            if [[ "$CODEC" == "265" ]]; then ENC="hevc_vaapi"; else ENC="h264_vaapi"; fi
            HW_FLAGS=(-vaapi_device "$HW_DEVICE")
            V_FLAGS=(-vf "${SCALE_FILTER},format=nv12,hwupload" -c:v "$ENC" -qp "$CRF_VALUE")
            
        else
            if [[ "$CODEC" == "265" ]]; then ENC="libx265"; else ENC="libx264"; fi
            V_FLAGS=(-c:v "$ENC" -crf "$CRF_VALUE" -preset "$DEFAULT_PRESET" -vf "$SCALE_FILTER")
        fi

        FFLOG=$(mktemp)
        
        CMD_ARRAY=(ffmpeg "${BASE_FF_ARGS[@]}" "${HW_FLAGS[@]}" -i "$file" "${V_FLAGS[@]}" "${A_FLAGS[@]}" -movflags +faststart "$TEMP_FILE")
        
        "${CMD_ARRAY[@]}" 2>&1 | tee "$FFLOG"
        RET=${PIPESTATUS[0]}
        
        AVG_FPS=$(grep -oE "fps=[[:space:]]*[0-9.]+" "$FFLOG" | tail -1 | sed 's/fps=//' | tr -d ' ')
        [ -z "$AVG_FPS" ] && AVG_FPS="N/A"
        rm "$FFLOG"

        if [ $RET -eq 0 ] && [ -s "$TEMP_FILE" ]; then
            END_SIZE=$(get_file_size "$TEMP_FILE")
            
            if [ "$START_SIZE" -gt 0 ]; then
                DIFF=$((START_SIZE - END_SIZE))
                PCT=$(awk "BEGIN {printf \"%.2f\", ($DIFF / $START_SIZE) * 100}")
            else
                PCT="0"
            fi

            FINAL_NAME="${file%.*}.mp4"
            [ "$OVERWRITE" = false ] && FINAL_NAME="${file%.*}${SUFFIX}.mp4"
            
            mv "$TEMP_FILE" "$FINAL_NAME"
            [ "$OVERWRITE" = true ] && [ "$file" != "$FINAL_NAME" ] && rm "$file"

            echo "  > Done. Reduced by $PCT%. Avg FPS: $AVG_FPS"
            
            if [ "$GENERATE_HTML" = true ]; then
                ROW="<tr><td>$(basename "$file")</td><td>$(format_size $START_SIZE)</td><td>$(format_size $END_SIZE)</td><td class='success'>-$PCT%</td><td class='stats'>$AVG_FPS</td><td>Success</td></tr>"
                REPORT_DATA+=("$ROW")
            fi
        else
            echo "  > Failed."
            [ -f "$TEMP_FILE" ] && rm "$TEMP_FILE"
            if [ "$GENERATE_HTML" = true ]; then
                ROW="<tr><td>$(basename "$file")</td><td>$(format_size $START_SIZE)</td><td>-</td><td>-</td><td class='stats'>-</td><td class='error'>Failed</td></tr>"
                REPORT_DATA+=("$ROW")
            fi
        fi

    done < <(find "$ABS_TARGET_DIR" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.avi" \) -print0)

    if [ "$GENERATE_HTML" = true ]; then
        generate_html_report
    fi
}

# ------------------------------------------------------------------------------
# Parse Args or Launch Menu
# ------------------------------------------------------------------------------

if [ $# -eq 0 ]; then
    show_menu
    check_dependencies
    process_videos
else
    while [[ $# -gt 0 ]]; do
      case $1 in
        -h|--help) usage; exit 0 ;;
        --menu) show_menu; check_dependencies; process_videos; exit 0 ;;
        -k|--keep) OVERWRITE=false; shift ;;
        -s|--subs) DOWNLOAD_SUBS=true; shift ;;
        -r|--res) TARGET_RES="$2"; shift 2 ;;
        --no-hw) DISABLE_HW=true; shift ;;
        --downmix) RECODE_AUDIO=true; DOWNMIX_AUDIO=true; shift ;;
        --html) GENERATE_HTML=true; shift ;;
        *) 
           # Attempt to reconstruct paths with spaces from split arguments
           if [ -n "$TARGET_DIR" ] && [ "$TARGET_DIR" != "." ] && [ "$TARGET_DIR" != "$CWD_OUTPUT" ]; then
               # If we already have a path, append this chunk with a space
               TARGET_DIR="$TARGET_DIR $1"
           else
               # First chunk
               TARGET_DIR="$1"
               
               # Heuristics: if it looks like a codec or number, treat as such immediately
               if [[ "$1" =~ ^[0-9]+$ ]] && [ -z "$ARG_CRF_SET" ] && [ ! -d "$1" ]; then 
                    CODEC="265"; CRF_VALUE="$1"; ARG_CRF_SET=1
                    TARGET_DIR="." # Reset if it was just a number
               elif [[ "$1" == "264" || "$1" == "265" ]]; then 
                    CODEC="$1"
                    TARGET_DIR="." # Reset
               fi
           fi
           shift 
           ;;
      esac
    done
    
    TARGET_DIR=$(clean_path_string "$TARGET_DIR")
    check_dependencies
    process_videos
fi