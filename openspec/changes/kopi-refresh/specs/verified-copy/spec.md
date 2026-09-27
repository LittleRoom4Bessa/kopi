# Spec: verified-copy (delta)

## RENAMED Requirements

### Requirement: MD5-verified copy with destination re-read
**Reason**: The verification algorithm becomes selectable (MD5 casual, xxHash64/SHA-256 pro); the name must not hardcode MD5.
**Migration**: None — behavioral contract is preserved and generalized.

FROM: `MD5-verified copy with destination re-read`
TO: `Verified copy with destination re-read`

### Requirement: Per-session MD5 manifest
**Reason**: Manifest format follows the session's hash algorithm; the name must not hardcode MD5.
**Migration**: Existing `.md5` manifests remain valid and continue to drive incremental skip.

FROM: `Per-session MD5 manifest`
TO: `Per-session manifest`

## MODIFIED Requirements

### Requirement: Verified copy with destination re-read
The system SHALL copy each file to every assigned destination by streaming from the source while computing its hash with the session's algorithm (MD5 in casual mode; xxHash64 or SHA-256 in pro mode), writing to a temporary destination file named `<filename>.kopi-tmp`, then re-reading the temporary file from the destination and computing its hash. The file SHALL be renamed to its final name only when both hashes match. Verification MUST reflect destination storage contents (bypassing the OS page cache for the verification read). Casual mode is the single-destination case of the same pipeline.

#### Scenario: Successful verified copy
- **WHEN** a file copies and source-stream hash equals destination re-read hash
- **THEN** the file exists at its final destination path and no `.kopi-tmp` remains for it

#### Scenario: Destination re-read detects corruption
- **WHEN** the destination re-read hash does not match the source hash
- **THEN** the `.kopi-tmp` file is NOT renamed, the file is retried once from the source, and if it fails again it is flagged as failed in the session report

#### Scenario: Crash during copy leaves no false-complete file
- **WHEN** the app is terminated mid-copy of a file
- **THEN** the destination contains only a `.kopi-tmp` for that file, never a final-named partial file

#### Scenario: Pro session uses selected algorithm
- **WHEN** a pro session runs with SHA-256 selected
- **THEN** both the source-stream hash and destination re-read hash are SHA-256 for every file

### Requirement: Incremental skip of verified existing files
For each destination independently, the system SHALL skip copying a file when a destination file with the same relative path and size already exists AND re-hashing that destination file with the session's algorithm matches the source stream hash. Existence or size alone SHALL NOT be sufficient to skip. Skip decisions for one destination SHALL NOT affect other destinations.

#### Scenario: Re-copying a partially offloaded card
- **WHEN** half the card's files already exist at a destination and verify, and half do not exist
- **THEN** only the missing files are copied to that destination, and skipped files are reported as verified-skipped

#### Scenario: Destinations at different completion states
- **WHEN** destination A already has and verifies all files but destination B is empty
- **THEN** A reports all files verified-skipped while B receives the full copy, in the same session

#### Scenario: Existing destination file differs from source
- **WHEN** a same-path, same-size destination file fails re-hash comparison against the source
- **THEN** the file is re-copied through the full verified-copy pipeline and the overwrite is surfaced in the UI

### Requirement: Per-session manifest
After each session, the system SHALL write one manifest per destination into that destination's root, named `kopi-manifest-<yyyymmdd-hhmmss>.<alg>` where `<alg>` is `md5`, `xxh64`, or `sha256` matching the session's algorithm. The manifest SHALL contain one line per verified file in standard `<hash>  <relative/path>` format. Files that failed verification SHALL NOT appear in the manifest.

#### Scenario: Session with all files verified
- **WHEN** a pro session completes with 100 files verified at each of 3 destinations
- **THEN** each destination root contains a manifest with exactly 100 entries matching the copied files' actual hashes

#### Scenario: Session with failures at one destination
- **WHEN** a session completes with 98 verified and 2 failed files at one destination and 100 verified at the others
- **THEN** that destination's manifest contains exactly 98 entries and the others contain 100

#### Scenario: Manifest extension matches algorithm
- **WHEN** a session ran with xxHash64
- **THEN** the manifest filename ends in `.xxh64` and entries are xxHash64 values

### Requirement: Loud failure handling
The system SHALL treat destination-full, destination-unavailable (destination volume disconnected), source-unavailable (card ejected), and hash mismatch as first-class, mutually distinguishable failures. A destination-level failure (full or disconnected) SHALL fail only that destination's remaining work; other destinations SHALL continue to completion. A source-level failure (card ejected) SHALL abort the entire session. On abort or destination failure, in-progress `.kopi-tmp` files for the affected destination SHALL be deleted, and completed/failed counts SHALL be reported per destination at session end. Orphaned `.kopi-tmp` files from prior interrupted sessions SHALL be removed and their files re-copied on the next session covering them.

#### Scenario: One destination fills mid-copy
- **WHEN** destination B becomes full during a 3-destination session
- **THEN** B's remaining files fail as destination-full, its in-progress `.kopi-tmp` is deleted, and destinations A and C continue to verified completion

#### Scenario: Destination volume disconnected mid-copy
- **WHEN** a destination volume disappears during a session
- **THEN** that destination fails distinctly as destination-unavailable (not as disk-full or source-ejected), and other destinations continue

#### Scenario: Card ejected mid-copy
- **WHEN** the source volume disappears during a session
- **THEN** the entire session aborts, all in-progress `.kopi-tmp` files are deleted, and the failure is reported distinctly from a hash mismatch

### Requirement: Session report
The system SHALL produce an end-of-session summary per destination listing copied files, verified-skipped files, and failed files with reasons, plus the session's hash algorithm.

#### Scenario: Mixed outcome across destinations
- **WHEN** a pro session ends with destination A fully verified, B failed as disk-full after 40 files, and C fully verified with 5 skips
- **THEN** the summary shows per-destination copied/skipped/failed counts, B's abort reason, and the session algorithm

## ADDED Requirements

### Requirement: Read-once fan-out
In a multi-destination session the system SHALL read each source file exactly once, streaming its bytes to all destinations concurrently, computing the source-stream hash during that single read. Per-destination writer queues SHALL be independently bounded so that a slow or stalled destination does not block writes to other destinations, though it MAY throttle the shared source read once its buffer bound is reached.

#### Scenario: Three destinations, one card read
- **WHEN** a 3-destination session copies a 4 GB file
- **THEN** the source file is read from the card exactly once and all 3 destinations receive verified copies

#### Scenario: Stalled NAS destination
- **WHEN** a network destination stalls while two local destinations are healthy
- **THEN** the local destinations continue writing and verifying without being blocked by the stalled queue, and the session does not fail the healthy destinations
