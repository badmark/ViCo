#!/bin/bash

# ==============================================================================
# Title: ViCo - Recursive Video Compressor
# Description: Recursively finds video files, validates them, compresses them
#              using ffmpeg. Auto-detects hardware acceleration.
#              Includes Interactive Menu and HTML Reporting.
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
REPORT_FILE="vico_report.html"

# Toggles
OVERWRITE=true
DOWNLOAD_SUBS=false
DISABLE_HW=false
DOWNMIX_AUDIO=false
RECODE_AUDIO=false
GENERATE_HTML=false
TARGET_DIR="."
CODEC="264"
CRF_VALUE="$DEFAULT_CRF"

# Data for Report
declare -a REPORT_DATA

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------

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
        if ! command -v $tool &> /dev/null; then
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
    echo "Report saved to $(pwd)/$REPORT_FILE"
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
            [ -e "$dev/device/vendor" ] && grep -q "$vendor" "$dev/device/vendor" && echo "/dev/dri/$(basename "$dev")" && return 0
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
        echo "=========================================="
        echo "   ViCo - Video Compressor Configurator   "
        echo "=========================================="
        echo "1.  Target Directory    [$TARGET_DIR]"
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
            1) read -p "Enter Path: " -e TARGET_DIR ;;
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
            [Pp]) break ;;
            [Qq]) exit 0 ;;
            *) echo "Invalid option." ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Processing Logic
# ------------------------------------------------------------------------------

process_videos() {
    detect_hardware
    
    echo ""
    echo "--- Job Configuration ---"
    echo "Directory: $TARGET_DIR"
    echo "Target:    ${TARGET_RES}p / H.${CODEC} / CRF $CRF_VALUE"
    echo "Hardware:  $HW_TYPE"
    echo "Audio:     $( [ "$RECODE_AUDIO" = true ] && echo "Re-encode" || echo "Copy" ) $( [ "$DOWNMIX_AUDIO" = true ] && echo "+ Downmix" )"
    echo "Report:    $GENERATE_HTML"
    echo "-------------------------"
    sleep 2

    if [ ! -d "$TARGET_DIR" ]; then
        echo "Error: Directory not found."
        exit 1
    fi

    find "$TARGET_DIR" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.avi" \) -print0 | while IFS= read -r -d '' file; do
        
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
        if [ "$RECODE_AUDIO" = true ]; then
            CHANNELS=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$file" | head -n 1)
            if [[ -z "$CHANNELS" || "$CHANNELS" == "N/A" ]]; then
                A_FLAGS="-an"
            elif [ "$DOWNMIX_AUDIO" = true ] && [ "$CHANNELS" -gt 2 ]; then
                echo "  > Downmixing $CHANNELS channels to Stereo."
                A_FLAGS="-c:a $AUDIO_CODEC -b:a $AUDIO_BITRATE -ac 2"
            else
                A_FLAGS="-c:a $AUDIO_CODEC -b:a $AUDIO_BITRATE"
                [ "$CHANNELS" -gt 2 ] && A_FLAGS="-c:a $AUDIO_CODEC -b:a $AUDIO_BITRATE_SURROUND -ac $CHANNELS"
            fi
        else
            A_FLAGS="-c:a copy"
        fi

        # Hardware Encoder Selection
        SCALE_FILTER="scale=-2:$TARGET_RES"
        
        if [ "$HW_TYPE" == "nvenc" ]; then
            V_CODEC="h${CODEC}_nvenc"; [ "$CODEC" == "265" ] && V_CODEC="hevc_nvenc"
            CMD="ffmpeg -n -v error -stats -i \"$file\" -c:v $V_CODEC -preset p4 -cq $CRF_VALUE -vf \"$SCALE_FILTER\" $A_FLAGS -movflags +faststart \"${file%.*}.temp_optim.mp4\""
        elif [ "$HW_TYPE" == "qsv" ]; then
            V_CODEC="h${CODEC}_qsv"; [ "$CODEC" == "265" ] && V_CODEC="hevc_qsv"
            CMD="LIBVA_DRIVER_NAME=iHD ffmpeg -n -v error -stats -init_hw_device vaapi=va:$HW_DEVICE -init_hw_device qsv=hw@va -filter_hw_device hw -i \"$file\" -vf \"$SCALE_FILTER,format=nv12,hwupload=extra_hw_frames=64,format=qsv\" -c:v $V_CODEC -global_quality $CRF_VALUE -preset medium $A_FLAGS -movflags +faststart \"${file%.*}.temp_optim.mp4\""
        elif [ "$HW_TYPE" == "vaapi" ]; then
            V_CODEC="h${CODEC}_vaapi"; [ "$CODEC" == "265" ] && V_CODEC="hevc_vaapi"
            CMD="ffmpeg -n -v error -stats -vaapi_device $HW_DEVICE -i \"$file\" -vf \"$SCALE_FILTER,format=nv12,hwupload\" -c:v $V_CODEC -qp $CRF_VALUE $A_FLAGS -movflags +faststart \"${file%.*}.temp_optim.mp4\""
        else
            V_CODEC="libx${CODEC}"
            CMD="ffmpeg -n -v error -stats -i \"$file\" -c:v $V_CODEC -crf $CRF_VALUE -preset $DEFAULT_PRESET -vf \"$SCALE_FILTER\" $A_FLAGS -movflags +faststart \"${file%.*}.temp_optim.mp4\""
        fi

        # Run
        eval "$CMD" < /dev/null
        
        # Post-Process
        TEMP_FILE="${file%.*}.temp_optim.mp4"
        
        if [ $? -eq 0 ] && [ -s "$TEMP_FILE" ]; then
            END_SIZE=$(get_file_size "$TEMP_FILE")
            
            # Calculate percentage reduction
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

            echo "  > Done. Reduced by $PCT%"
            
            if [ "$GENERATE_HTML" = true ]; then
                ROW="<tr><td>$(basename "$file")</td><td>$(format_size $START_SIZE)</td><td>$(format_size $END_SIZE)</td><td class='success'>-$PCT%</td><td>Success</td></tr>"
                REPORT_DATA+=("$ROW")
            fi
        else
            echo "  > Failed."
            [ -f "$TEMP_FILE" ] && rm "$TEMP_FILE"
            if [ "$GENERATE_HTML" = true ]; then
                ROW="<tr><td>$(basename "$file")</td><td>$(format_size $START_SIZE)</td><td>-</td><td>-</td><td class='error'>Failed</td></tr>"
                REPORT_DATA+=("$ROW")
            fi
        fi

    done

    if [ "$GENERATE_HTML" = true ]; then
        generate_html_report
    fi
}

# ------------------------------------------------------------------------------
# Parse Args or Launch Menu
# ------------------------------------------------------------------------------

if [ $# -eq 0 ]; then
    # No args? Menu.
    show_menu
    process_videos
else
    # Parse Args
    while [[ $# -gt 0 ]]; do
      case $1 in
        -h|--help) usage; exit 0 ;;
        --menu) show_menu; process_videos; exit 0 ;;
        -k|--keep) OVERWRITE=false; shift ;;
        -s|--subs) DOWNLOAD_SUBS=true; shift ;;
        -r|--res) TARGET_RES="$2"; shift 2 ;;
        --no-hw) DISABLE_HW=true; shift ;;
        --downmix) RECODE_AUDIO=true; DOWNMIX_AUDIO=true; shift ;;
        --html) GENERATE_HTML=true; shift ;;
        *) 
           if [ -d "$1" ]; then TARGET_DIR="$1"
           elif [[ "$1" =~ ^[0-9]+$ ]] && [ -z "$ARG_CRF_SET" ]; then CODEC="265"; CRF_VALUE="$1"; ARG_CRF_SET=1
           elif [[ "$1" == "264" || "$1" == "265" ]]; then CODEC="$1"
           fi
           shift 
           ;;
      esac
    done
    check_dependencies
    process_videos
fi