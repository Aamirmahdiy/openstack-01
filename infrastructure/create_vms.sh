#!/usr/bin/env bash
# Create the 4 HC_storage VirtualBox VMs (NAT + Host-Only) and attach Ubuntu ISO.
set -euo pipefail

ISO="${ISO:-/home/amir/iso/ubuntu-22.04.5-live-server-amd64.iso}"
VM_ROOT="${VM_ROOT:-$HOME/VirtualBox VMs}"
HOSTONLY_IF="${HOSTONLY_IF:-vboxnet0}"

mkdir -p "$VM_ROOT"

ensure_sata() {
  local name="$1"
  if VBoxManage showvminfo "$name" | grep -q 'Storage Controller Name ([0-9]*): *SATA'; then
    return 0
  fi
  VBoxManage storagectl "$name" --name "SATA" --add sata --controller IntelAhci --portcount 4 --bootable on
}

create_disk_if_needed() {
  local path="$1" size_mb="$2"
  if [[ ! -f "$path" ]]; then
    VBoxManage createmedium disk --filename "$path" --size "$size_mb" --format VDI
  fi
}

attach_hdd() {
  local name="$1" path="$2" port="$3"
  # Detach empty medium on port if needed, then attach
  VBoxManage storageattach "$name" \
    --storagectl "SATA" \
    --port "$port" \
    --device 0 \
    --type hdd \
    --medium "$path"
}

attach_dvd() {
  local name="$1"
  if [[ ! -f "$ISO" ]]; then
    echo "WARN: ISO missing ($ISO) — start VMs after download finishes"
    return 0
  fi
  VBoxManage storageattach "$name" \
    --storagectl "SATA" \
    --port 3 \
    --device 0 \
    --type dvddrive \
    --medium "$ISO"
}

create_vm() {
  local name="$1" memory_mb="$2" cpus="$3" sys_mb="$4" data_mb="${5:-0}"
  local vm_dir="$VM_ROOT/$name"
  mkdir -p "$vm_dir"

  if VBoxManage showvminfo "$name" &>/dev/null; then
    echo "SKIP exists: $name"
  else
    echo "CREATE $name (RAM=${memory_mb}MB CPUs=${cpus})"
    VBoxManage createvm --name "$name" --ostype "Ubuntu_64" --register --basefolder "$VM_ROOT"
  fi

  VBoxManage modifyvm "$name" \
    --memory "$memory_mb" \
    --cpus "$cpus" \
    --vram 16 \
    --ioapic on \
    --boot1 dvd \
    --boot2 disk \
    --boot3 none \
    --boot4 none \
    --rtcuseutc on \
    --graphicscontroller vmsvga \
    --audio none \
    --usb off

  VBoxManage modifyvm "$name" \
    --nic1 nat \
    --nictype1 82540EM \
    --cableconnected1 on \
    --nic2 hostonly \
    --hostonlyadapter2 "$HOSTONLY_IF" \
    --nictype2 82540EM \
    --cableconnected2 on

  ensure_sata "$name"

  create_disk_if_needed "$vm_dir/${name}-system.vdi" "$sys_mb"
  # Attach system disk only if not already attached
  if ! VBoxManage showvminfo "$name" | grep -q "${name}-system.vdi"; then
    attach_hdd "$name" "$vm_dir/${name}-system.vdi" 0
  fi

  if [[ "$data_mb" -gt 0 ]]; then
    create_disk_if_needed "$vm_dir/${name}-data.vdi" "$data_mb"
    if ! VBoxManage showvminfo "$name" | grep -q "${name}-data.vdi"; then
      attach_hdd "$name" "$vm_dir/${name}-data.vdi" 1
    fi
  fi

  # Attach ISO if not already
  if [[ -f "$ISO" ]] && ! VBoxManage showvminfo "$name" | grep -q 'ubuntu-22.04'; then
    attach_dvd "$name"
  elif [[ -f "$ISO" ]]; then
    # Refresh attach (idempotent enough for re-runs)
    VBoxManage storageattach "$name" --storagectl "SATA" --port 3 --device 0 --type dvddrive --medium "$ISO" 2>/dev/null || true
  else
    echo "WARN: $name has no ISO yet"
  fi

  echo "OK $name"
}

# Plan inventory
create_vm "proxy-01" 2048 1 20480 0
create_vm "hot-01"   1536 1 30720 10240
create_vm "cold-01"  1536 1 30720 15360
create_vm "mgmt-01"  1536 1 20480 0

echo
echo "=== VMs ==="
VBoxManage list vms
echo
echo "=== Host-Only ==="
VBoxManage list hostonlyifs | grep -E '^(Name|IPAddress|NetworkMask|Status|DHCP):'
echo
echo "ISO present: $([[ -f $ISO ]] && echo yes || echo no) ($ISO)"
