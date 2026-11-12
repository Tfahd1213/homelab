# Backups and restore testing (planned)

> **Status: planned, not set up yet.** A backup only counts once a restore has been tested.

## Why
After a power cut, an unplugged cable took the whole lab offline. Nothing was lost that time,
but a dead disk would have wiped every container and its configuration. Backups fix that.

## Plan

### 1. Backup storage
- [ ] Add a second disk (or a USB drive) to the Proxmox host and create a `backups` directory storage on it
- [ ] Later: off-site copies to Backblaze B2 (free for the first 10 GB)

### 2. Scheduled backup job
- [ ] Datacenter → Backup → Add
  - Storage: `backups`
  - Schedule: weekly, Sunday 03:00
  - Selection: all containers and VMs
  - Mode: **Snapshot** (no downtime for LXC)
  - Compression: ZSTD
  - Retention: keep the last 4 weekly backups
  - Notifications: on failure
- [ ] Run the job once by hand and check that every guest finished with status `OK`

### 3. Restore test
- [ ] Restore the Uptime Kuma backup to a **new** container ID (so the live one isn't touched)
- [ ] Give it a free IP, start it, and confirm the monitors and settings are all there
- [ ] Record how long the restore took
- [ ] Delete the test container

### 4. Before risky changes
- [ ] Take a manual snapshot before Proxmox upgrades or big container changes

## Results
To be filled in after the first restore test: backup sizes, job duration, restore time and anything that went wrong.
