#!/usr/bin/bash
set -e

is_installed() {
    if ! command -v $1 &> /dev/null; then
        echo "Error: '$1' is not installed." >&2
        echo "$2" >&2
        exit 1
    fi
}

is_installed ffmpeg "Use 'apt install ffmpeg' (or similar)"
is_installed ffprobe "Use 'apt install ffmpeg' (or similar)"
is_installed dovi_tool "See https://github.com/quietvoid/dovi_tool"
is_installed hdr10plus_tool "See https://github.com/quietvoid/hdr10plus_tool"
is_installed jq "Use 'apt install jq' (or similar)"
is_installed mkvmerge "Use 'apt install mkvtoolnix' (or similar)"

encode_single_file() {
    local src=$1
    local extra=$2

    local dst="${src%.*}.rnc.mkv"
    if [ -f "$dst" ]; then
        return 0
    fi

    # query file metadata
    local meta=$(ffprobe -v error -select_streams v:0 -show_frames -read_intervals "%+#1" \
        -show_entries "stream=width,height,color_transfer:stream_side_data=side_data_type:frame=side_data_list:stream_side_data_list" \
        -print_format json "$src")

    # common stuff first
    local args=""
    args+=" -loglevel error -stats"     # reduce noise
    args+=" -map 0:v:0"                 # keep only first video stream
    args+=" -map 0:a"                   # keep all audio
    args+=" -map 0:a"                   # keep all subs
    args+=" -c:v libx265"

    # basic quality
    local width=$(echo "$meta" | jq -r '.streams[0].width')
    if (( $width < 3000 )); then
        # non-4K
        if [[ "${src,,}" == *".hq."* ]]; then
            echo "- Non-4K HQ"
            args+=" -crf 22 -preset slow"
        elif [[ "${src,,}" == *"remux"* ]]; then
            echo "- Non-4K Remux"
            args+=" -crf 23 -preset medium"
        else
            echo "- Non-4K"
            args+=" -crf 23 -preset fast"
        fi
    else
        # 4K
        if [[ "${src,,}" == *".hq."* ]]; then
            echo "- 4K HQ"
            args+=" -crf 20 -preset slow"
        elif [[ "${src,,}" == *"remux"* ]]; then
            echo "- 4K Remux"
            args+=" -crf 22 -preset slow"
        else
            echo "- 4K"
            args+=" -crf 22 -preset medium"
        fi
    fi

    # Other defaults
    args+=" -pix_fmt yuv420p10le"       # 10-bit encoding
    args+=" -max_muxing_queue_size 4096"
 
    # Color formats
    local color_transfer=$(echo "$meta" | jq -r '.streams[0].color_transfer')
    local side_data_type=$(echo "$meta" | jq -r '.frames[0].side_data_list')
 
    local x265="aq-mode=3"
    local dv_rpu=""

    # HDR, HLG or SDR?
    if [[ $color_transfer == "smpte2084" ]]; then
        # HDR10 etc
        x265+=":hdr10=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020"

        local hdr10plus=""
        if [[ $side_data_type =~ 2094|HDR10\+ ]]; then
            # HDR10+
            echo "- HDR10+"

            # extract dynamic metadata to make sure
            hdr10plus="${src// /_}.hdr10plus"
            if [[ -f "$hdr10plus" ]] || ffmpeg -i "$src" -c:v copy -bsf:v hevc_mp4toannexb -f hevc - 2>/dev/null | hdr10plus_tool extract -o "$hdr10plus" - >/dev/null 2>&1; then
                # actually HDR10+
                echo "- extracted dynamic metadata"
                x265+=":dhdr10-info=${hdr10plus}"
            else
                # dynamic metadata is missing, treat as HDR10
                echo "- no dynamic metadata found, treating as HDR10"
            fi
        else
            # HDR10
            echo "- HDR10"
        fi

        # grab master-display, max-cll values
        local master_display=$(echo "$meta" | jq -r '.frames[0].side_data_list[] | select(.side_data_type=="Mastering display metadata") | 
            "G(\(.green_x | split("/")[0]),\(.green_y | split("/")[0]))B(\(.blue_x | split("/")[0]),\(.blue_y | split("/")[0]))R(\(.red_x | split("/")[0]),\(.red_y | split("/")[0]))WP(\(.white_point_x | split("/")[0]),\(.white_point_y | split("/")[0]))L(\(.max_luminance | split("/")[0]),\(.min_luminance | split("/")[0]))"')
        local max_cll=$(echo "$meta" | jq -r '.frames[0].side_data_list[] | select(.side_data_type=="Content light level metadata") | 
        "\(.max_content),\(.max_average)"')
        x265+=":master-display=${master_display}:max-cll=${max_cll}"

        # Dolby Vision?
        local dv_info=$(echo "$meta" | \
            jq -r '.streams[0].side_data_list[]? | select(.side_data_type == "DOVI configuration record") | "\(.dv_profile).\(.dv_version)"')
        if [[ $dv_info ]]; then
            echo "- Dolby Vision"
            dv_rpu="${src// /_}.rpu"
            [[ -f "$dv_rpu" ]] || dovi_tool -m 2 extract-rpu -i "$src" -o "$dv_rpu"
        fi

        # side_data=dv_profile:dv_level:dv_bl_signal_compatibility_id
    elif [[ $color_transfer == "arib-std-b67" ]]; then
        # HLG
        echo "- HLG"
        x265+=":colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:range=limited"
        args+=" -color_range tv -colorspace bt2020nc -color_primaries bt2020 -color_trc arib-std-b67"
    else
        # SDR
        echo "- SDR"
        x265+=""
    fi

    # 'grain' tune?
    if [[ "${src,,}" == *".grain."* ]]; then
        echo "- Grain"
        x265+=":tune=grain"
        args+=" -maxrate 25M -bufsize 50M"  # relaxed cap for grain
    else
        args+=" -maxrate 18M -bufsize 30M"  # cap encoding sizes
    fi

    # remaining arguments
    args+=" -x265-params \"${x265}\""
    args+=" -c:a copy -c:s copy"        # copy audio/subtitles
    args+=" -map_metadata 0"            # carry over global metadata
    args+=" -metadata title=\"\""       # clear embedded title
    args+=" -dn "                       # skip data streams
 
    # now run the conversion
    if [[ -z "$dv_rpu" ]]; then
        ffmpeg -i "$src" $args "$dst"
    else
        # Dolby Vision path...
        local tmp="${dst%.*.tmp.mkv}"
        ffmpeg -i "$src" $args "$tmp"

        ffmpeg -i "$tmp" -c:v copy -bsf:v hevc_mp4toannexb "${tmp}.1.hevc"
        dovi_tool inject-rpu "${tmp}.1.hevc" --rpu-in "$dv_rpu" -o "${tmp}.2.hevc"
        mkvmerge -o "$dst" -D \( "$tmp" \) "${tmp}.2.hevc"

        rm "${tmp}.1.hevc"
        rm "${tmp}.2.hevc"
        rm "${tmp}"
        rm "${dv_rpu}"
    fi
 
    # cleanup
    rm -f "$hdr10plus"
}

encode_folder() {
    local pattern=$1
    local extra=$2
    
    for file in $pattern; do
        [ -e "$file" ] || continue

        echo "=== $file"
        encode_single_file "$file" $extra
    done
}

encode_folder "*.ts" "-vf yadif"
encode_folder "*.mkv"
encode_folder "*.mp4"
encode_folder "*.avi"
encode_folder "*.m2ts"
