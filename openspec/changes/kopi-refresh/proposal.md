# Proposal: kopi-refresh

## Why

kopi v1 proved the core loop — verified SD-card ingest without pro-priced DIT software — but it treats disks as opaque folders and offers only a single destination. Casual users still lack the two things real DIT tools sell: visible confidence about the physical media involved ("what is this disk, how full is it, how fast is it?"), and a guided path to proper 3-2-1 backup hygiene (3 copies, 2 media, 1 remote) at ingest time.

## What Changes

- **Disk intelligence everywhere**: source and destination pickers become "disk cards" showing volume name, disk type (SD card / external SSD / HDD / network volume), connection bus, occupied/free capacity, and interface speed class. An explicit "Speed Test" button runs a real read/write probe benchmark on demand.
- **Pro mode**: a detached panel (menu-bar app, no dock icon) where the user assigns **3 destination folders** and runs a 3-2-1 ingest:
  - Hash algorithm choice: **xxHash64 (default, fast)** or **SHA-256 (forensic)**. Casual mode keeps MD5.
  - Media-diversity rules with physical-disk detection: two destinations on the same physical disk → warning; no network volume among the 3 → warning; destination on the source card or duplicate folder → hard error.
  - **Strict mode** (opt-in toggle, default off): warnings above become start-blocking violations.
  - "Remote" means a mounted network volume (SMB/NFS) only — no cloud APIs in this change.
- **Fan-out verified copy**: the copy engine reads the source once and streams to all destinations concurrently with per-destination queues (a stalled NAS must not stall a local SSD), keeping per-destination verification, manifests, and incremental skip.
- **Menu bar stays primary**: casual mode remains a popover close to v1's shape; pro mode opens a detached panel from the menu bar.

## Capabilities

### New Capabilities

- `disk-intelligence`: Volume/disk introspection (type, bus, capacity, free space, interface speed class) via DiskArbitration/IOKit, plus an on-demand read/write speed probe benchmark per volume.
- `pro-mode`: Pro tier behavior — assignment of exactly 3 destination folders, hash algorithm selection (xxHash64 default / SHA-256), 3-2-1 media-diversity rules with warn and strict enforcement levels, and the detached pro panel UI.

### Modified Capabilities

- `menu-bar-ui`: Popover gains disk cards for source/destination, a pro-mode entry point, and condensed multi-destination progress display.
- `verified-copy`: Extends from one destination to N (1 in casual, 3 in pro) with read-once fan-out, per-destination queues/verification/manifests/incremental skip, and selectable hash algorithm (MD5 casual, xxHash64/SHA-256 pro).

## Impact

- **Code**: `KopiCore` grows disk introspection (DiskArbitration/IOKit), a benchmark probe, and a fan-out pipeline replacing the serial single-destination loop in `CopyEngine`; `kopi` app target gains disk-card views, a detached pro panel window, and pro settings.
- **Dependencies**: first non-Apple dependency — **xxhash** (xxHash64) via SwiftPM.
- **Systems touched**: filesystem as before, plus DiskArbitration/IOKit queries and small benchmark temp files on tested volumes (cleaned up after probe). No cloud/network API surface; network destinations are plain mounted volumes.
- **Sequencing**: `add-sd-backup-tool` (v1) should complete its final manual e2e task and archive before this change is implemented, so delta specs land on archived base specs.
- **Out of scope**: cloud object storage (S3/B2), auto-detect on card insert, card formatting, offsite geography verification (app detects *network*, not *offsite*).
