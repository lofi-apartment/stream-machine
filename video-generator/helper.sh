#!/bin/bash

if [[ "$DEBUG" = "true" ]]; then
    set -x
fi

source "$(dirname "${BASH_SOURCE[0]}")/../.lib.sh"

EPOCH=$(date '+%Y-%m-%d-%H-%M')
CWD=$(pwd)
cachedir=".lofigenerator"
FFMPEG='ffmpeg -hide_banner -loglevel error'

validate-requirements () {
    if ! yq --version >/dev/null; then
        echo "yq not installed"
        exit 1
    elif ! spotdl --version >/dev/null; then
        echo "spotdl not installed"
        exit 1
    elif ! ffmpeg -version >/dev/null 2>&1; then
        echo "ffmpeg not installed"
        exit 1
    fi
}

validate-inputs () {
    if [[ -n "$PLAYLIST_PATH" ]]; then
        PLAYLIST_DATA=$(cat "$PLAYLIST_PATH/playlist.yml")
        TEXT_COLOR=$(printf '%s' "$PLAYLIST_DATA" | yq '.text_color')
        if [[ -z "$TEXT_COLOR" ]] || [[ "$TEXT_COLOR" == "null" ]]; then
            TEXT_COLOR="white"
        fi

        PLAYLIST_ID=$(printf '%s' "$PLAYLIST_DATA" | yq '.playlist_id')
        if [[ -n "$PLAYLIST_ID" ]] && [[ "$PLAYLIST_ID" != "null" ]]; then
            playlist_url="https://open.spotify.com/playlist/${PLAYLIST_ID}"
            PLAYLIST_URL="${PLAYLIST_URL-$playlist_url}"
        fi

        AUDIOS_PATH="${AUDIOS_PATH-${PLAYLIST_PATH}/audio}"

        bg_file=$(printf '%s' "$PLAYLIST_DATA" | yq '.bg_file')
        BG_FILE="${PLAYLIST_PATH}/${bg_file}"

        OUTPUT_DIR="${OUTPUT_DIR-${PLAYLIST_PATH}/video}"
    fi

    TEXT_COLOR="${TEXT_COLOR-white}"

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

    mkdir -p "$AUDIOS_PATH"
}

setuptmp () {
    TMP="$OUTPUT_DIR/$EPOCH/tmp"
    mkdir -p "$TMP"
}

cleanuptmp () {
    find "$TMP" -delete
    exit
}

compute-audiosha () {
    audiosha=$(shasum $AUDIOS_PATH/*.wav | shasum | sed -nE 's/([a-zA-Z0-9]+) .*/\1/p')
}

download-playlist-if-needed () {
    if [[ -z "$PLAYLIST_URL" ]]; then
        return
    fi

    echo "Downloading playlist..."
    cd "$AUDIOS_PATH"
    spotdl \
        --output "{list-position}_{isrc}.{output-ext}" \
        --threads 2 \
        --format wav \
        --save-file "$AUDIOS_PATH/save.spotdl" \
        sync "$PLAYLIST_URL" \
        --audio youtube-music soundcloud youtube \
        || exit 1
    cd "$CWD"
}

setup-audiocache () {
    compute-audiosha || exit 1
    echo "Audio files hash: $audiosha"

    audiocache="$AUDIOS_PATH/$cachedir/$audiosha"
    audiofile="$audiocache/combined.wav"

    # Create cache dir if it does not exist
    mkdir -p "$audiocache"

    # Cleanup previous caches from non-matching hashes
    find "$AUDIOS_PATH/$cachedir" -path "$AUDIOS_PATH/$cachedir/*" ! -path "*/$audiosha*" -delete
}

list-audiofiles () {
    # add files to array
    files=()
    while IFS='' read -r file || [[ -n "$file" ]]; do
        files+=("$file")
    done <<< "$(find "$AUDIOS_PATH" -name '*.wav' ! -path */${cachedir}/*)"
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

    SECONDS=0

    # parse durations into a file
    json_details='[]'
    order=0
    for file in "${files[@]}"; do
        isrc="${file##*_}"
        isrc="${isrc%.*}"

        if [[ -z "$isrc" ]]; then
            echo "Failed to parse ISRC from $file"
            exit 1
        fi

        spotdl_details=$(cat "$AUDIOS_PATH/save.spotdl" | jq --arg isrc "$isrc" -rc '.songs | map(select(.isrc == $isrc)) | first')
        title=$(printf '%s' "$spotdl_details" | jq -rc '.name')
        artist=$(printf '%s' "$spotdl_details" | jq -rc '.artist')
        cover_url=$(printf '%s' "${spotdl_details}" | jq -rc '.cover_url')

        file_details=$(ffprobe -i "$file" 2>&1)
        duration_ff=$(printf '%s' "$file_details" | sed -nE 's/ +Duration: ([:.0-9]+),.+/\1/p' | head -1)
        duration_ms=$(parse_duration "$duration_ff")

        file_details=$(jq -rc --null-input \
            --arg file "$file" \
            --argjson order "$order" \
            --arg title "$title" \
            --arg artist "$artist" \
            --arg coverurl "$cover_url" \
            --arg duration "$duration_ff" \
            --arg duration_ms "$duration_ms" \
            '{
                file :$file,
                order: $order,
                title: $title,
                artist: $artist,
                coverurl: $coverurl,
                duration: $duration,
                duration_ms: $duration_ms
            }')

        json_details=$(jq -rc --null-input \
            --argjson all "$json_details" \
            --argjson next "$file_details" \
            '$all | . += [$next]')

        order=$(( order + 1 ))

        printf '\rParsing metadata: %d/%d songs %s' $(( 10#$order )) "${#files[@]}" '             '
    done

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
        -c:a copy \
        -pix_fmt yuv420p \
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
            artist=$(printf '%s\n' "$track" | jq -rc '.artist')
            cover_url=$(printf '%s\n' "$track" | jq -rc '.coverurl')

            order=$(printf '%s\n' "$track" | jq -rc '.order')
            order=$(printf '%05d' "$order")
            file=$(printf '%s\n' "$track" | jq -rc '.file')
            file=$(printf '%q' "$file")
            duration=$(printf '%s\n' "$track" | jq -rc '.duration')

            # download cover image
            curl -s "${cover_url}" -o "$chapter_dir/tracks/cover-$order.png"

            # generate text
            python3 "$(dirname "${BASH_SOURCE[0]}")/textimg.py" \
                -t "${title}" \
                -a "${artist}" \
                -f "$REGULAR_FONT" \
                -c "$TEXT_COLOR" \
                -o "$chapter_dir/tracks/txt-$order.png"

            # encode the starter tile
            $FFMPEG \
                -re \
                -i "$TMP/pre-video.mp4" \
                -i "$chapter_dir/tracks/txt-$order.png" \
                -i "$chapter_dir/tracks/cover-$order.png" \
                -c:v libx264 -c:a copy \
                -tune stillimage \
                -pix_fmt yuv420p \
                -filter_complex \
                    '[1:v]scale=w=-1:h=80 [txt];
                     [2:v]scale=w=-1:h=80 [cvr];
                     [0:v][cvr] overlay=40:40 [withcvr];
                     [withcvr][txt] overlay=135:45' \
                -y "$chapter_dir/tracks/pre-$order.mp4"

            # loop text tile to full duration, using stream copy
            # also add audio at this point
            echo "file $chapter_dir/tracks/$order.mp4" >> "$TMP/chapter-files.txt"
            $FFMPEG \
                -stream_loop -1 \
                -t "$duration" \
                -i "$chapter_dir/tracks/pre-$order.mp4" \
                -i "$file" \
                -tune stillimage \
                -c:v copy -c:a aac \
                -map 0:v -map 1:a \
                -y "$chapter_dir/tracks/$order.mp4"

            printf '%s: %d/%d songs %s' "$progresstext" $(( 10#$order + 1 )) "${#files[@]}"
            echo "file '$chapter_dir/tracks/$order.mp4'" >> "$TMP/track-files.txt"
        done

        printf '%s: combining tracks' "$progresstext"

        # combine all track files into the chapter file
        chapter_file=$(printf '%s/%s/chapter_%05d.mp4' "$OUTPUT_DIR" "$EPOCH" "$chapter_count")
        $FFMPEG \
            -safe 0 \
            -f concat \
            -i "$TMP/chapter-files.txt" \
            -c copy \
            -tune stillimage \
            -y "$chapter_file"

        rm -rf "$chapter_dir"
        chapter_count=$(( chapter_count + 1 ))

        printf '%s: complete! Saved to %s                         \n' "$progresstext" "$chapter_file"
    done

    exit 0
}
