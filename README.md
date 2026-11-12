# Home Lab

A self-hosted home server I built from a spare ASUS desktop to learn system administration, networking and containers. It runs Proxmox VE and hosts DNS filtering, remote access, monitoring and a fitness tracker for my phone.

## Projects

| Project | Status |
|---|---|
| Proxmox host with Pi-hole, Tailscale, Uptime Kuma and Docker (this page) | ✅ Running |
| [PowerShell onboarding and offboarding scripts](powershell-onboarding/) | 📝 Written, not yet tested |
| [Windows domain lab](windows-domain-lab/): AD, DNS, DHCP, GPO, file shares | 🗓️ Planned |
| [Backups and restore testing](backups/) | 🗓️ Planned |

## Architecture

```
               Home network (router / DHCP)
                            │
         ┌──────────────────┴──────────────────┐
         │  ASUS desktop: Proxmox VE           │
         │  (hypervisor, static IP)            │
         │                                     │
         │  ┌─────────────┐  ┌─────────────┐   │
         │  │ Pi-hole     │  │ Uptime Kuma │   │
         │  │ + Tailscale │  │ (LXC)       │   │
         │  │ (LXC)       │  └─────────────┘   │
         │  └─────────────┘                    │
         │  ┌───────────────────────────────┐  │
         │  │ Docker (LXC)                  │  │
         │  │  wger: web, PostgreSQL, Redis,│  │
         │  │  Celery, nginx, PowerSync     │  │
         │  └───────────────────────────────┘  │
         └─────────────────────────────────────┘
              │                         │
     Tailscale (remote access)    ntfy.sh (alerts)
              │                         │
          Phone / laptop away from home
```

## Services

| Service | Runs in | What it does |
|---|---|---|
| **Proxmox VE** | Bare metal | Hypervisor that manages every container, with a web UI for administration |
| **Pi-hole** | LXC container | DNS server that blocks ad, tracker and telemetry domains for devices that use it |
| **Tailscale** | Pi-hole container and Proxmox host | WireGuard-based VPN. A subnet route gives secure access to the whole lab from anywhere without opening any router ports |
| **Uptime Kuma** | LXC container | Monitors Proxmox, Pi-hole's web UI and DNS, and wger, and sends phone push notifications through ntfy when anything goes down |
| **wger** | Docker Compose in an LXC container | Workout and nutrition tracker made of six containers (Django web app, PostgreSQL, Redis, Celery worker and scheduler, nginx, PowerSync), synced with the wger iPhone app |

## Setup

1. **Installed Proxmox VE** by writing the ISO to a USB drive in DD mode with Rufus, enabling CPU virtualization in the BIOS, and replacing Windows.
2. **Configured networking:** a static IP for the host in `/etc/network/interfaces`, with the matching entry in `/etc/hosts`.
3. **Created containers** with the [Proxmox VE community scripts](https://community-scripts.github.io/ProxmoxVE/), choosing LXC over full VMs to keep RAM use low.
4. **Deployed wger** by cloning the official `wger-project/docker` Compose stack and setting the site URL, trusted CSRF origins and time zone in `config/prod.env`.

## Problems I solved

**Proxmox unreachable after setup.** The web UI refused connections, and the server couldn't ping the router, even though my laptop could ping its IP. Comparing MAC addresses with `arp` on the laptop and `ip a` on the server showed that another device on the network already had that IP. I moved the server to a free address and noted that it needs a DHCP reservation.

**Server couldn't resolve domain names.** Downloads failed with `Could not resolve host`. `ping 1.1.1.1` worked but `ping google.com` didn't, so it was DNS, not connectivity. `/etc/resolv.conf` showed that Tailscale had replaced the server's DNS with `100.100.100.100`. I fixed it with `tailscale set --accept-dns=false` and set upstream DNS servers in Proxmox.

**Pi-hole wasn't blocking anything.** Querying Pi-hole directly showed it was blocking ad domains correctly, but devices were still using the ISP's DNS. The ISP gateway wouldn't let me change its DNS settings, so each device has to be pointed at Pi-hole individually.

**Container ran out of disk space.** wger's images didn't fit in the default 4 GB root disk, so I resized the container's disk in Proxmox (`pct resize`) and confirmed it with `df -h`.

**Phone app said "sync server unreachable".** The website worked, but the PowerSync service kept restarting. Reading `docker compose logs` turned up a database authentication error. I ran the skipped setup step (`manage.py setup-powersync-storage`), then restarted nginx, which had cached the old address of the crashing service. After that, all six containers stayed up and the app synced.

**Whole lab offline after a power cut.** The router was back but nothing in the lab answered. A ping sweep of the subnet from my laptop showed the Proxmox host and all its containers missing, not just one service. On the server's console, `ip -br a` showed the physical interface `nic0` as down, and pinging the router got 0 replies. The Ethernet cable had come out of the back of the router. After reseating it, every service came back. To make it survive the next outage on its own, the plan is to set the BIOS to power on after AC loss and enable "Start at boot" on each container.

**Monitoring Proxmox's HTTPS UI.** Uptime Kuma flagged Proxmox as down because of its self-signed certificate. I allowed that certificate for the internal check only.

## Security choices

- **No ports are forwarded on the router.** Remote access goes only through Tailscale.
- **Docker's TCP socket isn't exposed.** I declined the installer option that would have allowed unauthenticated remote control of Docker.
- The ntfy topic uses a long random name, since topics on the public ntfy.sh server are readable by anyone who guesses them.

## Next steps

- Set up scheduled Proxmox backups and test a restore ([plan](backups/))
- Build the Windows domain lab ([plan](windows-domain-lab/)) and test the [onboarding scripts](powershell-onboarding/) in it
- Power on after AC loss in the BIOS, and "Start at boot" for every container
- Add a reverse proxy (Nginx Proxy Manager) with local DNS names
