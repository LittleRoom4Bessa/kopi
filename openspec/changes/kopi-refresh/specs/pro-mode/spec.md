# Spec: pro-mode

## ADDED Requirements

### Requirement: Three destination assignment
In pro mode the system SHALL require the user to assign exactly 3 destination folders before a copy can start, and SHALL persist all 3 across launches. Assigning the same folder twice, or a folder on the source's physical disk, SHALL be a hard error that blocks Start regardless of strict mode. "3 copies" means 3 destination folders; the source card does not count.

#### Scenario: Fewer than 3 destinations assigned
- **WHEN** only 2 of the 3 destination slots are filled
- **THEN** Start is disabled and the empty slot is visibly called out

#### Scenario: Duplicate folder
- **WHEN** two destination slots resolve to the same folder
- **THEN** an error identifies the duplicate and Start is disabled in both warn and strict modes

#### Scenario: Destination on source disk
- **WHEN** a destination folder resolves to the same physical media identity as the source
- **THEN** an error explains the destination is on the source disk and Start is disabled in both modes

### Requirement: Hash algorithm selection
Pro mode SHALL offer xxHash64 (default, labeled "fast verify") and SHA-256 (labeled "forensic") for per-file verification. The selected algorithm SHALL be used for source-stream hashing, destination re-read comparison, and the session manifest. Casual mode SHALL continue to use MD5 and is unaffected by this setting.

#### Scenario: Default selection
- **WHEN** the user enters pro mode and has never chosen an algorithm
- **THEN** xxHash64 is selected and labeled as the fast default

#### Scenario: Forensic selection
- **WHEN** the user selects SHA-256 and runs a session
- **THEN** all verification hashes and manifest entries for that session use SHA-256

### Requirement: Media diversity rules
The system SHALL evaluate the 3 assigned destinations against 3-2-1 media rules using physical media identity, and surface violations as badges naming the specific disks involved:
- Two destinations sharing one physical disk: warn-level violation
- No network volume among the 3 destinations: warn-level violation (labeled "network/remote" — the system detects network mounts, not physical offsite location)

In warn mode (default) violations SHALL NOT block Start. In strict mode (opt-in toggle, default off) any warn-level violation SHALL disable Start with an explanation.

#### Scenario: Same-disk destinations in warn mode
- **WHEN** two destinations share one physical disk and strict mode is off
- **THEN** a warning badge names the shared disk and Start remains available

#### Scenario: Same-disk destinations in strict mode
- **WHEN** two destinations share one physical disk and strict mode is on
- **THEN** Start is disabled and the message names the shared disk and the violated rule

#### Scenario: No network destination in strict mode
- **WHEN** all 3 destinations are local disks and strict mode is on
- **THEN** Start is disabled with a message that no network/remote destination is assigned

### Requirement: Pro configuration persistence
The system SHALL persist pro mode settings across launches: the 3 destination folders, hash algorithm choice, and strict mode toggle state.

#### Scenario: Relaunch
- **WHEN** the user configured 3 destinations, SHA-256, and strict mode, then relaunches the app
- **THEN** all settings are restored exactly, with unavailable volumes indicated as such
