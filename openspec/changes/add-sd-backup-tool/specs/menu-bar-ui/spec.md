# Spec: menu-bar-ui

## ADDED Requirements

### Requirement: Menu bar presence
The system SHALL run as a macOS menu bar agent (no Dock icon) presenting a status item that opens the app's control panel.

#### Scenario: App launch
- **WHEN** the app launches
- **THEN** a status item appears in the menu bar and no icon appears in the Dock

### Requirement: Manual source and destination selection
The system SHALL provide folder pickers for the user to manually assign the source (e.g., a mounted SD volume) and the destination folder. Both selections SHALL be persisted across app launches. The Start action SHALL be unavailable until both paths are set and valid.

#### Scenario: First launch
- **WHEN** the app opens with no stored paths
- **THEN** both pickers are empty and the Start action is disabled

#### Scenario: Paths remembered
- **WHEN** the user previously selected source and destination and relaunches the app
- **THEN** both paths are pre-filled from the previous session

#### Scenario: Selected source disappears
- **WHEN** the stored source path no longer exists (card not inserted)
- **THEN** the UI indicates the source is unavailable and Start is disabled

### Requirement: Pre-copy summary
The system SHALL display the planned file count and total byte size (after junk filtering) before copying begins.

#### Scenario: Both paths selected
- **WHEN** valid source and destination are set
- **THEN** the panel shows the scannable file count and total size, and Start becomes available

### Requirement: Live progress
The system SHALL show per-file and overall copy progress (current filename, files completed of total, bytes copied of total) during an active session.

#### Scenario: Copy in progress
- **WHEN** a session is running and 40 of 100 files are complete
- **THEN** the panel shows the current filename, 40/100 files, and corresponding byte progress

### Requirement: Completion notification and safe-to-eject state
The system SHALL send a macOS notification when a session ends and SHALL present a distinct completion state indicating the backup is verified and the card is safe to eject. Sessions ending with failures SHALL present a visually distinct state from fully successful sessions.

#### Scenario: Fully successful session
- **WHEN** all files verify
- **THEN** a notification fires and the panel shows a success state with a safe-to-eject message

#### Scenario: Session with failures
- **WHEN** any file fails verification or the session aborts
- **THEN** the panel shows a failure state listing failed files and does NOT claim the card is safe to eject

#### Scenario: Aborted session shows distinct reason
- **WHEN** a session aborts because the card was ejected, the destination volume disconnected, or the destination became full
- **THEN** the failure state names the specific abort reason

### Requirement: No hidden storage
The system SHALL NOT create intermediate copies, caches, or backups of payload data anywhere other than the user-selected destination (including Application Support). Persisted app state SHALL be limited to preferences (selected paths).

#### Scenario: Disk usage audit
- **WHEN** a session of 12 GB completes
- **THEN** the only payload bytes written are the 12 GB at the destination plus the manifest file, and no app-managed copies exist elsewhere
