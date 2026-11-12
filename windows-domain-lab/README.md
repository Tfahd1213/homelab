# Windows domain lab (planned)

> **Status: planned, not built yet.** This is the build plan. Checkboxes get ticked,
> and screenshots and notes added, as each part is done.

A Windows Server domain controller with Active Directory, DNS and DHCP, a domain-joined
Windows client, Group Policies and a permissioned file share, all running on Proxmox.

## Design

```
 Home network 10.0.0.0/24 (Rogers gateway)
          │
   Proxmox host ── vmbr0 (home LAN)
          │
          └─ vmbr1: isolated lab network 192.168.50.0/24, NAT to the internet through the host
                ├─ DC01   Windows Server 2025 (eval): AD DS, DNS, DHCP   192.168.50.10
                ├─ WS01   Windows 11 Enterprise (eval), domain-joined     DHCP
                └─ WS02   optional second client, only when RAM allows    DHCP
```

**Why a separate network:** a Windows DHCP server on the home network would compete with
the router and could give family devices wrong addresses. `vmbr1` has no physical port, so
lab DHCP never leaves the lab. The Proxmox host NATs it to the internet for updates.

**RAM budget (12 GB host, ~3 GB already in use):** DC01 3 GB + WS01 4 GB. WS02 only runs
while WS01 is off, or as Windows 10 with 2 GB. Ballooning is enabled on every VM.

## Build plan

### 1. Lab network
- [ ] Create `vmbr1` (no bridge port) with `192.168.50.1/24` on the Proxmox host
- [ ] Enable IP forwarding and a NAT (masquerade) rule from `vmbr1` out through `vmbr0`
- [ ] Download the Windows Server 2025 and Windows 11 Enterprise evaluation ISOs and the VirtIO drivers ISO

### 2. Domain controller
- [ ] Create DC01: 2 cores, 3 GB RAM, 60 GB disk, VirtIO SCSI and network, on `vmbr1`
- [ ] Install Windows Server (Desktop Experience), loading the VirtIO storage driver during setup
- [ ] Set a static IP `192.168.50.10`, gateway `192.168.50.1`, DNS `127.0.0.1`
- [ ] Install AD DS and promote to a new forest: `lab.local`
- [ ] DNS: add a forwarder to `1.1.1.1` and check the reverse lookup zone
- [ ] DHCP: scope `192.168.50.100–200`, options for router (`.1`) and DNS (`.10`); authorize in AD

### 3. Client
- [ ] Create WS01: UEFI (OVMF), TPM 2.0, 2 cores, 4 GB RAM, 60 GB disk, on `vmbr1`
- [ ] Install Windows 11 Enterprise and confirm it gets a DHCP lease from DC01
- [ ] Join `lab.local` and log in with a domain account

### 4. Users, groups and OUs
- [ ] OUs: `Staff` (with `Sales`, `IT`, `Finance`), `Workstations`, `Disabled Users`
- [ ] Move WS01 into `Workstations`
- [ ] Create users and groups (or test the [onboarding script](../powershell-onboarding/))

### 5. Group Policy
- [ ] Password policy: 12+ characters, complexity, lockout after 5 attempts (Default Domain Policy)
- [ ] Drive mapping: `S:` to the shared folder for the matching department group (Group Policy Preferences)
- [ ] Block USB storage on `Workstations` (Removable Storage Access policies)
- [ ] Test each one with `gpupdate /force` and `gpresult /r` on WS01

### 6. File share
- [ ] Create `\\DC01\Shares\<Department>` folders
- [ ] Share permissions: Authenticated Users = Change. NTFS: each department group = Modify on its own folder only
- [ ] Test that a Sales user can open Sales but not Finance

### 7. Write-up
- [ ] Screenshots: ADUC tree, DHCP leases, GPO results, access-denied test
- [ ] Problems I hit and how I fixed them

## License timers
Windows Server evaluation: 180 days. Windows 11 Enterprise evaluation: 90 days.
Screenshots and notes need to be done before they expire. Rebuilding is good practice anyway.
