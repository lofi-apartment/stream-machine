# stream-machine

A set of tools for generating simple looping videos from Spotify playlists,
and streaming them live to YouTube.

## Installing

```bash
# Either clone the repo
git clone git@github.com:lofi-apartment/stream-machine.git

# Or add it as a submodule to your project
git submodule add git@github.com:lofi-apartment/stream-machine.git
```

## Using

#### 1. Setup files
Create a folder for your playlist, with an image and a `playlist.yml` file.

Check out [playlists/example](playlists/example) for an example playlist.

#### 2. Run the script!

```bash
source .env # store credentials in a .env file for convenience
source venv/bin/activate # activate python virtual envrionment
PLAYLIST_PATH=<path-to-playlist> ./video-generator/generate.sh
```
