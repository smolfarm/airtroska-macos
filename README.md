# Airtroska

A small macOS app that turns an `.mkv` (or any container ffmpeg understands)
into an **AirPlay-friendly MP4** and hands it to a native AVPlayer so you can
send it to an Apple TV — no re-encoding in some other tool, no fiddling with
VLC.

You drop a file in, it probes the streams with `ffprobe`, decides the cheapest
conversion that Apple will actually play, runs `ffmpeg`, and opens the result
in a player with an AirPlay route picker right there.

## Why

Apple TV / AVFoundation is picky about what it will decode, especially over
AirPlay:

- Multichannel AAC, E-AC-3 (DD+), Dolby Atmos, DTS, Vorbis, etc. reliably stall
  AVPlayer. So audio is **always transcoded to stereo AAC**.
- Video is **copied** when it's already Apple-friendly (`h264`, `hevc`, `mpeg4`),
  otherwise it's transcoded to H.264.
- HEVC copied from MKV gets an `hev1` tag by default, which Apple refuses to
  decode — the file ends up **audio-only**. Airtroska forces the `hvc1` tag so
  the video track actually plays.

For AirPlay to a third-party receiver (e.g. a Roku TV) that can't be handed a
`file://` URL, Airtroska runs a tiny local HTTP server with byte-range support
and gives AVPlayer the `http://` LAN URL instead.

## Requirements

- macOS 13+
- `ffmpeg` and `ffprobe` on your PATH (e.g. `brew install ffmpeg`). The app
  searches `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, and falls back to
  a login shell to find them — important when launched from Finder, which gets
  a minimal `PATH`.

## Build

```sh
./build.sh release
open build/Airtroska.app
```

`build.sh` compiles with SwiftPM, assembles the `.app` bundle (with the
`Info.plist` that AirPlay / local networking needs), and ad-hoc signs it. The
assembled bundle in `build/` is a build artifact and is git-ignored.

## Use

1. Launch Airtroska.
2. Drag a `.mkv` / `.mp4` / `.m4v` / `.mov` / `.avi` onto the window.
3. Wait for the progress bar — "Copying video, converting audio" is fast;
   "Transcoding to H.264" is not.
4. The converted MP4 opens in an AVPlayer. Use the AirPlay button to pick your
   Apple TV.

## Project layout

```
Sources/Airtroska/
  AirtroskaApp.swift   entry point / window
  ContentView.swift     drop zone + progress + error handling
  Remuxer.swift        ffprobe probe, conversion-kind decision, ffmpeg run
  PlayerView.swift     AVPlayer with AirPlay route picker
  LocalHTTPServer.swift  byte-range HTTP server for non-Apple receivers
Resources/Info.plist   AirPlay / local-network entitlements
Package.swift          SwiftPM manifest
build.sh               build + assemble + ad-hoc sign
```

## License

MIT — see [LICENSE](LICENSE).