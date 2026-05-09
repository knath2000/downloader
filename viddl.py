#!/usr/bin/env python3
"""Extract direct download links from supported video pages."""

import argparse
import os
import re
import ssl
import subprocess
import sys
import tempfile
import urllib.request

try:
    import certifi
    CA_BUNDLE = certifi.where()
except ImportError:
    CA_BUNDLE = None

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0"


def find_cmd(name):
    for p in [f"/usr/local/bin/{name}", f"/opt/homebrew/bin/{name}"]:
        if os.path.exists(p):
            return p
    return None


def make_opener():
    ctx = ssl.create_default_context(cafile=CA_BUNDLE) if CA_BUNDLE else ssl.create_default_context()
    return urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx))


def fetch_page(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    opener = make_opener()
    with opener.open(req, timeout=15) as resp:
        return resp.read().decode("utf-8")


def download_file(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    opener = make_opener()
    with opener.open(req, timeout=600) as resp:
        return resp.read()


def extract_video_sources(html):
    mp4_urls = re.findall(r'"(https?://[^"\s]+\.mp4)"', html)
    mp4_url = mp4_urls[0] if mp4_urls else None

    hls_pattern = re.compile(r'"(https?://[^"\s]+\.m3u8)"')
    hls_all = hls_pattern.findall(html)

    main_base = mp4_url + "/" if mp4_url else None
    seen = set()
    hls_entries = []
    master_url = None
    res_order = {"2160p": 0, "1440p": 1, "1080p": 2, "720p": 3, "480p": 4, "360p": 5}

    for u in hls_all:
        if u in seen:
            continue
        seen.add(u)
        res_match = re.search(r'/(\d+p)\.m3u8$', u)
        if res_match and main_base and u.startswith(main_base):
            hls_entries.append((res_match.group(1), u))
        elif u.endswith("/master.m3u8") and main_base and u.startswith(main_base):
            master_url = u

    hls_entries.sort(key=lambda x: res_order.get(x[0], 99))
    if master_url:
        hls_entries.append(("master", master_url))

    return {"mp4": mp4_url, "hls": hls_entries}


def mega_is_available():
    return find_cmd("mega-whoami") is not None


def mega_is_logged_in():
    mega_whoami = find_cmd("mega-whoami")
    if not mega_whoami:
        return False
    r = subprocess.run([mega_whoami], capture_output=True)
    return r.returncode == 0


def mega_upload(url, remote_path="/Cloud/VidDL/"):
    if not mega_is_available():
        print("ERROR: MEGA CLI not installed. Run: brew install --cask megacmd-app")
        sys.exit(1)
    if not mega_is_logged_in():
        print("ERROR: Not logged in to MEGA. Run: mega-login <email> <password>")
        sys.exit(1)

    print(f"Downloading MP4 from: {url}")
    data = download_file(url)
    filename = url.rsplit("/", 1)[-1] if "/" in url else "video.mp4"

    with tempfile.NamedTemporaryFile(delete=False, suffix=".mp4") as f:
        f.write(data)
        tmp_path = f.name

    try:
        size_mb = len(data) / (1024 * 1024)
        print(f"Downloaded {size_mb:.1f} MB")
        print(f"Uploading to MEGA: {remote_path}")

        mega_put = find_cmd("mega-put")
        r = subprocess.run([mega_put, "-c", tmp_path, remote_path], capture_output=True, text=True, timeout=900)

        if r.returncode != 0:
            print(f"Upload failed: {r.stderr.strip() or f'exit code {r.returncode}'}")
            sys.exit(1)

        if r.stdout.strip():
            print(r.stdout.strip())
        print(f"OK Uploaded to MEGA: {remote_path}")
    finally:
        os.unlink(tmp_path)


def verify_url(url):
    req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": UA})
    opener = make_opener()
    try:
        with opener.open(req, timeout=10) as resp:
            return resp.status == 200
    except Exception:
        return False


def main():
    parser = argparse.ArgumentParser(description="Extract & download videos from supported pages")
    parser.add_argument("url", help="video page URL")
    parser.add_argument("--mega", nargs="?", const="/Cloud/VidDL/", metavar="PATH",
                        help="Upload MP4 to MEGA (default remote path: /Cloud/VidDL/)")
    args = parser.parse_args()

    print(f"Fetching {args.url}")
    html = fetch_page(args.url)
    sources = extract_video_sources(html)

    if not sources["mp4"] and not sources["hls"]:
        print("No video sources found.", file=sys.stderr)
        sys.exit(1)

    if args.mega:
        if not sources["mp4"]:
            print("No MP4 source found for direct download.", file=sys.stderr)
            sys.exit(1)
        mega_upload(sources["mp4"], args.mega)
        return

    if sources["mp4"]:
        status = "OK" if verify_url(sources["mp4"]) else "FAIL"
        print(f"\nMP4 [{status}]:")
        print(f"  {sources['mp4']}")

    if sources["hls"]:
        print(f"\nHLS Streams:")
        for res, url in sources["hls"]:
            status = "OK" if verify_url(url) else "FAIL"
            print(f"  {res:>7s} [{status}]: {url}")


if __name__ == "__main__":
    main()
