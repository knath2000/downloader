# Neon Collections Deployment, Runtime 17, and Installer

Date recorded: 2026-08-22

## Delivered

- Added the Agent-backed local collection cache and durable outbox for Library and Watchlist.
- Added normalized Neon Library, device-location, mutation-receipt, and change-ledger tables plus Watchlist tombstones.
- Added authenticated `POST /api/cloud/v1/collections/sync`.
- Production and development Neon branches were migrated independently. Do not assume `web/.env.local` points to Vercel Production.
- Deployed the matching `lustrecli` API to Vercel Production at `https://lustrecli.vercel.app`.
- Collection sync accepts bounded 100-mutation Agent batches with a route-specific 1 MiB request limit; other cloud routes retain the shared 16 KiB default.
- Collection writes use a dedicated Postgres transaction client because the existing Neon HTTP driver does not support callback transactions.
- Non-empty mutation uploads no longer return a duplicate initial bootstrap.

## Production evidence

- Production deployment: `dpl_4ow5CZGELVW85FqXDFhVLvokFaBa`
- Production alias: `https://lustrecli.vercel.app`
- Neon accepted the first 100 collection mutations atomically: 100 mutation receipts, 100 Library items, 100 device locations, and 100 collection change rows.
- The local store retains all 246 mutations because acknowledgement is removed only after the Agent successfully decodes and applies the complete response.

## Agent

- Installed and activated release Runtime 17.
- Current health: status `ok`, database ready, zero active jobs, authenticated listener at `127.0.0.1:63406`.
- The managed LaunchAgent points to `~/Library/Application Support/LustreStudioAgent/Runtime/17/lustre-agent`.
- Runtime 17 adds precise collection decoding diagnostics and finalizes the SQLite cursor statement before committing the apply transaction.
- Safe activation required confirming that all 274 durable jobs were completed.

## Remaining issue

Cloud collection upload is not yet complete. Runtime 17 reports:

`Unable to decode the cloud response at <root>: Expected date string to be ISO8601-formatted.`

Current local state:

- Library items: 246
- Watchlist items: 0
- Pending mutations: 246
- Cursor: 0

This is fail-safe: the outbox is retained and no local collection data is lost. The next task is to identify the response date field that bypasses the Agent decoder, add a contract fixture, deploy the correction, and verify the outbox reaches zero.

## Installer

- Artifact: `/Volumes/WD/Projects/pmvhavendownloader/LustreStudio-2.2.7-build17-unsigned.dmg`
- Version/build: `2.2.7 (17)`
- Size: `17,464,926` bytes
- SHA-256: `047bb513684e3bc8f3e3fa7205d6d8cb5919afc76018355b648f3b3f3a113196`
- Embedded Agent SHA-256 matched the release Runtime 17 binary at packaging time.
- `hdiutil verify`: valid
- Signing: unsigned and unnotarized for personal local installation

## Validation notes

- Next.js TypeScript and production builds passed.
- The focused collection store suite executed two tests: acknowledgement/cursor advancement passed; the optimistic Watchlist equality test failed on SQLite/JSON date precision despite visually identical timestamps.
- The Swift release build passed.
- Keep repository state, deployed cloud state, installed Runtime state, and DMG contents distinct when validating future releases.
