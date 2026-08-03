# HC_storage — VirtualBox Inventory (Phase 0)

## Host-Only network

| Setting | Value |
|---|---|
| Adapter | `vboxnet0` |
| Host IP | `192.168.56.1` |
| Netmask | `255.255.255.0` |
| DHCP | Disabled (guests use static IPs) |

Each VM has:

- **NIC1** — NAT (internet / `apt`)
- **NIC2** — Host-Only `vboxnet0` (cluster traffic)

## Virtual machines

| VM | Hostname (set at install) | RAM | vCPU | System disk | Data disk | Host-Only IP |
|---|---|---|---|---|---|---|
| `proxy-01` | `proxy-01` | 2048 MB | 1 | 20 GB | — | `192.168.56.10` |
| `hot-01` | `hot-01` | 1536 MB | 1 | 30 GB | 10 GB | `192.168.56.11` |
| `cold-01` | `cold-01` | 1536 MB | 1 | 30 GB | 15 GB | `192.168.56.12` |
| `mgmt-01` | `mgmt-01` | 1536 MB | 1 | 20 GB | — | `192.168.56.20` |

VM files: `~/VirtualBox VMs/<name>/`  
Installer ISO: `~/iso/ubuntu-22.04.5-live-server-amd64.iso`  
Create/re-attach script: [`create_vms.sh`](create_vms.sh)

## Install Ubuntu Server 22.04 (interactive)

Do one VM at a time (RAM is limited on the host).

```bash
# After ISO download finishes, refresh DVD attach:
~/Desktop/HC_storage/infrastructure/create_vms.sh

VBoxManage startvm proxy-01 --type gui
```

During install, for each VM:

1. Hostname = table above (`proxy-01`, etc.)
2. Create a user (e.g. `swiftlab`) with SSH allowed
3. Install **OpenSSH server**
4. Disks:
   - Use the **system** disk for Ubuntu (`/`)
   - On `hot-01` / `cold-01`, leave the **second disk unused** for now (Swift data disk later → `/srv/node/sdb1`)
5. After first boot, configure Host-Only static IP (netplan). Example for `proxy-01` (`enp0s8` is usually NIC2):

```yaml
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: true
    enp0s8:
      dhcp4: false
      addresses: [192.168.56.10/24]
```

6. `/etc/hosts` on every guest (and on the host):

```
192.168.56.10 proxy-01
192.168.56.11 hot-01
192.168.56.12 cold-01
192.168.56.20 mgmt-01
```

7. From the host, verify: `ping 192.168.56.10` and `ssh swiftlab@192.168.56.10`

## Useful commands

```bash
VBoxManage list vms
VBoxManage list hostonlyifs
VBoxManage startvm proxy-01 --type gui
VBoxManage controlvm proxy-01 poweroff
```
