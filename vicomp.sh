#!/bin/bash

# ==============================================================================
# Title: ViCo - Recursive Video Compressor (Stable Edition)
# Description: Robust video optimizer with interactive TUI.
#              Fixes MP4 subtitle incompatibilities and path handling.
# Dependencies: bash, ffmpeg, ffprobe, dialog
# ==============================================================================

# --- 1. ENVIRONMENT SETUP & SANITIZATION ---

# Immediately capture the directory the user called the script from
USER_INVOCATION_DIR="$PWD"

# Prevent "shell-init" errors by moving to a safe directory if the current one is unstable
if ! pwd >/dev/null 2>&1; then
    cd "${HOME:-/tmp}" || exit 1
fi

# Determine absolute path to defaults
if command -v realpath &> /dev/null; then
    DEFAULT_START_DIR=$(realpath "$USER_INVOCATION_DIR")
else
    DEFAULT_START_DIR="$USER_INVOCATION_DIR"
fi

# --- 2. CONFIGURATION DEFAULTS ---
CFG_DIR="$DEFAULT_START_DIR"
CFG_RES="1080"
CFG_CODEC="264"
CFG_CRF="23"
CFG_AUDIO="copy"       # 'copy' or 'downmix'
CFG_HW="auto"          # 'auto', 'cpu', 'nvenc', 'qsv', 'vaapi'
CFG_SUBS="false"       # 'true' or 'false'
CFG_OVERWRITE="true"   # 'true' or 'false'
CFG_RECURSIVE="true"   # 'true' or 'false'
CFG_HTML="false"       # 'true' or 'false'

# Internal Global Variables
STATS_TOTAL=0
STATS_START=0
CURRENT_TEMP=""
REPORT_DATA=()

# --- 3. CLEANUP & TRAPS ---

cleanup_exit() {
    echo ""
    echo "!!! Process Interrupted !!!"
    if [ -n "$CURRENT_TEMP" ] && [ -f "$CURRENT_TEMP" ]; then
        echo "Removing incomplete file: $CURRENT_TEMP"
        rm -f "$CURRENT_TEMP"
    fi
    # Restore cursor if dialog messed it up
    clear
    echo "Exited."
    exit 1
}
trap cleanup_exit SIGINT SIGTERM

# --- 4. HARDWARE DETECTION ENGINE ---

detect_hardware() {
    # If manually set to CPU, return
    if [ "$CFG_HW" == "cpu" ]; then return; fi

    local ffmpeg_encoders
    ffmpeg_encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null)
    
    # 1. NVIDIA
    if echo "$ffmpeg_encoders" | grep -q "nvenc"; then
        if command -v nvidia-smi &> /dev/null; then
            CFG_HW="nvenc"
            return
        fi
    fi

    # 2. Intel QSV
    # Strictly check for Intel Vendor ID (0x8086) to avoid AMD conflicts
    local intel_card=""
    for dev in /sys/class/drm/renderD*; do
        if [ -e "$dev/device/vendor" ] && grep -q "0x8086" "$dev/device/vendor"; then
            intel_card="/dev/dri/$(basename "$dev")"
            break
        fi
    done

    if [ -n "$intel_card" ] && echo "$ffmpeg_encoders" | grep -q "qsv"; then
        CFG_HW="qsv"
        HW_DEVICE="$intel_card"
        return
    fi

    # 3. VAAPI (AMD / Intel fallback)
    if echo "$ffmpeg_encoders" | grep -q "vaapi"; then
        # Find first valid render node
        local render_node=""
        if ls /dev/dri/renderD* 1> /dev/null 2>&1; then
            render_node=$(ls /dev/dri/renderD* | head -n 1)
        fi
        
        if [ -n "$render_node" ]; then
            CFG_HW="vaapi"
            HW_DEVICE="$render_node"
            return
        fi
    fi

    # Fallback
    CFG_HW="cpu"
}

# --- 5. DEPENDENCY CHECK ---

check_dependencies() {
    local missing=()
    for cmd in ffmpeg ffprobe dialog; do
        if ! command -v "$cmd" &> /dev/null; then missing+=("$cmd"); fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing dependencies: ${missing[*]}"
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            case "$ID" in
                ubuntu|debian|pop|kali) sudo apt-get update && sudo apt-get install -y "${missing[@]}" ;;
                fedora|centos|rhel)     sudo dnf install -y "${missing[@]}" ;;
                arch|manjaro)           sudo pacman -S --noconfirm "${missing[@]}" ;;
                *) echo "Install manually."; exit 1 ;;
            esac
        else
            exit 1
        fi
    fi
}

# --- 6. INTERACTIVE MENU SYSTEM ---

show_menu() {
    # Validate initial directory
    if [ ! -d "$CFG_DIR" ]; then CFG_DIR="$DEFAULT_START_DIR"; fi

    local selection="1"

    while true; do
        # Dynamic labels
        local lbl_audio="Copy Audio (Intact)"
        [ "$CFG_AUDIO" == "downmix" ] && lbl_audio="Stereo AAC (Re-encode)"
        
        local lbl_hw="Auto-Detect"
        [ "$CFG_HW" == "cpu" ] && lbl_hw="Force CPU"

        local lbl_rec="Yes"
        [ "$CFG_RECURSIVE" == "false" ] && lbl_rec="No (Current Folder)"

        local lbl_subs="Skip"
        [ "$CFG_SUBS" == "true" ] && lbl_subs="Download"

        local lbl_html="No"
        [ "$CFG_HTML" == "true" ] && lbl_html="Yes"

        local choice
        choice=$(dialog --stdout --clear --backtitle "ViCo - Video Compressor" \
            --title "Main Menu" \
            --default-item "$selection" \
            --menu "Target: $CFG_DIR" 22 70 12 \
            "1" "START PROCESSING" \
            "2" "Directory Select" \
            "3" "Resolution [$CFG_RES]" \
            "4" "Codec [H.$CFG_CODEC]" \
            "5" "Quality CRF [$CFG_CRF]" \
            "6" "Audio [$lbl_audio]" \
            "7" "Hardware [$lbl_hw]" \
            "8" "Recursion [$lbl_rec]" \
            "9" "Subtitles [$lbl_subs]" \
            "10" "HTML Report [$lbl_html]" \
            "0" "Exit") || exit 0

        selection="$choice"

        case $choice in
            1) break ;;
            2)
                # File Browser
                # Ensure trailing slash to force directory entry
                local start_browse="${CFG_DIR%/}/"
                local new_dir
                new_dir=$(dialog --stdout --title "Choose Directory" --dselect "$start_browse" 14 70)
                if [ -n "$new_dir" ]; then
                    CFG_DIR="${new_dir%/}"
                    [ -z "$CFG_DIR" ] && CFG_DIR="/"
                fi
                ;;
            3)
                CFG_RES=$(dialog --stdout --radiolist "Vertical Resolution" 15 50 5 \
                    "480" "480p (SD)" off \
                    "720" "720p (HD)" off \
                    "1080" "1080p (FHD)" on \
                    "2160" "2160p (4K)" off)
                [ -z "$CFG_RES" ] && CFG_RES="1080"
                ;;
            4)
                CFG_CODEC=$(dialog --stdout --radiolist "Video Codec" 15 50 5 \
                    "264" "H.264 (AVC)" on \
                    "265" "H.265 (HEVC)" off)
                [ -z "$CFG_CODEC" ] && CFG_CODEC="264"
                ;;
            5)
                CFG_CRF=$(dialog --stdout --inputbox "CRF Value (18-28).\nLower = Better Quality, Larger File." 10 60 "$CFG_CRF")
                ;;
            6)
                local aud_res=$(dialog --stdout --radiolist "Audio Strategy" 15 60 5 \
                    "copy" "Copy Streams (Best Quality)" on \
                    "downmix" "Downmix to Stereo AAC" off)
                [ -n "$aud_res" ] && CFG_AUDIO="$aud_res"
                ;;
            7)
                local hw_res=$(dialog --stdout --radiolist "Hardware Acceleration" 15 60 5 \
                    "auto" "Auto-Detect Best" on \
                    "cpu" "Force CPU" off)
                [ -n "$hw_res" ] && CFG_HW="$hw_res"
                ;;
            8)
                [ "$CFG_RECURSIVE" == "true" ] && CFG_RECURSIVE="false" || CFG_RECURSIVE="true"
                ;;
            9)
                [ "$CFG_SUBS" == "true" ] && CFG_SUBS="false" || CFG_SUBS="true"
                ;;
            10)
                [ "$CFG_HTML" == "true" ] && CFG_HTML="false" || CFG_HTML="true"
                ;;
            0) clear; exit 0 ;;
        esac
    done
    clear
}

# --- 7. CORE PROCESSING ENGINE ---

process_video_file() {
    local input_file="$1"
    
    # Skip logic
    if [[ "$input_file" == *"_optimized.mp4" ]]; then return; fi
    if [[ "$input_file" == *".temp_vico.mp4" ]]; then return; fi

    STATS_TOTAL=$((STATS_TOTAL + 1))
    local basename=$(basename "$input_file")
    local dirname=$(dirname "$input_file")
    local name_no_ext="${basename%.*}"
    local temp_file="$dirname/${name_no_ext}.temp_vico.mp4"
    
    # Set global for trap
    CURRENT_TEMP="$temp_file"

    # Destination
    local final_file
    if [ "$CFG_OVERWRITE" == "true" ]; then
        final_file="$dirname/${name_no_ext}.mp4"
    else
        final_file="$dirname/${name_no_ext}_optimized.mp4"
    fi

    echo "[$STATS_TOTAL] $basename"

    # 1. Validation
    if ! ffprobe -v error -select_streams v:0 -show_entries stream=codec_type "$input_file" < /dev/null 2>/dev/null | grep -q "video"; then
        echo "    > Invalid video. Skipping."
        return
    fi

    local start_size=$(stat -c%s "$input_file")

    # 2. Subtitles (Optional)
    if [ "$CFG_SUBS" == "true" ]; then
        # Check for embedded subs
        if ! ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$input_file" < /dev/null 2>/dev/null | grep -q .; then
            local slang="${LANG%%_*}"
            [ -z "$slang" ] && slang="en"
            # Run in background with timeout to avoid hanging
            timeout 20s subliminal download -l "$slang" "$input_file" < /dev/null >/dev/null 2>&1
        fi
    fi

    # 3. Construct FFmpeg Arguments (Using Arrays for Safety)
    local cmd_args=()
    local video_args=()
    local audio_args=()
    
    # Standard Flags
    cmd_args+=("-y" "-nostdin" "-v" "error" "-stats")

    # --- Hardware Setup ---
    local scale_filter="scale=-2:$CFG_RES"

    if [ "$CFG_HW" == "nvenc" ]; then
        cmd_args+=("-hwaccel" "cuda" "-hwaccel_output_format" "cuda")
        local v_enc="h${CFG_CODEC}_nvenc"
        [ "$CFG_CODEC" == "265" ] && v_enc="hevc_nvenc"
        video_args+=("-c:v" "$v_enc" "-preset" "p4" "-cq" "$CFG_CRF" "-vf" "$scale_filter")

    elif [ "$CFG_HW" == "qsv" ]; then
        # QSV specific environment + device init
        cmd_args+=("-init_hw_device" "vaapi=va:$HW_DEVICE" "-init_hw_device" "qsv=hw@va" "-filter_hw_device" "hw")
        local v_enc="h${CFG_CODEC}_qsv"
        [ "$CFG_CODEC" == "265" ] && v_enc="hevc_qsv"
        # QSV filter chain
        local qsv_vf="${scale_filter},format=nv12,hwupload=extra_hw_frames=64,format=qsv"
        video_args+=("-vf" "$qsv_vf" "-c:v" "$v_enc" "-global_quality" "$CFG_CRF" "-preset" "medium")

    elif [ "$CFG_HW" == "vaapi" ]; then
        cmd_args+=("-vaapi_device" "$HW_DEVICE")
        local v_enc="h${CFG_CODEC}_vaapi"
        [ "$CFG_CODEC" == "265" ] && v_enc="hevc_vaapi"
        local vaapi_vf="${scale_filter},format=nv12,hwupload"
        video_args+=("-vf" "$vaapi_vf" "-c:v" "$v_enc" "-qp" "$CFG_CRF")

    else
        # CPU
        local v_enc="libx${CFG_CODEC}"
        video_args+=("-c:v" "$v_enc" "-crf" "$CFG_CRF" "-preset" "medium" "-vf" "$scale_filter")
    fi

    # --- Audio & Subtitle Logic ---
    # Map everything first
    cmd_args+=("-i" "$input_file" "-map" "0:v:0" "-map" "0:a?" "-map" "0:s?")

    # Handle Audio
    if [ "$CFG_AUDIO" == "downmix" ]; then
        # Check channel count
        local ch=$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$input_file" < /dev/null 2>/dev/null)
        if [[ "$ch" -gt 2 ]]; then
            audio_args+=("-c:a" "aac" "-b:a" "128k" "-ac" "2")
        else
            audio_args+=("-c:a" "aac" "-b:a" "128k")
        fi
    else
        # Copy is default
        audio_args+=("-c:a" "copy")
    fi

    # Handle Subtitles (Convert to mov_text for MP4 compatibility)
    # This fixes the [mp4] error with ASS subtitles
    audio_args+=("-c:s" "mov_text")

    # --- Execution ---
    # Combine all args
    local full_cmd=("ffmpeg" "${cmd_args[@]}" "${video_args[@]}" "${audio_args[@]}" "-movflags" "+faststart" "$temp_file")
    
    local log_file=$(mktemp)
    
    # Execute with environment var if QSV
    if [ "$CFG_HW" == "qsv" ]; then
        env LIBVA_DRIVER_NAME=iHD "${full_cmd[@]}" 2>&1 | tee "$log_file"
    else
        "${full_cmd[@]}" 2>&1 | tee "$log_file"
    fi
    
    local ret=${PIPESTATUS[0]}

    # --- Stats & Cleanup ---
    local fps=$(grep -oE "fps=[[:space:]]*[0-9.]+" "$log_file" | tail -1 | sed 's/fps=//' | tr -d ' ')
    rm "$log_file"
    [ -z "$fps" ] && fps="N/A"

    if [ $ret -eq 0 ] && [ -s "$temp_file" ]; then
        local end_size=$(stat -c%s "$temp_file")
        
        # Replace/Move
        mv "$temp_file" "$final_file"
        
        # Handle Overwrite (if names differed)
        if [ "$CFG_OVERWRITE" == "true" ] && [ "$input_file" != "$final_file" ]; then
            rm "$input_file"
        fi

        # Calc percentage
        local pct=0
        if [ $start_size -gt 0 ]; then
             pct=$(awk "BEGIN {printf \"%.2f\", (($start_size - $end_size) / $start_size) * 100}")
        fi
        
        echo "    > Done. Saved: $pct% ($fps fps)"
        
        if [ "$CFG_HTML" == "true" ]; then
             local h_s=$(numfmt --to=iec-i --suffix=B $start_size)
             local h_e=$(numfmt --to=iec-i --suffix=B $end_size)
             REPORT_DATA+=("<tr><td>$basename</td><td>$h_s</td><td>$h_e</td><td class='good'>$pct%</td><td>$fps</td><td>OK</td></tr>")
             TOTAL_BYTES_SAVED=$((TOTAL_BYTES_SAVED + (start_size - end_size)))
        fi
    else
        echo "    > Failed."
        [ -f "$temp_file" ] && rm "$temp_file"
        if [ "$CFG_HTML" == "true" ]; then
             local h_s=$(numfmt --to=iec-i --suffix=B $start_size)
             REPORT_DATA+=("<tr><td>$basename</td><td>$h_s</td><td>-</td><td>-</td><td>-</td><td class='bad'>Error</td></tr>")
        fi
    fi
    
    CURRENT_TEMP=""
}

run_batch() {
    # Verify Directory
    if [ ! -d "$CFG_DIR" ]; then
        echo "Error: Directory $CFG_DIR does not exist."
        exit 1
    fi

    # Detect HW
    detect_hardware
    echo "Target: $CFG_DIR"
    echo "HW:     $CFG_HW"
    
    STATS_START=$SECONDS
    TOTAL_BYTES_SAVED=0
    
    # HTML Header
    local r_path="$CFG_DIR/vico_report.html"
    if [ "$CFG_HTML" == "true" ]; then
        # Start report with refresh
        cat <<EOF > "$r_path"
<!DOCTYPE html><html><head><meta http-equiv="refresh" content="5">
<style>body{font-family:sans-serif;padding:20px;background:#f0f0f0}table{width:100%;background:#fff;border-collapse:collapse}th,td{padding:10px;border:1px solid #ddd}th{background:#333;color:#fff}.good{color:green}.bad{color:red}</style>
</head><body><h2>ViCo Report</h2><p>$(date)</p><table>
<tr><th>File</th><th>Old</th><th>New</th><th>Red.</th><th>FPS</th><th>Stat</th></tr>
EOF
    fi

    # Find files
    local find_args=("$CFG_DIR" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" -o -iname "*.avi" \))
    if [ "$CFG_RECURSIVE" == "false" ]; then find_args+=(-maxdepth 1); fi

    # Loop safely using FD 9
    while IFS= read -r -d '' -u 9 f; do
        process_video_file "$f"
        
        # Update HTML incrementally
        if [ "$CFG_HTML" == "true" ] && [ ${#REPORT_DATA[@]} -gt 0 ]; then
            # Append latest row to file
            echo "${REPORT_DATA[-1]}" >> "$r_path"
        fi
    done 9< <(find "${find_args[@]}" -print0)

    # Finalize HTML
    if [ "$CFG_HTML" == "true" ]; then
        local mb=$(awk "BEGIN {printf \"%.2f\", $TOTAL_BYTES_SAVED / 1048576}")
        local gb=$(awk "BEGIN {printf \"%.2f\", $TOTAL_BYTES_SAVED / 1073741824}")
        echo "</table><div style='margin-top:20px;padding:10px;background:#e0e0e0'><b>Total Saved:</b> $mb MB ($gb GB)</div></body></html>" >> "$r_path"
        # Remove refresh
        sed -i '/http-equiv="refresh"/d' "$r_path"
    fi

    local duration=$((SECONDS - STATS_START))
    local h=$((duration/3600))
    local m=$(( (duration%3600)/60 ))
    local s=$((duration%60))
    
    echo ""
    echo "========================================"
    echo " Finished."
    printf " Files:    %d\n" "$STATS_TOTAL"
    printf " Time:     %02d:%02d:%02d\n" $h $m $s
    if [ "$CFG_HTML" == "true" ]; then echo " Report:   $r_path"; fi
    echo "========================================"
}

# --- 8. ENTRY POINT ---

check_deps

# Arg Parsing
FORCE_MENU=false
if [ $# -eq 0 ]; then FORCE_MENU=true; fi

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        --menu) FORCE_MENU=true; shift ;;
        -r|--res) CFG_RES="$2"; shift 2 ;;
        --no-hw) CFG_HW="cpu"; shift ;;
        --downmix) CFG_AUDIO="downmix"; shift ;;
        --no-recursive) CFG_RECURSIVE="false"; shift ;;
        --html) CFG_HTML="true"; shift ;;
        -k|--keep) CFG_OVERWRITE="false"; shift ;;
        -s|--subs) CFG_SUBS="true"; shift ;;
        *) 
           if [ -d "$1" ]; then CFG_DIR=$(realpath "$1"); shift
           elif [[ "$1" =~ ^[0-9]+$ ]]; then CFG_CRF="$1"; shift
           else shift; fi 
           ;;
    esac
done

if [ "$FORCE_MENU" == "true" ]; then
    show_menu
fi

run_batch