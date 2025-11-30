#!/bin/bash

# ==============================================================================
# Title: ViCo - Recursive Video Compressor (TUI Edition)
# Description: Robust video optimizer with interactive TUI.
#              Fixes directory detection, function ordering, and adds cleanup.
# Dependencies: bash, ffmpeg, ffprobe, dialog
# ==============================================================================

# --- 1. IMMEDIATE ENVIRONMENT SANITIZATION ---
# Capture the environment PWD before any commands run, as this persists even
# if the directory is physically deleted.
USER_INVOCATION_DIR="$PWD"

# Check if the current directory is actually accessible.
# If not, switch to HOME to prevent "shell-init" errors in subshells.
if ! pwd >/dev/null 2>&1; then
    if [ -d "$HOME" ]; then
        cd "$HOME" >/dev/null 2>&1
    else
        cd "/tmp" >/dev/null 2>&1
    fi
fi

# Now we are in a safe directory. We can resolve paths.
# If arguments were passed (like .), resolve them relative to where the user WAS.
REQUESTED_TARGET="$1"

if [ -n "$REQUESTED_TARGET" ]; then
    # Handle relative paths manually since we changed directory
    if [[ "$REQUESTED_TARGET" != /* ]]; then
        # It's relative, prepend the original PWD
        TARGET_DIR="$USER_INVOCATION_DIR/$REQUESTED_TARGET"
    else
        TARGET_DIR="$REQUESTED_TARGET"
    fi
else
    # Default to the directory the user ran the script from
    TARGET_DIR="$USER_INVOCATION_DIR"
fi

# Clean up path (remove trailing slash, resolve . and ..)
if command -v realpath &> /dev/null; then
    # Suppress error if path doesn't exist yet (handled in validation)
    RESOLVED=$(realpath -m "$TARGET_DIR" 2>/dev/null)
    [ -n "$RESOLVED" ] && TARGET_DIR="$RESOLVED"
fi

# --- 2. GLOBAL CONFIGURATION DEFAULTS ---
CONF_RES="1080"
CONF_CODEC="264"        # 264 or 265
CONF_CRF="23"
CONF_AUDIO="copy"       # copy | downmix
CONF_HW="auto"          # auto | cpu | nvenc | qsv | vaapi
CONF_SUBS="false"       # true | false
CONF_OVERWRITE="true"   # true | false
CONF_HTML="false"       # true | false
CONF_RECURSIVE="true"   # true | false

# Global Temp File Tracker for Cleanup
CURRENT_TEMP_FILE=""

# Stats Tracking
STATS_TOTAL_FILES=0
STATS_START_TIME=0
STATS_END_TIME=0
REPORT_DATA=()

# --- 3. SIGNAL TRAP & CLEANUP ---

cleanup_and_exit() {
    echo ""
    echo "=========================================="
    echo "   STOPPING PROCESSING (User Interrupt)   "
    echo "=========================================="
    
    if [ -n "$CURRENT_TEMP_FILE" ] && [ -f "$CURRENT_TEMP_FILE" ]; then
        echo "Cleaning up temporary file: $CURRENT_TEMP_FILE"
        rm -f "$CURRENT_TEMP_FILE"
    fi
    
    echo "Exiting gracefully."
    exit 1
}

# Trap SIGINT (Ctrl+C)
trap cleanup_and_exit SIGINT

# --- 4. HELPER FUNCTIONS ---

usage() {
    echo "Usage: $0 [flags] [directory]"
    echo "  -h, --help       Show help"
    echo "  --menu           Force interactive menu"
    echo "  --no-recursive   Disable recursion"
    echo "  (See menu for full configuration options)"
    exit 0
}

check_deps() {
    local missing=()
    for tool in ffmpeg ffprobe dialog; do
        if ! command -v "$tool" &> /dev/null; then missing+=("$tool"); fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Installing dependencies: ${missing[*]}..."
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            case "$ID" in
                ubuntu|debian|pop|kali) sudo apt-get update && sudo apt-get install -y "${missing[@]}" ;;
                fedora|centos|rhel)     sudo dnf install -y "${missing[@]}" ;;
                arch|manjaro)           sudo pacman -S --noconfirm "${missing[@]}" ;;
                *) echo "Please install manually: ${missing[*]}"; exit 1 ;;
            esac
        else
            echo "Unknown OS. Please install: ${missing[*]}"
            exit 1
        fi
    fi
}

format_time() {
    local T=$1
    local H=$((T/3600))
    local M=$(( (T%3600)/60 ))
    local S=$((T%60))
    printf "%02d:%02d:%02d" $H $M $S
}

format_size() {
    numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1"
}

# --- 5. HARDWARE DETECTION ---

detect_hardware_capability() {
    if [ "$CONF_HW" != "auto" ]; then return; fi
    
    # Default to CPU
    CONF_HW="cpu"
    
    ENCODERS=$(ffmpeg -hide_banner -encoders 2>/dev/null)

    # Nvidia
    if echo "$ENCODERS" | grep -q "nvenc"; then
        if command -v nvidia-smi &> /dev/null; then
            CONF_HW="nvenc"
            return
        fi
    fi

    # Intel QSV (Prioritize over VAAPI for Intel)
    for dev in /sys/class/drm/renderD*; do
        if [ -e "$dev/device/vendor" ] && grep -q "0x8086" "$dev/device/vendor"; then
            if echo "$ENCODERS" | grep -q "qsv"; then
                CONF_HW="qsv"
                HW_DEVICE="/dev/dri/$(basename "$dev")"
                return
            fi
        fi
    done

    # VAAPI (AMD or Intel Fallback)
    if echo "$ENCODERS" | grep -q "vaapi"; then
        if ls /dev/dri/renderD* 1> /dev/null 2>&1; then
            CONF_HW="vaapi"
            HW_DEVICE=$(ls /dev/dri/renderD* | head -n 1)
            return
        fi
    fi
}

# --- 6. INTERACTIVE MENU ---

show_main_menu() {
    # Ensure TARGET_DIR is sane before showing menu
    [ -z "$TARGET_DIR" ] && TARGET_DIR="$USER_INVOCATION_DIR"

    # Initialize default selection
    SELECTION="1"

    while true; do
        # Dynamic Descriptions
        local d_audio="Copy Audio"
        [ "$CONF_AUDIO" == "downmix" ] && d_audio="Downmix (Stereo)"
        
        local d_hw="Auto-Detect"
        [ "$CONF_HW" == "cpu" ] && d_hw="Force CPU"
        
        local d_subs="Skip"
        [ "$CONF_SUBS" == "true" ] && d_subs="Download"
        
        local d_rec="Yes"
        [ "$CONF_RECURSIVE" == "false" ] && d_rec="No (Flat)"
        
        local d_ow="Overwrite"
        [ "$CONF_OVERWRITE" == "false" ] && d_ow="Keep Original"

        local d_html="No"
        [ "$CONF_HTML" == "true" ] && d_html="Yes"

        # Display Menu
        CHOICE=$(dialog --stdout --clear --backtitle "ViCo - Video Compressor" \
            --title "Configuration" \
            --default-item "$SELECTION" \
            --menu "Directory: $TARGET_DIR" 20 70 12 \
            "1" "START PROCESSING" \
            "2" "Target Directory" \
            "3" "Resolution [$CONF_RES]" \
            "4" "Codec [H.$CONF_CODEC]" \
            "5" "CRF [$CONF_CRF]" \
            "6" "Audio [$d_audio]" \
            "7" "Hardware [$d_hw]" \
            "8" "Recursion [$d_rec]" \
            "9" "Subtitles [$d_subs]" \
            "10" "Overwrite [$d_ow]" \
            "11" "HTML Report [$d_html]" \
            "0" "Exit")

        # Store selection to return to it
        SELECTION="$CHOICE"

        case $CHOICE in
            1) break ;; 
            2) 
                # File Browser
                local browse_start="${TARGET_DIR%/}/"
                NEW_DIR=$(dialog --stdout --title "Select Directory" --dselect "$browse_start" 14 70)
                if [ -n "$NEW_DIR" ]; then
                    TARGET_DIR="${NEW_DIR%/}"
                    [ -z "$TARGET_DIR" ] && TARGET_DIR="/"
                fi
                ;;
            3)
                CONF_RES=$(dialog --stdout --title "Resolution" --radiolist "Select Target Height" 15 50 5 \
                    "720" "720p" off "1080" "1080p" on "2160" "4K" off)
                [ -z "$CONF_RES" ] && CONF_RES="1080"
                ;;
            4)
                CONF_CODEC=$(dialog --stdout --title "Codec" --radiolist "Select Codec" 15 50 5 \
                    "264" "H.264 (AVC)" on "265" "H.265 (HEVC)" off)
                [ -z "$CONF_CODEC" ] && CONF_CODEC="264"
                ;;
            5)
                CONF_CRF=$(dialog --stdout --title "CRF" --inputbox "Enter Quality (18-28). Lower=Better." 8 60 "$CONF_CRF")
                ;;
            6)
                local aud=$(dialog --stdout --title "Audio" --radiolist "Audio Mode" 15 60 5 \
                    "copy" "Copy Stream Intact" on "downmix" "Re-encode to Stereo AAC" off)
                [ -n "$aud" ] && CONF_AUDIO="$aud"
                ;;
            7)
                local hw=$(dialog --stdout --title "Hardware" --radiolist "Hardware Acceleration" 15 60 5 \
                    "auto" "Auto-Detect" on "cpu" "Force CPU Only" off)
                [ -n "$hw" ] && CONF_HW="$hw"
                ;;
            8)
                if [ "$CONF_RECURSIVE" == "true" ]; then CONF_RECURSIVE="false"; else CONF_RECURSIVE="true"; fi ;;
            9)
                if [ "$CONF_SUBS" == "true" ]; then CONF_SUBS="false"; else CONF_SUBS="true"; fi ;;
            10)
                if [ "$CONF_OVERWRITE" == "true" ]; then CONF_OVERWRITE="false"; else CONF_OVERWRITE="true"; fi ;;
            11)
                if [ "$CONF_HTML" == "true" ]; then CONF_HTML="false"; else CONF_HTML="true"; fi ;;
            0) clear; echo "Exiting."; exit 0 ;;
            *) clear; echo "Exiting."; exit 0 ;;
        esac
    done
    clear
}

# --- 7. PROCESSING LOGIC ---

process_files() {
    # Validate Target
    if [ ! -d "$TARGET_DIR" ]; then
        echo "Error: Directory not found: $TARGET_DIR"
        exit 1
    fi

    detect_hardware_capability
    
    echo "=========================================="
    echo "Starting Processing"
    echo "Dir: $TARGET_DIR"
    echo "HW:  $CONF_HW"
    echo "Rec: $CONF_RECURSIVE"
    echo "=========================================="
    STATS_START_TIME=$SECONDS

    # HTML Header
    REPORT_PATH="$TARGET_DIR/vico_report.html"
    if [ "$CONF_HTML" == "true" ]; then
        # Added meta refresh tag for live updates
        cat <<EOF > "$REPORT_PATH"
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8">
<meta http-equiv="refresh" content="5">
<title>ViCo Report</title>
<style>body{font-family:sans-serif;background:#f4f4f9;padding:20px}table{width:100%;border-collapse:collapse;background:#fff;box-shadow:0 1px 3px rgba(0,0,0,0.2)}th,td{padding:12px;border-bottom:1px solid #ddd;text-align:left}th{background:#4CAF50;color:#fff}.good{color:green;font-weight:bold}.bad{color:red}</style>
</head><body><h1>ViCo Compression Report</h1><p>Date: $(date)</p><table>
<tr><th>File</th><th>Orig Size</th><th>New Size</th><th>Reduced</th><th>FPS</th><th>Status</th></tr>
EOF
    fi

    # Build Find Command
    FIND_CMD=(find "$TARGET_DIR" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.avi" \))
    if [ "$CONF_RECURSIVE" == "false" ]; then
        FIND_CMD+=(-maxdepth 1)
    fi

    # Main Loop
    # Use FD 9 to prevent ffmpeg stealing stdin
    while IFS= read -r -d '' -u 9 file; do
        
        if [[ "$file" == *"_optimized.mp4" ]] || [[ "$file" == *".temp_vico.mp4" ]]; then continue; fi
        
        STATS_TOTAL_FILES=$((STATS_TOTAL_FILES + 1))
        BASENAME=$(basename "$file")
        DIRNAME=$(dirname "$file")
        NAME_NOEXT="${BASENAME%.*}"
        TEMP_FILE="$DIRNAME/${NAME_NOEXT}.temp_vico.mp4"
        
        # Set global tracker for cleanup trap
        CURRENT_TEMP_FILE="$TEMP_FILE"
        
        if [ "$CONF_OVERWRITE" == "true" ]; then
            FINAL_FILE="${DIRNAME}/${NAME_NOEXT}.mp4"
        else
            FINAL_FILE="${DIRNAME}/${NAME_NOEXT}_optimized.mp4"
        fi

        echo "[$STATS_TOTAL_FILES] Processing: $BASENAME"

        # Validate Video
        if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type "$file" < /dev/null 2>/dev/null | grep -q "video"; then
            echo "   > Skipped (Not a valid video)"
            if [ "$CONF_HTML" == "true" ]; then
                echo "<tr><td>$BASENAME</td><td>-</td><td>-</td><td>-</td><td>-</td><td class='bad'>Invalid</td></tr>" >> "$REPORT_PATH"
            fi
            continue
        fi
        
        START_SIZE=$(stat -c%s "$file")

        # Subtitles
        if [ "$CONF_SUBS" == "true" ]; then
            if ! ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$file" < /dev/null 2>/dev/null | grep -q .; then
                SLANG="${LANG%%_*}"; [ -z "$SLANG" ] && SLANG="en"
                echo "   > Downloading subtitles..."
                timeout 30s subliminal download -l "$SLANG" "$file" < /dev/null >/dev/null 2>&1
            fi
        fi

        # Audio Settings
        if [ "$CONF_AUDIO" == "downmix" ]; then
            CH=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$file" < /dev/null 2>/dev/null)
            if [[ "$CH" -gt 2 ]]; then
                A_OPTS="-c:a aac -b:a 128k -ac 2"
            else
                A_OPTS="-c:a aac -b:a 128k"
            fi
        else
            A_OPTS="-c:a copy"
        fi

        # Video Settings
        SCALE="-vf scale=-2:$CONF_RES"
        
        if [ "$CONF_HW" == "nvenc" ]; then
            [ "$CONF_CODEC" == "265" ] && V_ENC="hevc_nvenc" || V_ENC="h264_nvenc"
            CMD_PRE="ffmpeg -y -nostdin -hwaccel cuda -hwaccel_output_format cuda -i"
            CMD_POST="-c:v $V_ENC -preset p4 -cq $CONF_CRF $SCALE"
        elif [ "$CONF_HW" == "qsv" ]; then
            [ "$CONF_CODEC" == "265" ] && V_ENC="hevc_qsv" || V_ENC="h264_qsv"
            export LIBVA_DRIVER_NAME=iHD
            CMD_PRE="ffmpeg -y -nostdin -init_hw_device vaapi=va:$HW_DEVICE -init_hw_device qsv=hw@va -filter_hw_device hw -i"
            CMD_POST="-vf scale=-2:$CONF_RES,format=nv12,hwupload=extra_hw_frames=64,format=qsv -c:v $V_ENC -global_quality $CONF_CRF -preset medium"
        elif [ "$CONF_HW" == "vaapi" ]; then
            [ "$CONF_CODEC" == "265" ] && V_ENC="hevc_vaapi" || V_ENC="h264_vaapi"
            CMD_PRE="ffmpeg -y -nostdin -vaapi_device $HW_DEVICE -i"
            CMD_POST="-vf scale=-2:$CONF_RES,format=nv12,hwupload -c:v $V_ENC -qp $CONF_CRF"
        else
            [ "$CONF_CODEC" == "265" ] && V_ENC="libx265" || V_ENC="libx264"
            CMD_PRE="ffmpeg -y -nostdin -i"
            CMD_POST="-c:v $V_ENC -crf $CONF_CRF -preset medium $SCALE"
        fi

        FULL_CMD="$CMD_PRE \"$file\" $CMD_POST $A_OPTS -movflags +faststart \"$TEMP_FILE\""
        
        # Run FFmpeg
        LOG=$(mktemp)
        # Use pipe to tee to show progress on stdout while capturing to log for stats
        eval "$FULL_CMD" 2>&1 | tee "$LOG"
        RET=${PIPESTATUS[0]}
        
        # Stats
        FPS=$(grep -oE "fps=[[:space:]]*[0-9.]+" "$LOG" | tail -1 | sed 's/fps=//' | tr -d ' ')
        [ -z "$FPS" ] && FPS="N/A"
        rm "$LOG"

        # Handle Success/Fail
        if [ $RET -eq 0 ] && [ -s "$TEMP_FILE" ]; then
            END_SIZE=$(stat -c%s "$TEMP_FILE")
            if [ $START_SIZE -gt 0 ]; then
                DIFF=$((START_SIZE - END_SIZE))
                PCT=$(awk "BEGIN {printf \"%.2f\", ($DIFF / $START_SIZE) * 100}")
            else
                PCT="0"
            fi
            
            mv "$TEMP_FILE" "$FINAL_FILE"
            
            if [ "$CONF_OVERWRITE" == "true" ] && [ "$file" != "$FINAL_FILE" ]; then
                rm "$file"
            fi
            
            echo "   > Success. Reduced by $PCT%. FPS: $FPS"
            if [ "$CONF_HTML" == "true" ]; then
                S1=$(format_size $START_SIZE); S2=$(format_size $END_SIZE)
                echo "<tr><td>$BASENAME</td><td>$S1</td><td>$S2</td><td class='good'>-$PCT%</td><td>$FPS</td><td>OK</td></tr>" >> "$REPORT_PATH"
            fi
        else
            echo "   > Failed."
            [ -f "$TEMP_FILE" ] && rm "$TEMP_FILE"
            if [ "$CONF_HTML" == "true" ]; then
                S1=$(format_size $START_SIZE)
                echo "<tr><td>$BASENAME</td><td>$S1</td><td>-</td><td>-</td><td>-</td><td class='bad'>Fail</td></tr>" >> "$REPORT_PATH"
            fi
        fi
        
        # Clear temp tracker
        CURRENT_TEMP_FILE=""

    done 9< <("${FIND_CMD[@]}" -print0)

    STATS_END_TIME=$SECONDS
    
    if [ "$CONF_HTML" == "true" ]; then
        echo "</table></body></html>" >> "$REPORT_PATH"
        # Remove the refresh tag from the final report to stop reloading
        sed -i '/http-equiv="refresh"/d' "$REPORT_PATH"
    fi
    
    print_synopsis
}

print_synopsis() {
    local duration=$((STATS_END_TIME - STATS_START_TIME))
    local h=$((duration/3600))
    local m=$(( (duration%3600)/60 ))
    local s=$((duration%60))
    
    echo ""
    echo "=========================================="
    echo "           ViCo Execution Summary         "
    echo "=========================================="
    printf "  Total Files:            %d\n" "$STATS_TOTAL_FILES"
    printf "  Total Duration:         %02d:%02d:%02d\n" $h $m $s
    if [ "$CONF_HTML" == "true" ]; then
        echo "  Report:                 $REPORT_PATH"
    fi
    echo "=========================================="
}

# --- 8. ENTRY POINT ---

check_deps

# Check flags
FORCE_MENU=false
# If no arguments are provided, default to menu mode
if [ $# -eq 0 ]; then FORCE_MENU=true; fi

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        --menu) FORCE_MENU=true; shift ;;
        --no-recursive) CONF_RECURSIVE="false"; shift ;;
        # Basic CLI overrides could be expanded here
        *) 
           if [ -d "$1" ]; then REQUESTED_TARGET="$1"; shift
           else shift; fi 
           ;;
    esac
done

if [ "$FORCE_MENU" == "true" ]; then
    show_main_menu
else
    # Headless logic
    if [ -n "$REQUESTED_TARGET" ]; then
        # Handle relative/absolute logic same as menu
        if [[ "$REQUESTED_TARGET" != /* ]]; then
             TARGET_DIR="$USER_INVOCATION_DIR/$REQUESTED_TARGET"
        else
             TARGET_DIR="$REQUESTED_TARGET"
        fi
    else
        TARGET_DIR="$USER_INVOCATION_DIR"
    fi
    
    if command -v realpath &> /dev/null; then
        TARGET_DIR=$(realpath "$TARGET_DIR")
    fi
fi

process_files