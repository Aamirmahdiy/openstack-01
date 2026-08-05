# HC_storage — Company VM Inventory (M0 — verified)

## Cluster topology (live)

Use these names **everywhere** (SSH, `/etc/hosts`, Swift configs, docs).

| Role | Hostname | IP | SSH user | OS |
|---|---|---|---|---|
| Proxy + TempAuth + rings + tierer | `sw-proxy` | `172.30.201.247` | `bbdh` | RHEL 10.2 |
| **Only** Hot storage node | `sw-hot` | `172.30.201.248` | `bbdh` | RHEL 10.2 |
| **Only** Cold storage node | `sw-cold` | `172.30.201.249` | `bbdh` | RHEL 10.2 |

- Host workstation: Ubuntu 22.04 (`10.60.20.70`), SSH key `~/.ssh/id_ed25519`
- Do **not** commit VM passwords into this repo

## Disks

No second disk yet. Pending: loopback XFS at `/srv/node/d1` **or** attach real disks.

## Blockers before Swift install (M1+)

- RHEL: no enabled `dnf` repos until subscription / Satellite / mirror is configured
- Data device on `sw-hot` / `sw-cold` not created yet

## M0 status

- [x] SSH key auth (`ssh sw-proxy` / `sw-hot` / `sw-cold`)
- [x] `/etc/hosts` on VMs with `sw-*` names
- [x] Chrony enabled; clocks synchronized
- [ ] dnf repos
- [ ] data path (loopback or real disk)

## Host-side work (can proceed while VMs blocked)

- Ingest generate + age check (existing)
- Dual Hot uploaders: [`ingest/upload_hot_cli.sh`](../ingest/upload_hot_cli.sh), [`ingest/upload_hot_api.py`](../ingest/upload_hot_api.py)
- Env example: [`config/hc_storage.env.example`](../config/hc_storage.env.example)
- Swift config templates: [`infrastructure/swift-templates/`](swift-templates/)
