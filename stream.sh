#!/bin/bash

if [[ -z "$YOUTUBE_STREAM_KEY" ]]; then
    echo "Missing YOUTUBE_STREAM_KEY"
    exit 1
fi

if [[ -z "$FILE" ]]; then
    echo "Missing FILE"
    exit 1
fi

ms_per_cs=10
ms_per_s=1000
ms_per_m=$(( 60 * ms_per_s ))
ms_per_h=$(( 60 * ms_per_m ))

parse_duration () {
    duration_string=$(ffprobe "$FILE" 2>&1 | sed -nE 's/ +Duration: +([0-9:.]+),.+/\1/p')
    h=$(echo "$duration_string" | sed -nE 's/([0-9]+):([0-9]+):([0-9]+).([0-9]+)/\1/p')
    m=$(echo "$duration_string" | sed -nE 's/([0-9]+):([0-9]+):([0-9]+).([0-9]+)/\2/p')
    s=$(echo "$duration_string" | sed -nE 's/([0-9]+):([0-9]+):([0-9]+).([0-9]+)/\3/p')
    c=$(echo "$duration_string" | sed -nE 's/([0-9]+):([0-9]+):([0-9]+).([0-9]+)/\4/p')

    duration_ms=$(( (c * ms_per_cs) + (s * ms_per_s) + (m * ms_per_m) + (h * ms_per_h) ))
}

parse_now () {
    current_time=$(date '+%T')
    current_h=$(echo "$current_time" | sed -nE 's/([0-9]+):([0-9]+):([0-9]+)/\1/p')
    current_m=$(echo "$current_time" | sed -nE 's/([0-9]+):([0-9]+):([0-9]+)/\2/p')
    current_s=$(echo "$current_time" | sed -nE 's/([0-9]+):([0-9]+):([0-9]+)/\3/p')

    current_ms=$(( (current_s * ms_per_s) + (current_m * ms_per_m) + (current_h * ms_per_h) ))
}

parse_offset () {
    parse_duration
    parse_now

    offset_ms=$(( current_ms % duration_ms ))
    done_ms=0

    offset_h=$(( offset_ms / ms_per_h ))
    done_ms=$(( done_ms + (offset_h * ms_per_h) ))

    offset_m=$(( (offset_ms - done_ms) / ms_per_m ))
    done_ms=$(( done_ms + (offset_m * ms_per_m) ))

    offset_s=$(( (offset_ms - done_ms) / ms_per_s ))
    done_ms=$(( done_ms + (offset_s * ms_per_s) ))

    if [[ "$offset_ms" != "$done_ms" ]]; then
        echo "Error parsing offset: $offset_ms != $done_ms"
        exit 1
    fi

    offset=$(printf '%02d:%02d:%02d' "${offset_h}" "${offset_m}" "${offset_s}")
}

run_stream () {
    parse_offset

    ffmpeg \
        -hide_banner \
        -re \
        -ss "$offset" \
        -i "$FILE" \
        -pix_fmt yuvj420p \
        -x264-params keyint=48:min-keyint=48:scenecut=-1 \
        -b:v 4500k \
        -b:a 128k \
        -ar 44100 \
        -acodec aac \
        -vcodec libx264 \
        -preset ultrafast \
        -tune stillimage \
        -threads 4 \
        -f flv \
        "rtmp://a.rtmp.youtube.com/live2/$YOUTUBE_STREAM_KEY"
}

while run_stream; do :; done
