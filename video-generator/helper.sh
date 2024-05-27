#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/../.lib.sh"

EPOCH=$(date '+%Y-%m-%d-%H-%M')
CWD=$(pwd)
cachedir=".lofigenerator"
FFMPEG='ffmpeg -hide_banner -loglevel error -threads 4'

validate-inputs () {
    if [[ -n "$PLAYLIST_PATH" ]]; then
        AUDIOS_PATH="${AUDIOS_PATH-${PLAYLIST_PATH}/audio}"
        BG_FILE="${BG_FILE-${PLAYLIST_PATH}/bg.jpg}"
        OUTPUT_DIR="${OUTPUT_DIR-${PLAYLIST_PATH}/video}"
    fi

    if [[ -z "$AUDIOS_PATH" ]]; then
        echo "Command failed: AUDIOS_PATH unset"
        exit 1
    elif [[ -z "$BG_FILE" ]]; then
        echo "Command failed: BG_FILE unset"
        exit 1
    elif [[ -z "$OUTPUT_DIR" ]]; then
        echo "Command failed: OUTPUT_DIR unset"
        exit 1
    elif [[ -z "$REGULAR_FONT" ]]; then
        echo "Command failed: REGULAR_FONT unset"
        exit 1
    elif [[ -z "$BOLD_FONT" ]]; then
        echo "Command failed: BOLD_FONT unset"
        exit 1
    fi

    THIS_OUTPUT_DIR="${OUTPUT_DIR}/${EPOCH}"

    mkdir -p "${AUDIOS_PATH}"
    mkdir -p "${THIS_OUTPUT_DIR}"
}

setuptmp () {
    TMP="${THIS_OUTPUT_DIR}/tmp"
    mkdir -p "$TMP"
}

cleanuptmp () {
    find "$TMP" -delete
    exit
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
    spotdl \
        --output "{list-position}.{output-ext}" \
        --threads 4 \
        --format flac \
        --save-file "$AUDIOS_PATH/save.spotdl" \
        sync "$PLAYLIST_URL" || exit 1
    cd "$CWD"
}

setup-audiocache () {
    list-audiofiles
    compute-audiosha || exit 1
    echo "Audio files hash: $audiosha"

    # Create cache dir if it does not exist
    audiocache="$AUDIOS_PATH/$cachedir/$audiosha"
    mkdir -p "$audiocache"

    # Cleanup previous caches from non-matching hashes
    find "$AUDIOS_PATH/$cachedir" -path "$AUDIOS_PATH/$cachedir/*" ! -path "*/$audiosha*" -delete
}

list-audiofiles () {
    # add files to array
    files=()
    while IFS='' read -r file || [[ -n "$file" ]]; do
        files+=("$file")
    done <<< "$(find "$AUDIOS_PATH" -name '*.flac' ! -path ""*/${cachedir}/*"")"
}

parse-track-details () {
    if [[ -f "$audiocache/track-details.json" ]]; then
        echo "Using cached details"
        return
    fi

    rm -rf "$audiocache/albumart" || true
    mkdir -p "$audiocache/albumart"

    SECONDS=0

    # parse durations into a file
    json_details='[]'
    order=0
    spaces=''
    for file in "${files[@]}"; do
        albumart="$audiocache/albumart/$order.jpg"
        file_details=$(ffmpeg -i "$file" -an -c:v copy "$albumart" 2>&1)
        title=$(printf '%s' "$file_details" | sed -nE 's/ +title +: +(.+)/\1/p' | head -1)
        artist=$(printf '%s' "$file_details" | sed -nE 's/ +artist +: +(.+)/\1/p' | head -1)
        duration_ff=$(printf '%s' "$file_details" | sed -nE 's/ +Duration: ([:.0-9]+),.+/\1/p' | head -1)
        duration_ms=$(parse_duration "$duration_ff")

        file_details=$(jq -rc --null-input \
            --arg file "$file" \
            --argjson order "$order" \
            --arg title "$title" \
            --arg artist "$artist" \
            --arg albumart "$albumart" \
            --arg duration "$duration_ff" \
            --arg duration_ms "$duration_ms" \
            '{
                file :$file,
                order: $order,
                title: $title,
                artist: $artist,
                albumart: $albumart,
                duration: $duration,
                duration_ms: $duration_ms
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

    # group songs into chapters and add details to file
    chapters='[]'
    chapter_max_ms=$(( 30 * ms_per_m ))
    chapter_index=0
    chapter_size_ms=0
    for i in "${!files[@]}"; do
        file_details=$(printf '%s' "$json_details" | jq -rc ".[$i]")
        file_ms=$(printf '%s' "$file_details" | jq -rc '.duration_ms')

        chapter_size_ms=$(( chapter_size_ms + file_ms ))

        if (( chapter_size_ms > chapter_max_ms )); then
            # add file to new chapter
            chapter_size_ms="$file_ms"
            chapter_index=$(( chapter_index + 1 ))
            chapters=$(jq --null-input -rc \
                --argjson all "$chapters" \
                --argjson file "$file_details" \
                '$all | . += [{
                    files: [$file.file],
                }]')
        else
            # add file to existing chapter
            chapters=$(jq --null-input -rc \
                --argjson all "$chapters" \
                --argjson i "$chapter_index" \
                --argjson file "$file_details" \
                '$all | .[$i].files += [$file.file]')
        fi
    done

    printf '%s\n' "$chapters" > "$audiocache/chapter-details.json"

    echo "done. took ${SECONDS}s"
}

generate-background () {
    padding="                  "
    SECONDS=0
    mkdir "$TMP/tracks"

    generate-track-videos

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

    track_details=$(cat "$audiocache/track-details.json")
    total_chapters=$(cat "$audiocache/chapter-details.json" | jq -rc '. | length')
    chapter_count=1
    for encodedChapter in $(cat "$audiocache/chapter-details.json" | jq -r '.[] | @base64'); do
        progresstext=$(printf '                    \r%s' "Chapter ${chapter_count}/${total_chapters}")
        chapter=$(printf '%s\n' "$encodedChapter" | base64 --decode)
        chapter_dir="$TMP/chapters/$chapter_count"
        mkdir -p "$chapter_dir"
        mkdir -p "$chapter_dir/tracks"
        echo "" > "$TMP/chapter-files.txt"
        for file in $(echo "$chapter" | jq -rc '.files[]'); do
            track=$(printf '%s' "$track_details" | jq --arg file "$file" '. | map(select(.file == $file)) | first')
            if [[ -z "$track" ]] || [[ "$track" == "null" ]]; then
                echo "Failed to determine details for track $file"
                exit 1
            fi

            title=$(printf '%s\n' "$track" | jq -rc '.title')
            title=$(printf '%q' "$title")
            artist=$(printf '%s\n' "$track" | jq -rc '.artist')
            artist=$(printf '%q' "$artist")
            albumart=$(printf '%s\n' "$track" | jq -rc '.albumart')
            albumart=$(printf '%q' "$albumart")
            order=$(printf '%s\n' "$track" | jq -rc '.order')
            order=$(printf '%05d' "$order")
            file=$(printf '%s\n' "$track" | jq -rc '.file')
            file=$(printf '%q' "$file")
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

            # encode the starter tile with text over it
            $FFMPEG \
                -re \
                -i "$TMP/pre-video.mp4" \
                -i "$albumart" \
                -filter_complex "[1:v]scale=60:60 [ovrl], [0:v][ovrl] overlay=40:40, ${drawtext}" \
                -c:v libx264 -c:a copy \
                -tune stillimage \
                -pix_fmt yuv420p \
                -y "$chapter_dir/tracks/pre-$order.mp4"

            # loop text tile to full duration, using stream copy
            # also add audio at this point
            echo "file $chapter_dir/tracks/$order.mp4" >> "$TMP/chapter-files.txt"
            $FFMPEG \
                -stream_loop -1 \
                -t "$duration" \
                -i "$chapter_dir/tracks/pre-$order.mp4" \
                -i "$file" \
                -c copy \
                -map 0:v -map 1:a \
                -tune stillimage \
                -y "$chapter_dir/tracks/$order.mp4"

            printf '%s: %d/%d songs %s' "$progresstext" $(( 10#$order + 1 )) "${#files[@]}"
            echo "file '$chapter_dir/tracks/$order.mp4'" >> "$TMP/track-files.txt"
        done

        printf '%s: combining tracks' "$progresstext"

        # combine all track files into the chapter file
        $FFMPEG \
            -safe 0 \
            -f concat \
            -i "$TMP/chapter-files.txt" \
            -tune stillimage \
            -c copy \
            -y $(printf '%s/chapter_%05d.mp4' "$THIS_OUTPUT_DIR" "$chapter_count")

        rm -rf "$chapter_dir"
        chapter_count=$(( chapter_count + 1 ))

        printf '%s: complete!                         \n' "$progresstext"
    done

    exit 0
}
