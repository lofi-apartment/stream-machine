mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(shell dirname $(mkfile_path))

TEST_PLAYLIST_ID=$(shell cat playlists.yml | yq '.playlists.test.playlist_id')
TEST_PLAYLIST_URL="https://open.spotify.com/playlist/$(TEST_PLAYLIST_ID)"

generate-test:
	@PLAYLIST_URL="$(TEST_PLAYLIST_URL)" \
	PLAYLIST_PATH=$(current_dir)/playlists/test \
	$(current_dir)/video-generator/generate.sh
.PHONY: generate-test
