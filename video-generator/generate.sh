#!/bin/bash

set -e


CWD=$(pwd)
cachedir=".lofigenerator"
FFMPEG='ffmpeg -hide_banner -loglevel warning'

source "$(dirname "${BASH_SOURCE[0]}")/helper.sh"

validate-requirements
validate-inputs
parse-options "$@"

trap cleanuptmp EXIT

setuptmp

header Downloading playlist
setup-audiocache
download-playlist

# header "Checking for changes"

header "Parsing track data"
list-audiofiles
parse-track-details

header "Generating video"
cleanup_videos
generate-background
