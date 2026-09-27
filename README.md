# kopi

[![CI](https://github.com/LittleRoom4Bessa/kopi/actions/workflows/ci.yml/badge.svg)](https://github.com/LittleRoom4Bessa/kopi/actions/workflows/ci.yml)

A DIT-grade offload tool for casual users, living in your macOS menu bar.

Finder copy-paste can't tell you whether your footage actually arrived intact — and professional DIT tools cost ~$1k/year for features most people never touch. kopi sits in between: pick a card, pick a destination, and every byte is proven to match before you format the card.

## Features

**Casual mode — verified single-destination backup**
- Streams each file while hashing (MD5), writes to a temp file, re-reads it from storage bypassing the page cache, and renames only when both hashes match
- A crash, eject, or power loss can never leave a corrupt file masquerading as a complete one — only an obviously-incomplete `.kopi-tmp`
- Per-session manifest (`kopi-manifest-<timestamp>.md5`) written to the destination for future bit-rot re-verification
- Incremental re-copy: files that already verify at the destination are skipped
- macOS junk filtering (`.DS_Store`, `._*`, `.Spotlight-V100`, …)
- Loud, distinct failures: disk full / destination disconnected / card ejected / hash mismatch

**Disk intelligence**
- Every volume becomes a "disk card": type (SD card / external SSD / HDD / internal / network), bus, capacity, free space
- Interface speed ceiling shown instantly ("SD bus · up to ~300 MB/s")
- Optional one-click **Speed Test** — a real measured read/write probe (read-only on source volumes)

**Pro mode — 3-2-1 ingest** (expands the popover in place)
- 3 destination folders: **3 copies · 2 media · 1 remote** (a mounted NAS volume counts as remote)
- Read-once **fan-out pipeline**: the card is read a single time and streamed to all destinations concurrently, with per-destination queues — a stalled NAS never slows down your local SSD
- Hash choice: **xxHash64** (fast, default) or **SHA-256** (forensic)
- Physical media-diversity rules: two destinations on the same disk → warning; no network destination → warning; destination on the source card → error
- Optional **strict mode**: warnings become start-blocking violations

The source card is **never** written to. Ever.

## Requirements

- macOS 14 (Sonoma) or later
- No dependencies beyond the system — the only vendored code is the official xxHash C reference (BSD-2)

## Install

Download `Kopi.zip` from the [latest release](https://github.com/LittleRoom4Bessa/kopi/releases/latest), unzip, and move `Kopi.app` to `/Applications`. The app is ad-hoc signed (no Developer ID), so on first launch use **right-click → Open** to clear Gatekeeper.

## Build & Run

```bash
swift build              # debug build
./scripts/make-app.sh    # release build + Kopi.app bundle
open .build/Kopi.app
```

## Test

```bash
./scripts/test.sh        # swift-testing suite (50 tests)
```

> **Note:** the test script targets machines with only the Command Line Tools
> (no Xcode). XCTest doesn't exist without Xcode, so the suite uses
> swift-testing and the script applies two small workarounds for the CLT's
> incomplete swift-testing packaging (framework search path, and a copied
> `Testing.framework` with its broken cross-import overlay stripped).

## How verification works

```
source ──stream + hash──▶ <name>.kopi-tmp ──re-read (page cache bypassed)──▶ compare
                                                                              │ match
                                                                              ▼
                                                              rename to final name
```

Hashing only the write stream proves what was *read*, not what *landed* — the
destination re-read is the actual verification. In fan-out (pro) mode the same
contract holds per destination, and a hash mismatch retries the file once.

## Project layout

```
Sources/
  KopiCore/     copy engine, fan-out pipeline, hashing, disk introspection,
                speed probe, 3-2-1 media rules — UI-free, fully unit-tested
  CxxHash/      vendored xxHash v0.8.3 reference implementation
  kopi/         menu bar app: popover, disk cards, pro mode expansion
Tests/          swift-testing suite (fault-injection transports)
openspec/       OpenSpec change proposals, designs, and specs
```

## Status

Feature-complete per the [kopi-refresh spec](openspec/changes/kopi-refresh/proposal.md);
final hardware e2e pass (real SD card + NAS) pending. See `openspec/` for the
full design history.
