# StreamTape Current-Player Resolution and Installer

Date recorded: 2026-08-20

## Root cause

The reported AllPornStream post correctly exposed StreamTape embed `xmBe2WwJ2AtkM08`, but the persistent Agent returned no resolvable source. Current StreamTape pages publish intentionally invalid hidden `get_video` tokens and construct the usable link through JavaScript string assignments. The old Agent selected a static decoy and used a normal GET.

## Implemented behavior

Agent commit `0e16730c29940c1ec547c1edfea72ba1ddac7d4d`:

- recognizes trusted player link elements including `ideoolink`, `botlink`, `robotlink`, `captchalink`, `norobotlink`, and `ideoooolink`;
- evaluates only quoted-string concatenation and chained integer-only `.substring(...)`;
- ranks evaluated assignments ahead of hidden static values;
- normalizes protocol-relative, StreamTape-relative, and `/get_video` links;
- adds `stream=1` when absent;
- resolves with HEAD first and `Range: bytes=0-0` fallback using the embed Referer and browser User-Agent;
- accepts only safe public HTTPS redirects to approved `tapecontent.net` MP4 hosts;
- distinguishes malformed expressions, rejected hosts, invalid token responses, and redirect failures;
- keeps the AllPornStream post URL as the durable queued source so expiring tokens refresh on each attempt.

## Verification

- Focused StreamTape and AllPornStream tests: 33 passed.
- The full Swift run executed 229 tests. Relevant coverage passed; one unrelated browser-extension-required Feed test failed.
- External-Xcode release build succeeded.
- Live extraction returned `STREAMTAPE · Video` backed by `tapecontent.net`.
- The bounded probe returned HTTP 206, `Content-Type: video/mp4`, one byte, and `Content-Range: bytes 0-0/1032443318`.

## Installer

LustreStudio commit `604abf1` pins the repaired Agent revision.

- Artifact: `/Volumes/WD/Projects/pmvhavendownloader/LustreStudio-2.2.7-build10-unsigned.dmg`
- SHA-256: `5c43314f4fdb0ea07e66f903d302f053c0c738b10216a9d8cddc8ea406855870`
- Size: `16597311` bytes
- Version/build: `2.2.7 (10)`
- Architecture: `x86_64`
- `hdiutil verify`: valid
- Mounted app and bundled Agent executables: present
- Signing: unsigned and unnotarized for personal local installation

## Operational distinction

This milestone repairs and packages the source. A later installed-Agent incident showed that an already installed Runtime 10 could still predate this commit; Runtime 11 activation repaired that deployment drift. Repository state, DMG contents, and the currently running per-user Agent must be verified separately.
