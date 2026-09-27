# Proposal: add-sd-backup-tool

## Why

Backing up photos/videos from SD cards today means either trusting Finder copy-paste (no integrity verification, partial copies look complete) or paying ~$1k/year for professional DIT offload tools that are massive overkill for personal use. The user needs a small, trustworthy tool that guarantees a backup actually matches the card before the card gets formatted and reused.

## What Changes

- New native macOS menu bar app (Swift/SwiftUI) — no cross-platform support
- Manual source (mounted SD volume) and destination folder selection, with last-used paths remembered
- Verified copy engine: stream source files with MD5 hashing, write to temporary destination files, re-read destination and compare hashes, rename to final name only on match
- Automatic filtering of macOS filesystem junk (`.DS_Store`, `._*` AppleDouble files, `.Spotlight-V100`, `.Trashes`, `.fseventsd`)
- Per-session MD5 manifest written to the destination, enabling future re-verification of the backup against bit rot
- Incremental re-copy behavior: files that already exist at the destination and verify against a prior manifest are skipped
- Live progress in the menu bar (per-file and overall), completion notification, and an explicit "safe to eject" done state
- Hard failure modes handled loudly: destination full, card ejected mid-copy, hash mismatch (kept as `.kopi-tmp`, flagged, retried once)
- The tool never deletes or modifies anything on the source card

## Capabilities

### New Capabilities

- `menu-bar-ui`: Menu bar presence, manual source/destination folder pickers, remembered paths, start control, live copy progress, completion notification, and safe-to-eject state
- `verified-copy`: Source scan with junk filtering, MD5-verified file copy (stream hash → temp write → destination re-read → atomic rename), mismatch/partial failure handling, per-session MD5 manifest, and incremental skip of already-verified files

### Modified Capabilities

<!-- None - greenfield project, no existing specs -->

## Impact

- **New codebase**: Swift/SwiftUI macOS app (menu bar agent, `LSUIElement`), no existing code affected
- **Dependencies**: none beyond Apple SDKs (CryptoKit/CommonCrypto or bundled MD5, DiskArbitration not required for v1 since source is manually assigned)
- **Systems touched**: filesystem only — reads source volume, writes destination folder + manifest. No caches, no intermediate copies, no Application Support storage of payload data
- **Out of scope (v1)**: auto-detect on card insert, auto-copy, multiple destinations, card formatting, MHL industry manifest format
