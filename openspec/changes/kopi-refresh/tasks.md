# Tasks: kopi-refresh

## 1. Hash abstraction

- [x] 1.1 Add `Hasher` protocol (update/finalize) in KopiCore with MD5 and SHA-256 implementations via CryptoKit
- [x] 1.2 Add xxhash SwiftPM dependency; implement xxHash64 `Hasher` wrapper
- [x] 1.3 Refactor `CopyEngine`/`CopyPlan` to take a hash-algorithm parameter instead of hardcoding MD5; manifest extension per algorithm (`.md5`/`.xxh64`/`.sha256`); keep v1 casual behavior (MD5) as default
- [x] 1.4 Unit tests: known-answer vectors for all three algorithms, manifest naming/format per algorithm

## 2. Disk intelligence

- [x] 2.1 Implement `DiskInspector` in KopiCore: mount path → BSD name → DiskArbitration description (volume name, bus, rotational/type, capacity, free space); whole-disk identity via partition-strip + device GUID; network volumes → server+share identity
- [x] 2.2 Define `DiskDescriptor` model with explicit `unknown` cases for every field; unit tests with fixture descriptions
- [x] 2.3 Interface speed-class table (USB 3.x, Thunderbolt, SD UHS, NVMe, network) with theoretical-ceiling labels
- [x] 2.4 Implement cancellable `SpeedProbe`: destination write+read (~256 MB temp file, `F_NOCACHE` read-back, cleanup on completion/cancel); source read-only probe; unit tests with scripted transport
- [x] 2.5 UI: disk card view component (name, type, bus, capacity/free bar, interface speed, Speed Test button + measured result); wire into casual pickers

## 3. Fan-out copy engine

- [x] 3.1 Generalize `CopyPlan` to N destinations; casual mode = N=1 of the same pipeline
- [x] 3.2 Implement read-once fan-out: single source reader, per-destination bounded queues (~64 MB), per-destination writer → tmp → re-read verify → rename
- [x] 3.3 Per-destination failure isolation: destination-full/disconnected fails only that destination; source-ejected aborts all; `.kopi-tmp` cleanup per affected destination
- [x] 3.4 Per-destination manifests and per-destination incremental skip (skip decisions independent across destinations)
- [x] 3.5 Per-destination session report with algorithm recorded
- [x] 3.6 Unit tests: scripted `CopyTransport` — stalled destination doesn't block others, mid-session per-destination failures, multi-destination incremental states, crash leaves only `.kopi-tmp`

## 4. Pro mode

- [x] 4.1 Pro settings model: 3 destination slots, hash selection (xxHash64 default), strict toggle; persistence across launches
- [x] 4.2 Media-rules evaluator (pure function): same-physical-disk warn, no-network warn, destination-on-source error, duplicate-folder error; unit tests for all rule/strict combinations
- [x] 4.3 Detached pro panel (NSPanel-style, no Dock icon): 3 destination pickers with disk cards, hash picker, strict toggle, rule badges naming involved disks, per-destination progress and results
- [x] 4.4 Start gating: hard errors always block; warn violations block only when strict is on; popover pro-mode entry point
- [x] 4.5 Popover condensed multi-destination progress during pro sessions; panel close does not interrupt session

## 5. Verification

- [x] 5.1 `swift build` + `swift test` green
- [x] 5.2 `openspec validate kopi-refresh --strict`
- [ ] 5.3 Manual e2e: real SD card → 3 destinations (internal SSD + external disk + NAS mount), xxHash64 and SHA-256 sessions; verify manifests independently (`md5 -r` equivalent per algorithm); pull card mid-copy (abort-all); fill/disconnect one destination mid-copy (others complete); strict-mode blocking with two destinations on one physical disk; Speed Test on source and destination cards
