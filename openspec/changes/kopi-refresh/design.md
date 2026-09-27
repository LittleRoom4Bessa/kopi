# Design: kopi-refresh

## Context

kopi v1 (`add-sd-backup-tool`) delivers a single-destination, MD5-verified SD-card ingest in a menu bar popover, built on a clean split: `KopiCore` (testable copy engine, protocol-based transport, no UI deps) and a thin SwiftUI shell (`kopi` target). Disks are opaque folder paths; the engine copies serially to one destination.

kopi-refresh repositions the app as a casual DIT tool: disks become visible, characterized objects (type, bus, capacity, speed), and a pro tier adds proper 3-2-1 ingest — 3 destination folders, stronger hash choice, and media-diversity enforcement. Constraints carried over from v1: source is never written to, failures are loud, `KopiCore` stays UI-free and unit-testable, `LSUIElement` menu-bar app (no dock icon).

Decisions below were settled during exploration with the user; see proposal for motivation.

## Goals / Non-Goals

**Goals:**
- Every mounted volume the user picks is characterized: type, bus, capacity/free, interface speed class — visible before copy starts
- On-demand real speed measurement (explicit Speed Test button, never automatic)
- Pro mode: exactly 3 destinations, read-once fan-out copy, per-destination verification/manifests/incremental skip
- Hash choice in pro mode: xxHash64 (default) / SHA-256; casual keeps MD5
- 3-2-1 media rules: same-physical-disk and no-network-destination → warn by default, block in opt-in strict mode; destination-on-source and duplicate folder → always error
- A stalled destination (slow NAS) must not stall copies to other destinations

**Non-Goals:**
- Cloud object storage (S3/B2) or any network API — "remote" = mounted SMB/NFS volume
- Offsite verification (app detects *network*, not geography; UI phrases it as "network/remote")
- Auto-detect on card insert, card formatting, MHL interop, PDF reports
- RAID/media-set introspection beyond what BSD device topology exposes (documented, not solved)
- Automatic speed probing at mount/pick time (explicit user action only)

## Decisions

### D1: Disk identity via DiskArbitration + IOKit, keyed on whole-disk
Mount point → `statfs` BSD name (`disk4s1`) → `DADiskCreateFromBSDName` → description dict gives bus (USB/SD/Thunderbolt/NVMe internal), rotational flag (HDD), volume name/capacity. Strip the partition suffix to get the **whole disk** (`disk4`); the whole disk's device GUID / IOKit path is the media identity used by 3-2-1 rules. Network volumes (`smbfs`/`nfs`) have no BSD device — identity is server+share from the mount URL.

Alternatives considered: `URLResourceKey` volume flags alone (misses bus type and whole-disk linkage); shelling out to `diskutil`/`system_profiler` (fragile parsing, slow). DiskArbitration is C but stable, synchronous, and needs no entitlements.

### D2: Speed shown as interface ceiling instantly; real numbers behind an explicit button
There is no API for "max read/write speed". The disk card shows what *is* knowable instantly — bus + protocol class with a theoretical ceiling label ("SD UHS-II reader · up to ~300 MB/s"). A **Speed Test** button runs a probe: write ~256 MB of random data to a hidden temp file on the volume (timed), read it back with `F_NOCACHE` (timed), delete. Source volumes get a read-only probe (write test would violate the never-write-to-source rule); destinations get read+write.

Alternatives considered: auto-probe on selection (rejected — writes without consent, slow, drains card reader bandwidth before copy); showing only live throughput during copy (rejected — user wants the info *before* committing).

### D3: Read-once fan-out pipeline with per-destination queues
The source (SD card, ~90–300 MB/s) is the slow link; reading it 3× serially wastes exactly the resource the user cares about. The engine becomes: one reader streams each source file once, hashing as it goes, and pushes chunks to N per-destination writer queues. Each destination independently: write `.kopi-tmp` → re-read (page-cache bypassed, v1 D9) → verify against the source-stream hash → rename. Bounded per-destination buffers give backpressure per destination; a stalled NAS blocks only its own queue until the bound is hit, at which point the reader throttles (correctness) while other destinations continue to drain.

Alternatives considered: serial per-destination (v1 shape ×3 — simple but 3× source reads); unbounded queues (memory blowup when one destination stalls); copyfile(3) clone-style fan-out (no per-destination hash verification).

This replaces the v1 serial single-destination loop in `CopyEngine`; casual mode is the N=1 case of the same pipeline, not a separate code path.

### D4: Pluggable hash strategy: MD5 / xxHash64 / SHA-256
`Hasher` protocol (update/finalize) with three implementations: MD5 and SHA-256 via CryptoKit, xxHash64 via the **xxhash** SwiftPM package (first non-Apple dependency — official C reference implementation, thin Swift wrapper). Casual mode: MD5 (v1 behavior, `.md5` manifest ecosystem). Pro mode: xxHash64 default (~2 GB/s — hashing never bottlenecks even NVMe destinations), SHA-256 selectable for forensic-grade assurance. The manifest file extension and header record the algorithm (`kopi-manifest-<ts>.md5` / `.xxh64` / `.sha256`), so future re-verification tools can parse unambiguously.

Alternative considered: SHA-256 only (no new dependency). Rejected — xxHash64's speed matters at multi-destination scale and users explicitly get the choice; collision-resistance needs are non-adversarial here (transfer errors, bit rot).

### D5: Physical-media diversity rules as a pure, testable function
Input: 3 destination descriptors (whole-disk GUID or network share identity) + source identity. Output: violations list. Rules:

| Rule | Level |
|---|---|
| Two destinations share one physical disk | warn (strict: block) |
| No network volume among the 3 destinations | warn (strict: block) |
| Destination on the source's physical disk | always error |
| Same folder picked twice | always error |

Known blind spots, documented in UI copy: RAID volumes present as one BSD device (looks like single media); a NAS in the same room satisfies the letter but not the spirit of "offsite".

### D6: Strict mode is a display-level gate, not engine behavior
Strict mode is one boolean in pro settings. The engine is identical in both modes; strict only changes whether the Start button is enabled when warn-level violations exist. Keeps the copy pipeline free of policy and keeps warn/strict trivially testable at the UI state layer.

### D7: Pro UI is a detached panel; popover stays the primary surface
Casual mode lives in the `MenuBarExtra` popover, close to v1's shape plus disk cards. Pro mode opens a separate `NSPanel`-style window (non-activating, no dock icon — standard menu-bar-app pattern) hosting: 3 destination pickers with disk cards, hash picker, strict toggle, rule badges, per-destination progress and verification results. The popover shows condensed aggregate progress while a pro session runs.

Alternative considered: everything in the popover. Rejected — 3 disk cards + rules + progress exceeds comfortable popover bounds; popovers are glanceable surfaces, this is a control panel.

### D8: Per-destination manifests and incremental skip, unchanged semantics per destination
Each destination gets its own per-session manifest (D6 in v1, extended with algorithm-appropriate extension) and its own incremental skip (v1 D7: re-hash existing destination file, skip only on verified match). No cross-destination state — destinations are fully independent, so any subset can be re-run or fail without affecting others.

## Risks / Trade-offs

- **Fan-out pipeline complexity** (backpressure, partial-failure semantics across queues) is the biggest engineering risk vs v1's simple loop → Mitigation: casual mode = N=1 of the same pipeline; heavy unit tests with scripted `CopyTransport` failures per destination; bounded buffers sized conservatively (~64 MB/destination).
- **DiskArbitration coverage gaps**: exotic readers, USB hubs, or non-APFS/HFS volumes may report incomplete bus info → Mitigation: every field has an explicit "Unknown" rendering; never block copy on missing metadata.
- **Speed probe misleading on cached/busy systems**: numbers vary with system load → Mitigation: label as "measured", run 256 MB (enough to beat cache on typical configs), `F_NOCACHE` on read-back.
- **xxhash dependency**: first external package → Mitigation: official reference implementation, C, zero transitive deps; wrapped behind `Hasher` protocol so replacement is one file.
- **Strict-mode false positives** (e.g., two partitions of one SSD that the user considers separate) → Mitigation: opt-in, off by default; violation messages name the exact physical disks involved so the user understands the judgment.
- **Source read probe on nearly-full cards** — read-only probe has no space requirement, but a slow reader still costs seconds → Mitigation: probe is explicit, cancellable, and clearly labeled with duration expectation.

## Migration Plan

- v1 (`add-sd-backup-tool`) completes its final e2e task and archives first; kopi-refresh specs land as deltas on the archived base specs.
- `CopyEngine` refactor is internal: v1's external behavior (casual 1→1 MD5 verified copy, `.md5` manifest) is preserved as the N=1, MD5 configuration. Existing destination manifests remain valid and continue to drive incremental skip.
- No user data migration; remembered source/destination paths carry over.

## Open Questions

- Exact buffer bound per destination queue (start at 64 MB, tune with real NAS testing during implementation).
- Whether speed-test results are cached per volume across launches (lean: yes, keyed by volume UUID, shown with a "measured <date>" label — confirm during implementation).
