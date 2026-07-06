# VidDL

VidDL is a macOS video downloader for streaming sites.

Minimum macOS version: macOS 14.0 Sonoma.

## Installation

Build a local unsigned DMG from this checkout:

```sh
bash scripts/build-dmg.sh
```

Then:

1. Open the generated `VidDL-<version>-build<build>-unsigned.dmg`.
2. Open the DMG and drag VidDL into `Applications`.
3. Open VidDL from `Applications`.

On first launch, macOS may say VidDL is from an unidentified developer because the local DMG is unsigned and unnotarized. Open System Settings, go to Privacy & Security, then allow VidDL from the security prompt. After that, open VidDL again.

## Required Dependencies

VidDL uses external command-line tools for extraction, HLS downloads, and video processing. Install them with Homebrew.

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

## Optional Cloud Upload Setup

Cloud uploads are optional. Current Settings exposes a minimal Cloud Destination tile for Google Drive setup. Click the tile to open the detailed modal after installing `rclone`.

### Google Drive Uploads

Google Drive uploads use `rclone`.

Install `rclone`:

```sh
brew install rclone
```

Create a Google Drive remote:

```sh
rclone config
```

In the rclone setup flow, choose Google Drive and name the remote:

```text
gdrive
```

You can use a different remote name, but it must match the Google Drive remote name in VidDL Settings.

The default Google Drive upload path is:

```text
VidDL/
```

## First Launch

The Home tab shows a Setup panel when VidDL finds missing tools or incomplete cloud setup.

The setup panel includes copyable install or setup commands, such as:

```sh
brew install yt-dlp
brew install ffmpeg
brew install rclone
rclone config
```

After installing or configuring tools, click Refresh Checks to verify them.

Cloud setup, notifications, download options, helper checks, Pro licensing, and app info are configured from minimal Settings tiles. Each tile opens a modal with the detailed controls.

## Licensing

VidDL includes 3 free downloads.

VidDL Pro unlocks unlimited downloads with a one-time $0.99 purchase. Purchase or activate Pro from the in-app upgrade prompt or the Pro section in Settings.

## Keeping Dependencies Updated

Keep command-line dependencies current with:

```sh
brew upgrade yt-dlp ffmpeg
```

If you use cloud uploads, also keep optional upload tools current:

```sh
brew upgrade rclone
```

## Automation URL Scheme

VidDL registers this custom URL scheme for local automation:

```text
pmvdl://extract?url=<encoded-url>
```
