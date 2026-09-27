# Tasks: add-sd-backup-tool

## 1. Project scaffolding

- [x] 1.1 Create Xcode project: macOS app target (SwiftUI, `MenuBarExtra`), `LSUIElement = true`, plus a `KopiCore` Swift package/library target for the copy engine with no AppKit/SwiftUI dependencies
- [x] 1.2 Configure signing/sandbox: confirm App Sandbox posture and user-selected file read/write entitlements (resolves design Open Question 2)
- [x] 1.3 Set up test target for `KopiCore` with fixture-based file system tests (temp directories on disk)

## 2. KopiCore: scan and filter

- [x] 2.1 Implement source enumerator producing relative paths + sizes, excluding `.DS_Store`, `._*`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`, `.TemporaryItems` (spec: verified-copy / Source scan)
- [x] 2.2 Implement copy-plan model: total file count, total bytes, per-file entries — exposed before copying starts

## 3. KopiCore: verified copy engine

- [x] 3.1 Implement streaming MD5 hasher over `CryptoKit Insecure.MD5` (spec: verified-copy / MD5-verified copy)
- [x] 3.2 Implement per-file pipeline: stream source → write `<name>.kopi-tmp` → re-read temp with `fcntl(F_NOCACHE)` → compare hashes → rename on match (spec: verified-copy / MD5-verified copy, incl. crash-safety scenario)
- [x] 3.3 Implement mismatch handling: keep `.kopi-tmp`, retry once, then flag as failed with reason (spec: verified-copy / MD5-verified copy)
- [x] 3.4 Enforce read-only source access throughout the engine (spec: verified-copy / Source is never modified)
- [x] 3.5 Implement incremental skip: same relative path + size → re-hash destination, compare to source hash, skip on match, re-copy on mismatch (spec: verified-copy / Incremental skip)
- [x] 3.6 Implement failure handling with four distinguishable types (destination-full, destination-unavailable, source-unavailable, hash mismatch): aborts are loud, in-progress `.kopi-tmp` is deleted; orphaned `.kopi-tmp` cleanup + re-copy on next session (spec: verified-copy / Loud failure handling)
- [x] 3.7 Implement session report model: copied / verified-skipped / failed-with-reasons (spec: verified-copy / Session report)
- [x] 3.8 Implement per-session manifest writer: `kopi-manifest-<yyyymmdd-hhmmss>.md5` in destination root, `md5sum` format, verified files only (spec: verified-copy / Per-session manifest)
- [x] 3.9 Unit tests covering every verified-copy spec scenario (junk filtering, hash mismatch, partial-copy crash safety, skip logic, disk-full abort, manifest contents, session report)

## 4. Menu bar UI

- [x] 4.1 `MenuBarExtra` panel shell with status item; no Dock icon (spec: menu-bar-ui / Menu bar presence)
- [x] 4.2 Source and destination folder pickers with persistence (`UserDefaults` or app prefs); Start disabled until both paths valid; unavailable-source indicator (spec: menu-bar-ui / Manual selection)
- [x] 4.3 Pre-copy summary view: file count + total bytes from the copy plan (spec: menu-bar-ui / Pre-copy summary)
- [x] 4.4 Live progress view: current filename, files done/total, bytes done/total, driven by engine progress callbacks (spec: menu-bar-ui / Live progress)
- [x] 4.5 Completion flow: macOS notification on session end; success state with safe-to-eject message; distinct failure state listing failed files, no safe-to-eject claim (spec: menu-bar-ui / Completion notification)
- [x] 4.6 "Reveal in Finder" action on the destination after completion (resolves design Open Question 1)
- [x] 4.7 Surface session abort reason distinctly in the failure state: card ejected vs destination disconnected vs destination full (spec: menu-bar-ui / Aborted session shows distinct reason)

## 5. Verification and polish

- [ ] 5.1 End-to-end manual test: real SD card → destination, verify manifest hashes with `md5 -r` independently, pull card mid-copy to confirm abort behavior and `.kopi-tmp` cleanup
- [x] 5.2 Disk-usage audit: confirm no payload data outside the destination (no caches, no Application Support copies) (spec: menu-bar-ui / No hidden storage)
- [x] 5.3 Validate change: `openspec validate add-sd-backup-tool` and review against specs
