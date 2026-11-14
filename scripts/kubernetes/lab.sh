#!/usr/bin/env bash
# Copy this directory to ~/smolbox-kubernetes-lab on ssh linux before use.
set -euo pipefail
umask 077
[[ $(uname -s) == Linux && $(hostname) == pop-os && $EUID != 0 ]] || {
  echo 'Run this script through ssh linux, as the lab operator.' >&2; exit 1;
}
scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ $scripts == "$HOME/smolbox-kubernetes-lab" ]] || exit 1
lab=/var/lib/smolbox-lab
root=$lab/kubernetes
unit=smolbox-kubernetes-lab.service
action=${1:?Usage: lab.sh prepare|start|install|install-preview|sync|smoke|qualify|ssh|status|stop}
shift

guest_ssh() {
  ssh -F /dev/null -i "$root/id_ed25519" -p 22470 \
    -o BatchMode=yes -o IdentitiesOnly=yes -o ForwardAgent=no \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$root/known_hosts" \
    -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 lab@127.0.0.1 "$@"
}

guest_copy() {
  scp -F /dev/null -i "$root/id_ed25519" -P 22470 \
    -o BatchMode=yes -o IdentitiesOnly=yes -o ForwardAgent=no \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$root/known_hosts" "$@"
}

sync_scripts() {
  guest_ssh 'mkdir -p /home/lab/smolbox-kubernetes/reports'
  guest_copy "$scripts/"{install-node.sh,install-preview.sh,offline_guard.py,smoke.py,pins.json,preview-policy.json,qualify.py,websocket_probe.py,source-basis.json,runtime-rbac.yaml} \
    lab@127.0.0.1:/home/lab/smolbox-kubernetes/
}

download() {
  local pin=$2 max=$3 target=$root/$1
  local sha url
  sha=$(jq -r ".$pin.sha256" "$scripts/pins.json")
  url=$(jq -r ".$pin.url" "$scripts/pins.json")
  if [[ ! -f $target ]]; then
    curl --fail --location --proto '=https' --proto-redir '=https' \
      --max-time 900 --max-filesize "$max" --output "$target.part" "$url"
    printf '%s  %s\n' "$sha" "$target.part" | sha256sum --check
    mv "$target.part" "$target"
  fi
  printf '%s  %s\n' "$sha" "$target" | sha256sum --check
}

case "$action" in
  prepare)
    [[ $(findmnt -n -o LABEL --target "$lab") == smolbox-lab && -w /dev/kvm ]] || exit 1
    exec 9>"$lab/vm.lock"
    flock -n 9 || { echo 'Stop the other lab VM before preparation.' >&2; exit 1; }
    if [[ ! -e $root ]]; then
      (( $(df -B1 --output=avail "$lab" | tail -1) > 50 * 1024 * 1024 * 1024 )) || exit 1
      mkdir -m 0700 "$root"
      id -un > "$root/owner"
      cp "$scripts/pins.json" "$root/prepared-pins.json"
    fi
    [[ ! -L $root && $(cat "$root/owner") == "$(id -un)" ]] || exit 1
    cmp "$scripts/pins.json" "$root/prepared-pins.json"
    base=$lab/images/ubuntu-24.04-server-cloudimg-amd64.img
    printf '%s  %s\n' "$(jq -r .cloud_image.sha256 "$scripts/pins.json")" "$base" | sha256sum --check
    download k3s k3s 268435456
    download smolvm.tar.gz smolvm 134217728
    if [[ ! -f $root/id_ed25519 ]]; then
      ssh-keygen -q -t ed25519 -N '' -C smolbox-kubernetes-lab -f "$root/id_ed25519"
    fi
    if [[ ! -e $root/node.qcow2 ]]; then
      cat > "$root/user-data" <<YAML
#cloud-config
hostname: smolbox-k3s
manage_etc_hosts: true
users:
  - name: lab
    groups: [adm, sudo]
    shell: /bin/bash
    lock_passwd: true
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - $(cat "$root/id_ed25519.pub")
disable_root: true
ssh_pwauth: false
runcmd:
  - [systemctl, disable, --now, apt-daily.timer, apt-daily-upgrade.timer]
YAML
      printf 'instance-id: smolbox-kubernetes-%s\nlocal-hostname: smolbox-k3s\n' \
        "$(date -u +%Y%m%dT%H%M%SZ)" > "$root/meta-data"
      cloud-localds "$root/cloud-init.iso" "$root/user-data" "$root/meta-data"
      qemu-img create -f qcow2 -F qcow2 -b "$base" "$root/node.qcow2" 40G
    fi
    mkdir -p "$HOME/.config/systemd/user"
    service=$HOME/.config/systemd/user/$unit
    if [[ -e $service ]]; then
      grep -Fqx '# Managed by SmolBox Kubernetes lab' "$service" || exit 1
    fi
    cat > "$service" <<UNIT
# Managed by SmolBox Kubernetes lab
[Unit]
Description=Disposable SmolBox Kubernetes development node
[Service]
Type=exec
ExecStart=$scripts/vm.sh
WorkingDirectory=$root
RuntimeMaxSec=4h
TimeoutStopSec=20s
KillMode=control-group
Restart=no
CPUQuota=400%
MemoryMax=12G
MemorySwapMax=0
TasksMax=256
LimitFSIZE=42G
LimitCORE=0
UMask=0077
UNIT
    systemd-analyze --user verify "$service"
    systemctl --user daemon-reload
    echo 'Prepared a separate 40 GiB disk; no VM started.'
    ;;
  start)
    [[ $(cat "$root/owner") == "$(id -un)" ]] || exit 1
    if systemctl --user is-failed --quiet "$unit"; then
      systemctl --user reset-failed "$unit"
    fi
    systemctl --user start "$unit"
    ;;
  install)
    until guest_ssh true 2>/dev/null; do
      (( SECONDS < 180 )) || { echo 'Guest SSH startup timed out.' >&2; exit 1; }
      sleep 2
    done
    guest_ssh 'cloud-init status --wait >/dev/null'
    sync_scripts
    guest_copy "$root/"{k3s,smolvm.tar.gz} \
      lab@127.0.0.1:/home/lab/smolbox-kubernetes/
    guest_ssh 'sudo bash /home/lab/smolbox-kubernetes/install-node.sh'
    ;;
  sync) sync_scripts ;;
  install-preview)
    sync_scripts
    guest_ssh 'sudo bash /home/lab/smolbox-kubernetes/install-preview.sh'
    ;;
  smoke|qualify)
    run_id=$action-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM
    status=0
    guest_ssh "sudo python3 /home/lab/smolbox-kubernetes/$action.py --report /home/lab/smolbox-kubernetes/reports/$run_id.json" || status=$?
    guest_copy "lab@127.0.0.1:/home/lab/smolbox-kubernetes/reports/$run_id.json" "$root/$run_id.json" || status=1
    if [[ -f $root/$run_id.json ]]; then
      cp "$root/$run_id.json" "$root/$action.json"
    fi
    exit "$status"
    ;;
  ssh) guest_ssh "$@" ;;
  status)
    systemctl --user show "$unit" -p ActiveState -p SubState -p MainPID -p Result \
      -p RuntimeMaxUSec -p MemoryMax -p MemorySwapMax -p CPUQuotaPerSecUSec -p TasksMax
    ;;
  stop)
    if systemctl --user is-active --quiet "$unit"; then
      guest_ssh 'sudo systemctl poweroff' >/dev/null 2>&1 || true
      for _attempt in {1..20}; do
        systemctl --user is-active --quiet "$unit" || break
        sleep 1
      done
    fi
    systemctl --user stop "$unit"
    ;;
  *) echo "Unknown action: $action" >&2; exit 1 ;;
esac
