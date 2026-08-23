# LustreStudio

LustreStudio is a macOS video downloader for streaming sites.

Minimum macOS version: macOS 14.0 Sonoma.

## Installation

Build a local unsigned DMG from this checkout:

```sh
bash scripts/build-dmg.sh
```

Then:

1. Open the generated `LustreStudio-<version>-build<build>-unsigned.dmg`.
2. Open the DMG and drag LustreStudio into `Applications`.
3. Open LustreStudio from `Applications`.

On first launch, macOS may say LustreStudio is from an unidentified developer because the local DMG is unsigned and unnotarized. Open System Settings, go to Privacy & Security, then allow LustreStudio from the security prompt. After that, open LustreStudio again.

## Required Dependencies

LustreStudio uses external command-line tools for extraction, HLS downloads, and video processing. Install them with Homebrew.

If Homebrew is not installed:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Install `yt-dlp` for video extraction from streaming sites:

```sh
brew install yt-dlp
```

Install `ffmpeg` for HLS stream assembly and video processing:

```sh
brew install ffmpeg
```

## Download Destinations

LustreStudio supports downloads to a local folder and uploads to Mega. Remote
destinations backed by `rclone` are not supported.

## First Launch

The Home tab shows a Setup panel when LustreStudio finds missing tools.

The setup panel includes copyable install or setup commands, such as:

```sh
brew install yt-dlp
brew install ffmpeg
```

After installing or configuring tools, click Refresh Checks to verify them.

Notifications, download options, Pro licensing, and app info are configured in Settings.

## Licensing

LustreStudio includes 3 free downloads.

LustreStudio Pro unlocks unlimited downloads with a one-time $0.99 purchase. Purchase or activate Pro from the in-app upgrade prompt or the Pro section in Settings.

## Keeping Dependencies Updated

Keep command-line dependencies current with:

```sh
brew upgrade yt-dlp ffmpeg
```

## Automation URL Scheme

LustreStudio retains this custom URL scheme for local automation:

```text
pmvdl://extract?url=<encoded-url>
```
