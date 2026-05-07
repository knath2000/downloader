# VidDL

VidDL is a macOS video downloader for streaming sites.

Minimum macOS version: macOS 14.0 Sonoma.

## Installation

1. Download the VidDL DMG from the GitHub Releases page: `https://github.com/knath2000/downloader/releases`.
2. Open the DMG and drag VidDL into `Applications`.
3. Open VidDL from `Applications`.

On first launch, macOS may say VidDL is from an unidentified developer. Open System Settings, go to Privacy & Security, then allow VidDL from the security prompt. After that, open VidDL again.

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

Cloud uploads are optional. Configure them in VidDL Settings after installing the required tools for the service you want to use.

### MEGA Uploads

MEGA uploads use MEGAcmd.

Install MEGAcmd:

```sh
brew install --cask megacmd-app
```

Then sign in with your MEGA account:

1. Open the MEGAcmd app and sign in, or
2. Run this from Terminal:

```sh
mega-login your@email.com
```

In VidDL Settings, configure the MEGA upload path. The default path is:

```text
/Cloud/VidDL/
```

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

### Seedbox Transfers

Seedbox transfers can use either `rclone` or direct WebDAV.

Option A: rclone

```sh
brew install rclone
rclone config
```

Create a seedbox remote named:

```text
seedbox
```

You can use a different remote name, but it must match the seedbox remote name in VidDL Settings.

Option B: WebDAV

In VidDL Settings, choose WebDAV mode and enter:

- WebDAV URL
- Username
- Password
- Remote path

The default seedbox remote path is:

```text
/
```

## First Launch

The Home tab shows a Setup panel when VidDL finds missing tools or incomplete cloud setup.

The setup panel includes copyable install or setup commands, such as:

```sh
brew install yt-dlp
brew install ffmpeg
brew install --cask megacmd-app
brew install rclone
rclone config
```

After installing or configuring tools, click Refresh Checks to verify them.

Cloud services are configured in the Settings tab under their respective sections.

## Licensing

VidDL includes 3 free downloads.

VidDL Pro unlocks unlimited downloads with a one-time $0.99 purchase. Purchase or activate Pro from the in-app upgrade prompt or the Pro section in Settings.

## Keeping Updated

VidDL checks for app updates automatically with Sparkle.

To check manually, use:

```text
VidDL > Check for Updates...
```

Keep command-line dependencies current with:

```sh
brew upgrade yt-dlp ffmpeg
```

If you use cloud uploads, also keep optional upload tools current:

```sh
brew upgrade rclone
brew upgrade --cask megacmd-app
```

## Browser Integration and URL Scheme

VidDL registers this custom URL scheme for browser extensions and automation:

```text
pmvdl://extract?url=<encoded-url>
```

The included Chrome extension uses this scheme for one-click extraction from the browser.
