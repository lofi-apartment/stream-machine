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

spotdl-details () {
    cat "$AUDIOS_PATH/save.spotdl" | jq -rc '.songs | sort_by(.list_position)'
}

validate-inputs () {
    if [[ -n "$PLAYLIST_PATH" ]]; then
        PLAYLIST_DATA=$(cat "$PLAYLIST_PATH/playlist.yml")
        TEXT_COLOR=$(printf '%s' "$PLAYLIST_DATA" | yq -r '.text_color')
        if [[ -z "$TEXT_COLOR" ]] || [[ "$TEXT_COLOR" == "null" ]]; then
            TEXT_COLOR="white"
        fi

        PLAYLIST_ID=$(printf '%s' "$PLAYLIST_DATA" | yq -r '.playlist_id')
        if [[ -n "$PLAYLIST_ID" ]] && [[ "$PLAYLIST_ID" != "null" ]]; then
            playlist_url="https://open.spotify.com/playlist/${PLAYLIST_ID}"
            PLAYLIST_URL=${PLAYLIST_URL-$playlist_url}
        fi

        AUDIOS_PATH="${AUDIOS_PATH-${PLAYLIST_PATH}/audio}"

        bg_file=$(printf '%s' "$PLAYLIST_DATA" | yq -r '.bg_file')
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

parse-options () {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-sync)
                SKIP_SYNC=true
                shift
                ;;
            -*|--*)
                echo "Unknown option $1"
                exit 1
                ;;
            *)
                shift
                ;;
        esac
    done
}

setuptmp () {
    TMP="$OUTPUT_DIR/$EPOCH/tmp"
    mkdir -p "$TMP"
}

cleanuptmp () {
    find "$TMP" -delete
    exit
}

cleanup_videos () {
    video_dirs=($(ls -td $OUTPUT_DIR/*/))
    for dir in "${video_dirs[@]:2}"; do
        test -f "$dir/.lock" && continue
        rm -rf "$dir"
    done
}

download-playlist-if-needed () {
    if [[ "$SKIP_SYNC" = "true" ]]; then
        echo 'detected `--skip-sync` flag, skipping playlist sync'
        return
    elif [[ -z "$PLAYLIST_URL" ]]; then
        echo 'No `PLAYLIST_URL` specified, skipping playlist sync'
        return
    fi

    echo "Downloading playlist..."
    cd "$AUDIOS_PATH"
    spotdl \
        --output "track_{isrc}.{output-ext}" \
        --format wav \
        --save-file "$AUDIOS_PATH/save.spotdl" \
        sync "$PLAYLIST_URL" \
        --audio youtube-music youtube \
        || exit 1
    cd "$CWD"
}

setup-audiocache () {
    audiocache="$AUDIOS_PATH/$cachedir"
    mkdir -p "$audiocache"
}

list-audiofiles () {
    # add files to array
    files=()
    while IFS='' read -r file || [[ -n "$file" ]]; do
        files+=("$file")
    done <<< "$(find "$AUDIOS_PATH" -name '*.wav' ! -path */${cachedir}/*)"
}

parse-track-details () {
    SECONDS=0

    # parse durations into a file
    json_details='[]'
    parsed=0
    for file in "${files[@]}"; do
        isrc=$(basename -s ".wav" "$file")
        isrc=${isrc#track_}

        if [[ -z "$isrc" ]]; then
            echo "Failed to parse ISRC from $file"
            exit 1
        fi

        spotdl_song=$(spotdl-details | jq -rc --arg isrc "$isrc" 'map(select(.isrc == $isrc)) | first')
        if [[ -z "$spotdl_song" ]] || [[ "$spotdl_song" = "null" ]]; then
            echo "Failed to detect song details"
            exit 1
        fi

        duration_s=$(printf '%s' "$spotdl_song" | jq -rc '.duration')
        duration_ms=$(( duration_s * 1000 ))

        json_details=$(jq -nrc \
            --argjson all "$json_details" \
            --argjson song "$spotdl_song" \
            --arg file "$file" \
            --argjson duration_ms "$duration_ms" \
            '$all | . += [{
                file : $file,
                position: $song.list_position,
                title: $song.name,
                artist: $song.artist,
                coverurl: $song.cover_url,
                duration_ms: $duration_ms
            }] | sort_by(.position)')

        parsed=$(( parsed + 1 ))

        printf '\r%s\rParsing metadata: %d/%d songs ' "$(blankline)" $(( 10#$parsed )) "${#files[@]}"
    done

    printf '%s' "$json_details" | jq '.' > "$audiocache/track-details.json"

    # group songs into chapters and add details to file


    printf '\r%s\rParsing metadata: grouping songs into chapters ' "$(blankline)"
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

    printf '%s\n' "$chapters" | jq '.' > "$audiocache/chapter-details.json"

    printf '\r%s\r%s\n' "$(blankline)" "Parsing metadata: done. took ${SECONDS}s"
}

generate-background () {
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
    tracks_count=$(jq -rc 'length' "$audiocache/track-details.json")
    total_chapters=$(cat "$audiocache/chapter-details.json" | jq -rc '. | length')
    chapter_count=1
    track_count=0
    for encodedChapter in $(cat "$audiocache/chapter-details.json" | jq -r '.[] | @base64'); do
        chapter=$(printf '%s\n' "$encodedChapter" | base64 --decode)
        chapter_dir="$TMP/chapters/$chapter_count"
        mkdir -p "$chapter_dir"
        mkdir -p "$chapter_dir/tracks"
        echo "" > "$TMP/chapter-files.txt"
        for file in $(echo "$chapter" | jq -rc '.files[]'); do
            track_count=$(( track_count + 1 ))
            success_percent=$(printf 'scale=1;%d*100/%d' "$(( track_count - 1 ))" "$tracks_count" | bc)
            progresstext=$(printf '\r%s\rTrack %d of %d (chapter %d of %d) (%s%%)' \
                "$(blankline)" "$track_count" "$tracks_count" "$chapter_count" "$total_chapters" "$success_percent")

            track=$(printf '%s' "$track_details" | jq --arg file "$file" '. | map(select(.file == $file)) | first')

            if [[ -z "$track" ]] || [[ "$track" == "null" ]]; then
                printf '%s: Failed to determine details for track %s\n' "$progresstext" "$file"
                exit 1
            fi

            printf '%s: processing ' "$progresstext"

            title=$(printf '%s\n' "$track" | jq -rc '.title')
            artist=$(printf '%s\n' "$track" | jq -rc '.artist')
            cover_url=$(printf '%s\n' "$track" | jq -rc '.coverurl')

            order=$(printf '%s\n' "$track" | jq -rc '.position')
            order=$(printf '%05d' "$order")
            file=$(printf '%s\n' "$track" | jq -rc '.file')
            file=$(printf '%q' "$file")

            # parse duration
            printf '%s: parsing duration ' "$progresstext"
            duration=$(ffprobe -i "$file" 2>&1 | sed -nE 's/ +Duration: ([:.0-9]+),.+/\1/p' | head -1)

            # download cover image
            printf '%s: downloading album art ' "$progresstext"
            curl -s "${cover_url}" -o "$chapter_dir/tracks/cover-$order.png"

            # generate text
            printf '%s: generating overlay ' "$progresstext"
            python3 "$(dirname "${BASH_SOURCE[0]}")/textimg.py" \
                -t "${title}" \
                -a "${artist}" \
                -f "$REGULAR_FONT" \
                -c "$TEXT_COLOR" \
                -o "$chapter_dir/tracks/txt-$order.png"

            # encode the starter tile
            printf '%s: generating background ' "$progresstext"
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
            printf '%s: adding track audio ' "$progresstext"
            echo "file $chapter_dir/tracks/$order.mp4" >> "$TMP/chapter-files.txt"
            $FFMPEG \
                -stream_loop -1 \
                -t "$duration" \
                -i "$chapter_dir/tracks/pre-$order.mp4" \
                -i "$file" \
                -tune stillimage \
                -c copy \
                -map 0:v -map 1:a \
                -y "$chapter_dir/tracks/$order.mp4"

            printf '%s: done ' "$progresstext"
            echo "file '$chapter_dir/tracks/$order.mp4'" >> "$TMP/track-files.txt"
        done

        chapter_tracks_count=$(printf '%s' "$chapter" | jq -rc '.files | length')
        printf '\r%s\rChapter %d: combining %d tracks ' "$(blankline)" "$chapter_tracks_count" "$chapter_count"

        # combine all track files into the chapter file
        chapter_file=$(printf '%s/%s/chapter_%05d.mp4' "$OUTPUT_DIR" "$EPOCH" "$chapter_count")
        $FFMPEG \
            -safe 0 \
            -f concat \
            -i "$TMP/chapter-files.txt" \
            -c copy \
            -tune stillimage \
            -y "$chapter_file"

        printf '\r%s\rChapter %d saved to %s                         \n' "$(blankline)" "$chapter_count" "$chapter_file"

        rm -rf "$chapter_dir"
        chapter_count=$(( chapter_count + 1 ))
    done

    exit 0
}
