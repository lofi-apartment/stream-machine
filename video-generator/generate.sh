#!/bin/bash

set -e

validate-requirements

CWD=$(pwd)
cachedir=".lofigenerator"
FFMPEG='ffmpeg -hide_banner -loglevel warning'

source "$(dirname "${BASH_SOURCE[0]}")/helper.sh"

validate-inputs

trap cleanuptmp EXIT

setuptmp

download-playlist-if-needed

echo "Checking for changes..."
setup-audiocache

echo "Parsing track data..."
list-audiofiles
parse-track-details

echo "Generating video..."
generate-background
