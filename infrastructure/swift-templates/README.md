# Swift config templates for HC_storage (RHEL / sw-* hosts).
# Copy onto the VMs AFTER openstack-swift packages are installed.
# These are starting points — IPs and hash suffix must match your lab.

# Nodes:
#   sw-proxy  172.30.201.247  — proxy + TempAuth + memcached + ring builder
#   sw-hot    172.30.201.248  — object policy 0 (hot) only
#   sw-cold   172.30.201.249  — object policy 1 (cold) only
#
# Device name in rings: d1  (loopback or real disk mounted at /srv/node/d1)

## Files in this directory

| File | Install on |
|---|---|
| `swift.conf` | all three |
| `proxy-server.conf` | sw-proxy |
| `rsyncd.conf` | sw-hot, sw-cold |
| `account-server.conf` | sw-hot, sw-cold |
| `container-server.conf` | sw-hot, sw-cold |
| `object-server.conf` | sw-hot, sw-cold |

Do not start services until rings exist (later milestone).
