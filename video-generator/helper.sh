#!/bin/bash

EPOCH=$(date '+%s')
CWD=$(pwd)
cachedir=".lofigenerator"
FFMPEG='ffmpeg -hide_banner -loglevel error -threads 4'

validate-inputs () {
    if [[ -n "$PLAYLIST_PATH" ]]; then
        AUDIOS_PATH="${AUDIOS_PATH-${PLAYLIST_PATH}/audio}"
        BG_FILE="${BG_FILE-${PLAYLIST_PATH}/bg.jpg}"
        OUTPUT_FILE="${OUTPUT_FILE-${PLAYLIST_PATH}/video/${EPOCH}.mp4}"
    fi

    if [[ -z "$AUDIOS_PATH" ]]; then
        echo "Command failed: AUDIOS_PATH unset"
        exit 1
    elif [[ -z "$BG_FILE" ]]; then
        echo "Command failed: BG_FILE unset"
        exit 1
    elif [[ -z "$OUTPUT_FILE" ]]; then
        echo "Command failed: OUTPUT_FILE unset"
        exit 1
    elif [[ -z "$REGULAR_FONT" ]]; then
        echo "Command failed: REGULAR_FONT unset"
        exit 1
    elif [[ -z "$BOLD_FONT" ]]; then
        echo "Command failed: BOLD_FONT unset"
        exit 1
    fi

    mkdir -p "$AUDIOS_PATH"
    mkdir -p "$(dirname $OUTPUT_FILE)"
}

setuptmp () {
    EPOCH=$(date +%s)
    TMP="$(dirname $OUTPUT_FILE)/tmp-$EPOCH"
    mkdir -p "$TMP"
}

cleanuptmp () {
    find $(dirname $OUTPUT_FILE) -path '*/tmp-*' -delete
    exit
}

list-audiofiles () {
    # add files to array
    files=()
    while IFS='' read -r file || [[ -n "$file" ]]; do
        files+=("$file")
    done <<< "$(find "$AUDIOS_PATH" -name '*.flac' ! -path ""*/${cachedir}/*"")"
}

compute-audiosha () {
    audiosha="$EPOCH"
    if [[ "${#files[@]}" -gt 0 ]]; then
        audiosha=$(shasum ${files[@]} | shasum | sed -nE 's/([a-zA-Z0-9]+) .*/\1/p')
    fi
}

download-playlist-if-needed () {
    if [[ -z "$PLAYLIST_URL" ]]; then
        return
    fi

    echo "Downloading playlist..."
    cd "$AUDIOS_PATH"
    spotdl --output "{list-position}.{output-ext}" --threads 4 --format flac --save-file "$AUDIOS_PATH/save.spotdl" sync "$PLAYLIST_URL" || exit 1
    cd "$CWD"
}

setup-audiocache () {
    list-audiofiles
    compute-audiosha || exit 1
    echo "Audio files hash: $audiosha"

    audiocache="$AUDIOS_PATH/$cachedir/$audiosha"
    audiofile="$audiocache/combined.flac"

    # Create cache dir if it does not exist
    mkdir -p "$audiocache"

    # Cleanup previous caches from non-matching hashes
    find "$AUDIOS_PATH/$cachedir" -path "$AUDIOS_PATH/$cachedir/*" ! -path "*/$audiosha*" -delete
}

combine-audiofiles () {
    durationfile="$audiocache/duration.txt"

    if [[ -f "$audiofile" && -f "$durationfile" ]]; then
        echo "Using cached result"
        DURATION=$(cat "$durationfile")
        return
    else
        echo -n "Combining ${#files[@]} audio files... "
        SECONDS=0
        cd "$audiocache"

        sox $(printf "%q " "${files[@]}") "${audiofile}"

        DURATION=$(sox "${audiofile}" -n stat 2>&1 \
            | sed -nE 's,Length \(seconds\): +([0-9.]+),\1,p')

        cd "$CWD"

        echo "done. took ${SECONDS} seconds"
    fi

    echo "$DURATION" > "$durationfile"

    DURATION_ROUNDED_UP=$(printf '%.0f' "$DURATION")
    DURATION_ROUNDED_UP=$((DURATION_ROUNDED_UP+1))

    MINS=$((DURATION_ROUNDED_UP/60))
    MINS=$(printf '%.0f' "$MINS")
    HOURS=$(( MINS / 60 ))
    HOURS=$(printf '%.1f' "$HOURS")
    echo "Total duration: ${HOURS}h"
}

parse-track-details () {
    if [[ -f "$audiocache/track-details.json" ]]; then
        echo "Using cached details"
        return
    fi

    rm -rf "$audiocache/albumart" || true
    mkdir -p "$audiocache/albumart"

    SECONDS=0
    json_details='[]'
    order=0
    spaces=''
    for file in "${files[@]}"; do
        albumart="$audiocache/albumart/$order.jpg"
        file_details=$(ffmpeg -i "$file" -an -c:v copy "$albumart" 2>&1)
        title=$(printf '%s' "$file_details" | sed -nE 's/ +title +: +(.+)/\1/p' | head -1)
        artist=$(printf '%s' "$file_details" | sed -nE 's/ +artist +: +(.+)/\1/p' | head -1)
        duration=$(printf '%s' "$file_details" | sed -nE 's/ +Duration: ([:.0-9]+),.+/\1/p' | head -1)

        file_details=$(jq -rc --null-input \
            --argjson order "$order" \
            --arg title "$title" \
            --arg artist "$artist" \
            --arg duration "$duration" \
            --arg albumart "$albumart" \
            '{
                order: $order,
                title: $title,
                artist: $artist,
                duration: $duration,
                albumart: $albumart
            }')

        json_details=$(jq -rc --null-input \
            --argjson all "$json_details" \
            --argjson next "$file_details" \
            '$all | . += [$next]')

        order=$(( order + 1 ))

        printf '%s\rParsing metadata: %d/%d songs' "$spaces" $(( 10#$order )) "${#files[@]}"
    done

    echo "\ndone. took ${SECONDS}s"

    printf '%s\n' "$json_details" > "$audiocache/track-details.json"
}

generate-background () {
    padding="                  "
    SECONDS=0
    mkdir "$TMP/tracks"

    generate-track-videos

    $FFMPEG \
        -safe 0 \
        -f concat \
        -i "$TMP/track-files.txt" \
        -c copy \
        -y "$TMP/video.mp4"

    rm -rf "$TMP/tracks"

    echo "done. took ${SECONDS} seconds"
}

generate-track-videos () {
    # create a starter video, looping background image for 0.1s
    $FFMPEG \
        -loop 1 \
        -i "$BG_FILE" \
        -c:v libx264 \
        -pix_fmt yuv420p \
        -tune stillimage \
        -t 0.1 \
        -vf 'scale=1920:1080,fps=30' \
        "$TMP/pre-video.mp4"

    for encodedRow in $(cat "$audiocache/track-details.json" | jq -r '.[] | @base64'); do
        track=$(printf '%s\n' "$encodedRow" | base64 --decode)
        title=$(printf '%s\n' "$track" | jq -rc '.title')
        title=$(printf '%q' "$title")
        artist=$(printf '%s\n' "$track" | jq -rc '.artist')
        artist=$(printf '%q' "$artist")
        albumart=$(printf '%s\n' "$track" | jq -rc '.albumart')
        albumart=$(printf '%q' "$albumart")
        order=$(printf '%s\n' "$track" | jq -rc '.order')
        order=$(printf '%05d' "$order")
        duration=$(printf '%s\n' "$track" | jq -rc '.duration')

        drawtext="drawtext=text=\'$title\'"
        drawtext="${drawtext}:fontcolor='white'"
        drawtext="${drawtext}:fontfile=\'$BOLD_FONT\'"
        drawtext="${drawtext}:fontsize=32"
        drawtext="${drawtext}:x=120"
        drawtext="${drawtext}:y=40"
        drawtext="${drawtext},drawtext=text=\'by $artist\'"
        drawtext="${drawtext}:fontcolor='white'"
        drawtext="${drawtext}:fontfile=\'$REGULAR_FONT\'"
        drawtext="${drawtext}:fontsize=24"
        drawtext="${drawtext}:x=120"
        drawtext="${drawtext}:y=40+40"

        $FFMPEG \
            -re \
            -i "$TMP/pre-video.mp4" \
            -i "$albumart" \
            -filter_complex "[1:v]scale=60:60 [ovrl], [0:v][ovrl] overlay=40:40, ${drawtext}" \
            -c:v libx264 -c:a copy \
            -tune stillimage \
            -pix_fmt yuv420p \
            -y "$TMP/tracks/pre-$order.mp4"

        $FFMPEG \
            -stream_loop -1 \
            -t "$duration" \
            -i "$TMP/tracks/pre-$order.mp4" \
            -tune stillimage \
            -c copy \
            -y "$TMP/tracks/$order.mp4"

        printf '                    \rGenerating track videos: %d/%d songs %s' $(( 10#$order + 1 )) "${#files[@]}"
        echo "file '$TMP/tracks/$order.mp4'" >> "$TMP/track-files.txt"
    done
}

add-audio () {
    SECONDS=0
    $FFMPEG \
        -i "$TMP/video.mp4" -i "${audiofile}" \
        -c:v copy \
        -map 0:v -map 1:a \
        -y "$OUTPUT_FILE"

    MINS=$(( SECONDS / 60 ))
    MINS=$(printf '%.1f' "$MINS")
    echo "done. took ${MINS}m"
}
