# Spec: verified-copy

## ADDED Requirements

### Requirement: Source scan with junk filtering
The system SHALL enumerate all files under the selected source directory, excluding macOS filesystem artifacts: `.DS_Store`, files prefixed with `._`, and the directories `.Spotlight-V100`, `.Trashes`, `.fseventsd`, and `.TemporaryItems`. The scan SHALL produce the total file count and byte size before copying begins.

#### Scenario: Card contains junk files
- **WHEN** the source contains `DCIM/photo.jpg`, `DCIM/.DS_Store`, and `DCIM/._photo.jpg`
- **THEN** only `DCIM/photo.jpg` appears in the copy plan and totals

#### Scenario: Nested junk directories
- **WHEN** the source contains a `.Trashes` directory at any depth
- **THEN** nothing under it is included in the copy plan

### Requirement: MD5-verified copy with destination re-read
The system SHALL copy each file by streaming from the source while computing its MD5, writing to a temporary destination file named `<filename>.kopi-tmp`, then re-reading the temporary file from the destination and computing its MD5. The file SHALL be renamed to its final name only when both hashes match. Verification MUST reflect destination storage contents (bypassing the OS page cache for the verification read).

#### Scenario: Successful verified copy
- **WHEN** a file copies and source-stream hash equals destination re-read hash
- **THEN** the file exists at its final destination path and no `.kopi-tmp` remains for it

#### Scenario: Destination re-read detects corruption
- **WHEN** the destination re-read hash does not match the source hash
- **THEN** the `.kopi-tmp` file is NOT renamed, the file is retried once from the source, and if it fails again it is flagged as failed in the session report

#### Scenario: Crash during copy leaves no false-complete file
- **WHEN** the app is terminated mid-copy of a file
- **THEN** the destination contains only a `.kopi-tmp` for that file, never a final-named partial file

### Requirement: Source is never modified
The system SHALL open source files read-only and SHALL NOT write, delete, rename, or otherwise modify anything under the source directory.

#### Scenario: Session completes or aborts
- **WHEN** any copy session finishes, fails, or is cancelled
- **THEN** every file and directory under the source is byte-identical to its pre-session state

### Requirement: Incremental skip of verified existing files
The system SHALL skip copying a file when a destination file with the same relative path and size already exists AND re-hashing that destination file matches the source stream hash. Existence or size alone SHALL NOT be sufficient to skip.

#### Scenario: Re-copying a partially offloaded card
- **WHEN** half the card's files already exist at the destination and verify, and half do not exist
- **THEN** only the missing files are copied, and skipped files are reported as verified-skipped

#### Scenario: Existing destination file differs from source
- **WHEN** a same-path, same-size destination file fails re-hash comparison against the source
- **THEN** the file is re-copied through the full verified-copy pipeline and the overwrite is surfaced in the UI

### Requirement: Per-session MD5 manifest
The system SHALL write a manifest file named `kopi-manifest-<yyyymmdd-hhmmss>.md5` into the destination root after each session, containing one line per verified file in `md5sum` format (`<md5>  <relative/path>`). Files that failed verification SHALL NOT appear in the manifest.

#### Scenario: Session with all files verified
- **WHEN** a session completes with 100 files verified
- **THEN** the destination root contains a manifest with exactly 100 entries, each matching the copied files' actual hashes

#### Scenario: Session with failures
- **WHEN** a session completes with 98 verified files and 2 failed files
- **THEN** the manifest contains exactly 98 entries

### Requirement: Loud failure handling
The system SHALL treat destination-full, destination-unavailable (destination volume disconnected), source-unavailable (card ejected), and hash mismatch as first-class, mutually distinguishable failures: abort or flag loudly, delete in-progress `.kopi-tmp` files on abort, and report completed/failed counts at session end. Orphaned `.kopi-tmp` files from prior interrupted sessions SHALL be removed and their files re-copied on the next session covering them.

#### Scenario: Destination disk fills mid-copy
- **WHEN** a write fails because the destination volume is full
- **THEN** the session aborts, the in-progress `.kopi-tmp` is deleted, and the UI reports how many files completed before the failure

#### Scenario: Destination volume disconnected mid-copy
- **WHEN** the destination volume disappears during a session
- **THEN** the session aborts, the in-progress `.kopi-tmp` is deleted, and the failure is reported distinctly as destination-unavailable (not as disk-full or source-ejected)

#### Scenario: Card ejected mid-copy
- **WHEN** the source volume disappears during a session
- **THEN** the session aborts, the in-progress `.kopi-tmp` is deleted, and the failure is reported distinctly from a hash mismatch

### Requirement: Session report
The system SHALL produce an end-of-session summary listing copied files, verified-skipped files, and failed files with reasons.

#### Scenario: Mixed outcome
- **WHEN** a session ends with 90 copied, 8 skipped, and 2 failed
- **THEN** the summary shows all three counts and identifies the 2 failed files with their failure reasons
