# Spec: disk-intelligence

## ADDED Requirements

### Requirement: Disk characterization
The system SHALL characterize any user-selected volume via DiskArbitration/IOKit and present: volume name, disk type (SD card, external SSD, HDD, internal SSD, or network volume), connection bus (USB, SD, Thunderbolt, NVMe, or network), total capacity, and free space. Each field that cannot be determined SHALL render explicitly as "Unknown" and SHALL NOT block selection or copying.

#### Scenario: SD card in USB reader selected
- **WHEN** the user selects a mounted SD card in a USB-C reader
- **THEN** the disk card shows the volume name, type "SD card", bus "USB", total capacity, and current free space

#### Scenario: Network volume selected
- **WHEN** the user selects an SMB-mounted volume
- **THEN** the disk card shows type "Network volume" and bus "Network", with capacity and free space from the mount

#### Scenario: Metadata unavailable
- **WHEN** DiskArbitration returns no bus or type information for a volume
- **THEN** the affected fields show "Unknown" and the volume remains usable as a source or destination

### Requirement: Interface speed class display
The system SHALL display the theoretical speed class of the volume's connection (e.g., "USB 3.2 · up to ~10 Gbps", "SD UHS-II · up to ~300 MB/s") immediately upon selection, clearly labeled as an interface ceiling rather than a measured speed. No benchmark SHALL run automatically.

#### Scenario: Volume selected
- **WHEN** a volume with a known bus class is selected and no probe has been run
- **THEN** the disk card shows the interface ceiling labeled as theoretical, and no probe activity has occurred

### Requirement: On-demand speed probe
The system SHALL provide an explicit Speed Test action per disk card. For destination volumes the probe SHALL write a temporary test file (~256 MB), time the write, re-read it bypassing the OS page cache, time the read, then delete the file. For source volumes the probe SHALL be read-only (read an existing region of volume data bypassing the page cache); the system SHALL NOT write to a source volume under any circumstances. The probe SHALL be cancellable and its results labeled as measured values.

#### Scenario: Destination speed test
- **WHEN** the user clicks Speed Test on a destination disk card
- **THEN** measured write and read speeds appear, labeled as measured, and no probe file remains on the volume afterward

#### Scenario: Source speed test
- **WHEN** the user clicks Speed Test on a source disk card
- **THEN** a measured read speed appears and nothing is written to the source volume

#### Scenario: Probe cancelled
- **WHEN** the user cancels a running probe
- **THEN** the probe stops, any temporary probe file is deleted, and no result is recorded

### Requirement: Physical media identity
The system SHALL derive a stable media identity for each volume: for local volumes, the whole-disk identifier (partition stripped, e.g. `disk4s1` → `disk4`) resolved via DiskArbitration; for network volumes, the server-and-share identity of the mount. Two volumes on the same physical disk SHALL have the same identity; a network volume's identity SHALL differ from any local disk identity.

#### Scenario: Two partitions of one SSD
- **WHEN** two destination folders live on different volumes of the same physical SSD
- **THEN** both resolve to the same media identity

#### Scenario: Local disk vs NAS share
- **WHEN** one destination is on an internal NVMe volume and another is an SMB mount
- **THEN** the two resolve to distinct media identities
