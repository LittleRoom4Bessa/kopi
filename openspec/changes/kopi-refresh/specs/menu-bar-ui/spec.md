# Spec: menu-bar-ui (delta)

## MODIFIED Requirements

### Requirement: Manual source and destination selection
The system SHALL provide folder pickers for the user to manually assign the source (e.g., a mounted SD volume) and the destination folder. Each selection SHALL be displayed as a disk card showing the disk-intelligence characterization (volume name, type, bus, capacity/free, interface speed class) with an explicit Speed Test action. Both selections SHALL be persisted across app launches. The Start action SHALL be unavailable until both paths are set and valid.

#### Scenario: First launch
- **WHEN** the app opens with no stored paths
- **THEN** both pickers are empty and the Start action is disabled

#### Scenario: Paths remembered
- **WHEN** the user previously selected source and destination and relaunches the app
- **THEN** both paths are pre-filled from the previous session and their disk cards re-characterize the volumes

#### Scenario: Selected source disappears
- **WHEN** the stored source path no longer exists (card not inserted)
- **THEN** the UI indicates the source is unavailable and Start is disabled

### Requirement: Live progress
The system SHALL show per-file and overall copy progress (current filename, files completed of total, bytes copied of total) during an active session. In casual mode progress appears in the popover; during a pro session the popover SHALL show condensed aggregate progress across all destinations while the pro panel shows per-destination progress.

#### Scenario: Casual copy in progress
- **WHEN** a casual session is running and 40 of 100 files are complete
- **THEN** the popover shows the current filename, 40/100 files, and corresponding byte progress

#### Scenario: Pro session condensed progress
- **WHEN** a pro session is running with 3 destinations
- **THEN** the popover shows aggregate file/byte progress and a per-destination status summary, without expanding to full pro-panel detail

## ADDED Requirements

### Requirement: Pro mode expansion
The system SHALL provide a pro mode toggle in the popover that expands the popover in place to reveal pro configuration (3 destination disk cards, hash picker, strict toggle, rule badges, per-destination progress). The expanded/collapsed state SHALL persist across launches. Collapsing pro mode SHALL NOT interrupt a running session; the collapsed popover continues to show condensed progress.

#### Scenario: Expand pro mode
- **WHEN** the user activates the pro mode toggle
- **THEN** the popover widens and reveals the 3 destination pickers and pro settings, without opening any new window

#### Scenario: Collapse mid-session
- **WHEN** the user collapses pro mode while a session runs
- **THEN** the session continues and the collapsed popover still shows condensed progress and completion state
