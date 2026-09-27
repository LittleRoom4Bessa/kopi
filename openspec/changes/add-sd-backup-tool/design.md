# Design: add-sd-backup-tool

## Context

Greenfield repo (only `openspec/` exists today). The product is a personal, native macOS menu bar app for verified SD-card backup: manually pick a source volume and destination folder, copy everything (minus macOS junk), and cryptographically-ish confirm every byte landed before the card is reused. The user explicitly wants Finder's trust problem solved (no verification, silent partials) without DIT-tool pricing or complexity.

Key constraint from exploration: **integrity failures come from the copy pipeline (silent read errors, interrupted copies, verifying what was read rather than what was written) — not from hash collisions.** The design centers on that reality.

## Goals / Non-Goals

**Goals:**
- Byte-level confidence: every copied file is proven to match the source by re-reading the destination
- No partial file ever appears complete (temp-write + rename-on-verify)
- No intermediate copies or caches anywhere (straight source → destination)
- Failure modes are loud and recoverable: disk full, card ejected mid-copy, hash mismatch
- Simple single-user UX: two pickers, one Start button, live progress, done = safe to eject

**Non-Goals (v1):**
- Auto-detect/auto-copy on card insert
- Multiple or scheduled destinations
- Deleting or formatting the source card (the tool NEVER writes to the source)
- MHL/industry manifest interop, PDF reports
- Cross-platform support

## Decisions

### D1: Native Swift/SwiftUI menu bar agent
`LSUIElement` app with `NSStatusItem` + SwiftUI `MenuBarExtra`. Alternatives (Electron/Tauri, shell script + SwiftBar) rejected: native gives proper file APIs, notifications, and a long-term home for volume-mount detection later, at lower complexity than a web stack for this UI.

### D2: Verify by re-reading the destination, not by hashing the stream alone
Per file: stream-read source → write `<name>.kopi-tmp` while computing MD5 of the source stream → close → **re-read the temp file from disk and compute its MD5** → compare → rename to final name only on match. Hashing only the write stream proves what we read, not what landed. The re-read is the actual verification.

Alternative considered: hash both streams in one pass and skip the re-read. Rejected — it cannot detect destination write corruption, which is one of the real failure modes.

### D3: MD5
User's choice, and acceptable: MD5 mismatch detection for random corruption is effectively certain (2⁻¹²⁸), and at single-card scale the bottleneck is card read speed, not hashing. xxHash64 is ~30x faster but buys nothing here and loses the familiar `.md5` manifest ecosystem. Not a security context, so MD5's collision attacks are irrelevant.

### D4: Temp-file + atomic rename for crash safety
All destination writes go to `<final>.kopi-tmp` and are renamed only after verification passes. A crash, eject, or power loss mid-copy leaves an obviously-incomplete `.kopi-tmp`, never a corrupt file masquerading as done. On mismatch: keep the `.kopi-tmp`, retry the file once, then flag it red in the UI if it fails again.

### D5: Junk filtering at scan time
Skip during source enumeration: `.DS_Store`, `._*` (AppleDouble), `.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.TemporaryItems`. These are Finder/index artifacts, not user content; copying them pollutes the manifest and wastes verification time.

### D6: Per-session MD5 manifest
After a session completes, write `kopi-manifest-<yyyymmdd-hhmmss>.md5` into the destination root: standard `md5sum` format (`<hash>  <relative/path>`), one line per verified file. This doubles as the record for future bit-rot re-verification and for incremental skip (D7).

Alternative considered: single append-only manifest. Rejected for v1 — per-session files are simpler, self-contained, and diffable; merging is a future concern.

### D7: Incremental skip via destination re-verification
If a destination file with the same relative path and size already exists, re-hash the **destination** file and compare against the source hash computed in-stream; skip the copy only on match. Never trust existence or size alone. (Manifest-accelerated skipping is a possible optimization, not v1.)

### D8: Copy engine is a testable Swift package, UI is a thin shell
Core logic (scan, filter, copy, hash, verify, manifest) lives in a library target with no AppKit/SwiftUI dependencies, driven by a protocol-based file system abstraction so the whole pipeline is unit-testable with fixtures. The menu bar app just renders state and forwards user intent.

### D9: Page-cache honesty
The destination re-read may be served from the OS page cache rather than disk. Use `fcntl(F_NOCACHE)` on destination file handles so verification reads reflect what's actually on storage. Low cost, closes a theoretical verification hole.

### D10: No third-party dependencies in v1
MD5 via `CryptoKit` (`Insecure.MD5`) — bundled with the OS, streaming-capable. Keeps the build trivial and the attack surface zero.

### D11: No mid-file resume (deliberate)
An interrupted file restarts from byte zero on the next session — there is no resume-where-it-left-off. Rationale: resume bookkeeping adds real complexity to save time in a rare case, and the temp-file model already guarantees a restarted file is always correct. Documented so it isn't later mistaken for a missing feature.

### D12: Four distinguishable failure types
Destination-full, destination-unavailable (volume disconnected), source-unavailable (card ejected), and hash mismatch are classified separately so the UI can name exactly what happened. Sleep prevention (`IOPMAssertion`) was considered and deferred — see Risks.

## Risks / Trade-offs

- [Re-reading doubles destination I/O] → Acceptable: single-card scale; correctness over speed. F_NOCACHE keeps it honest without extra cost.
- [Card ejected mid-copy leaves `.kopi-tmp` litter] → On next run, orphaned `.kopi-tmp` files are deleted and re-copied (they were never verified).
- [Destination disk full mid-copy] → Detect write errors, abort session loudly, delete the in-progress `.kopi-tmp`, report how many files completed.
- [Same-relative-path collision across sessions with different content] → D7 re-verifies; mismatch means overwrite-with-verify (new content wins), logged in UI.
- [MD5 feels "broken" to security-minded observers] → Documented in D3; integrity-only context, and manifest format stays swappable if ever needed.
- [User picks a slow/network destination] → Works correctly but slowly; UI shows throughput so it's diagnosable. No special-casing in v1.
- [Mac sleeps during a long copy, interrupting the session] → Sleep prevention (`IOPMAssertion`) deferred per user decision; the interruption is handled gracefully (abort + `.kopi-tmp` cleanup + re-copy next session), just not prevented. Revisit if it bites in practice.

## Open Questions

All resolved during implementation:

- ~~"Reveal in Finder" + per-file failure export?~~ → **Yes** to Reveal in Finder (task 4.6). Failure reasons shown inline in the panel; no separate log export in v1.
- ~~App Sandbox posture~~ → **Non-sandboxed for v1** (personal tool, no distribution). Paths persist as plain strings in `UserDefaults`; ad-hoc code signing only. Revisit if the app is ever distributed or notarized.
