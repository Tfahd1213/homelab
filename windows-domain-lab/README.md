# Windows domain lab

> **Status: in progress.** The isolated lab network and the DC01 VM are built, with
> Windows Server 2025 installed. Active Directory, DNS, DHCP, the client, GPOs and file
> shares are next. Checkboxes are ticked only for work that's done.

A Windows Server domain controller with Active Directory, DNS and DHCP, a domain-joined
Windows client, Group Policies and a permissioned file share, all running on Proxmox.

## Design

```
 Home network 10.0.0.0/24 (Rogers gateway)
          │
   Proxmox host ── vmbr0 (home LAN, plugged into nic0)
          │
          └─ vmbr1: isolated lab network 192.168.50.0/24, NAT to the internet through the host
                ├─ DC01   Windows Server 2025 (eval): AD DS, DNS, DHCP   192.168.50.10 (planned)
                ├─ WS01   Windows 11 Enterprise (eval), domain-joined     DHCP (planned)
                └─ WS02   optional second client, only when RAM allows    DHCP (planned)
```

**Why a separate network:** a Windows DHCP server on the home network would compete with
the router and could give family devices wrong addresses. `vmbr1` has no physical port, so
lab DHCP never leaves the lab. The Proxmox host NATs it to the internet for updates.

**RAM budget (12 GB host, ~3 GB already in use):** DC01 gets 3 GB with ballooning down to
2 GB, and WS01 will get 4 GB. A second client only runs while WS01 is off.

## What I've done so far

### 1. Isolated lab network ✅
I backed up `/etc/network/interfaces`, then added a bridge with no physical port and a NAT rule:

```
auto vmbr1
iface vmbr1 inet static
        address 192.168.50.1/24
        bridge-ports none
        bridge-stp off
        bridge-fd 0
        post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
        post-up   iptables -t nat -A POSTROUTING -s 192.168.50.0/24 -o vmbr0 -j MASQUERADE
        post-down iptables -t nat -D POSTROUTING -s 192.168.50.0/24 -o vmbr0 -j MASQUERADE
```

I was working remotely over Tailscale, so before running `ifreload -a` I checked with `grep`
that the existing `vmbr0`/`nic0` lines were intact (a bad config there would have cut off
my only way in). Afterwards I verified:
- `ip -br a show vmbr1` showed `192.168.50.1/24`
- `iptables -t nat -S POSTROUTING` showed the `MASQUERADE` rule
- `/proc/sys/net/ipv4/ip_forward` was `1`

### 2. Installers ✅
I checked free space first (`df -h`, `pvesm status`), then downloaded straight onto the
Proxmox ISO store with `wget`, so nothing went through my laptop:
- `virtio-win.iso` (Fedora's stable VirtIO drivers, 837 MB)
- `WinServer2025-eval.iso` (Microsoft Evaluation Center, 7.6 GB). Before downloading,
  I checked the link's redirect target and size with `curl -I`.

### 3. DC01 VM ✅
I built it from the command line:

```bash
qm create 103 --name DC01 --ostype win11 --cores 2 --cpu host --memory 3072 --balloon 2048
qm set 103 --scsihw virtio-scsi-single --scsi0 local-lvm:60,discard=on,iothread=1,ssd=1
qm set 103 --net0 virtio,bridge=vmbr1
qm set 103 --ide2 local:iso/WinServer2025-eval.iso,media=cdrom
qm set 103 --ide0 local:iso/virtio-win.iso,media=cdrom
qm set 103 --boot 'order=ide2;scsi0'
qm set 103 --agent enabled=1
```

- **VirtIO SCSI disk and network** for performance; this is why the driver ISO is attached.
- **`--ostype win11`** pins the machine version, so Proxmox upgrades don't make Windows think its hardware changed.
- **`discard=on`** returns deleted space to the thin pool.
- **NIC on `vmbr1` only.**

### 4. Windows Server 2025 install ✅
- Setup couldn't see the disk until I loaded the `vioscsi\2k25\amd64` driver from the VirtIO ISO.
- I installed **Windows Server 2025 Standard Evaluation (Desktop Experience)**.
- Then I ran `virtio-win-guest-tools.exe` to add the network, balloon and QEMU guest agent drivers.

## Problems I hit

**Installed the wrong edition.** The first install came up as a text-only console
(`LogonUI.exe`, then SConfig) because I'd picked the first image in the list, which is
**Server Core**. Core is a valid choice for a domain controller, but for learning AD and Group
Policy for the first time I wanted the GUI tools. I reinstalled and picked the
**(Desktop Experience)** image. Setup then showed the old Core install's three partitions
(system, Windows, recovery), which I deleted to start from unallocated space.

**Missed the "Press any key to boot from CD" prompt.** The prompt only lasts a few
seconds. Opening the VM console *before* starting the VM, then resetting it to try again when I
missed it, solved it. After setup started, I had to *not* press a key on later reboots, or the
installer would start over.

**First login hung on a black `tzsync.exe` window.** Its title said "Select", which means a
click in the console had put the window in QuickEdit selection mode, pausing the process.
Pressing Esc resumed it and the desktop loaded.

**Console looked dead after a few hours.** The noVNC console had disconnected while idle;
the VM itself was still running. Reconnecting the console fixed it.

## Still to do

### Domain controller
- [ ] Snapshot DC01 as a clean save point before promoting it
- [ ] Rename to `DC01`; static IP `192.168.50.10`, gateway `192.168.50.1`, DNS `127.0.0.1`
- [ ] Install AD DS and promote to a new forest: `lab.local`
- [ ] DNS: add a forwarder to `1.1.1.1` and check the reverse lookup zone
- [ ] DHCP: scope `192.168.50.100–200`, options for router (`.1`) and DNS (`.10`); authorize in AD

### Client
- [ ] Create WS01: UEFI (OVMF), TPM 2.0, 2 cores, 4 GB RAM, 60 GB disk, on `vmbr1`
- [ ] Install Windows 11 Enterprise and confirm it gets a DHCP lease from DC01
- [ ] Join `lab.local` and log in with a domain account

### Users, groups and OUs
- [ ] OUs: `Staff` (with `Sales`, `IT`, `Finance`), `Workstations`, `Disabled Users`
- [ ] Move WS01 into `Workstations`
- [ ] Create users and groups, and run the [onboarding scripts](../powershell-onboarding/) against a real domain

### Group Policy
- [ ] Password policy: 12+ characters, complexity, lockout after 5 attempts (Default Domain Policy)
- [ ] Drive mapping: `S:` to the shared folder for the matching department group (Group Policy Preferences)
- [ ] Block USB storage on `Workstations` (Removable Storage Access policies)
- [ ] Test each one with `gpupdate /force` and `gpresult /r` on WS01

### File share
- [ ] Create `\\DC01\Shares\<Department>` folders
- [ ] Share permissions: Authenticated Users = Change. NTFS: each department group = Modify on its own folder only
- [ ] Test that a Sales user can open Sales but not Finance

### Write-up
- [ ] Screenshots: ADUC tree, DHCP leases, GPO results, access-denied test

## License timers
Windows Server evaluation: 180 days from install. Windows 11 Enterprise evaluation: 90 days.
