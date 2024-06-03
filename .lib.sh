#!/bin/bash

ms_per_cs=10
ms_per_s=1000
ms_per_m=$(( 60 * ms_per_s ))
ms_per_h=$(( 60 * ms_per_m ))

lock_dir () {
    lockfile="$1/.lock"
    if ! [[ -d "$1" ]]; then
        echo "Cannot lock non-existent directory: $1"
        exit 1
    elif [[ -f "$lockfile" ]]; then
        echo "Cannot lock directory, lockfile already exists: $lockfile"
        exit 1
    fi

    date > $lockfile
    echo "locked $lockfile"
}

unlock_dir () {
    rm -f "$1/.lock"
    echo "unlocked $1/.lock"
}

parseint() {
    test -n "$1" \
        && printf '%d' "$(( 10#$1 ))" \
        || printf '%d' 0
}

parse_duration () {
    duration_string="$1"
    h=$(echo "$duration_string" | sed -nE 's/([0-9]+):([0-9]+):([0-9]+).([0-9]+)/\1/p')
    h=$(parseint "$h")
    m=$(echo "$duration_string" | sed -nE 's/([0-9]+):([0-9]+):([0-9]+).([0-9]+)/\2/p')
    m=$(parseint "$m")
    s=$(echo "$duration_string" | sed -nE 's/([0-9]+):([0-9]+):([0-9]+).([0-9]+)/\3/p')
    s=$(parseint "$s")
    c=$(echo "$duration_string" | sed -nE 's/([0-9]+):([0-9]+):([0-9]+).([0-9]+)/\4/p')
    c=$(parseint "$c")

    duration_ms=$(( (c * ms_per_cs) + (s * ms_per_s) + (m * ms_per_m) + (h * ms_per_h) ))
    printf '%d' "$duration_ms"
}

duration_from_ms () {
    offset_ms=$(parseint "$1")
    done_ms=0

    offset_h=$(( offset_ms / ms_per_h ))
    done_ms=$(( done_ms + (offset_h * ms_per_h) ))

    offset_m=$(( (offset_ms - done_ms) / ms_per_m ))
    done_ms=$(( done_ms + (offset_m * ms_per_m) ))

    offset_s=$(( (offset_ms - done_ms) / ms_per_s ))
    done_ms=$(( done_ms + (offset_s * ms_per_s) ))

    offset_cs=$(( (offset_ms - done_ms) / ms_per_cs ))

    printf '%02d:%02d:%02d.%02d' "${offset_h}" "${offset_m}" "${offset_s}" "${offset_cs}"
}

blankline () {
    printf ' %.0s' $(seq 1 $(tput cols))
}

divider () {
    printf '_%.0s' $(seq 1 $(tput cols)) | sed -nE 's/_/-/gp'
    echo ""
}

header () {
    test "$called" = true && echo "" || called=true
    divider
    echo "$@"
    divider
}
