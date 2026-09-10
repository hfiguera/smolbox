#!/usr/bin/env bash
# Maintainer experiment confined to the disposable nested Linux guest.
set -euo pipefail
[[ $EUID == 0 && $(hostname) == smolbox-nested && $(systemd-detect-virt) == kvm ]] || exit 1
root=/srv/smolbox-cleanup
unit=smolbox-cleanup.service
action=${1:?Expected prepare, start, restart, stop, or metrics}

stop_worker() {
  if systemctl cat "$unit" >/dev/null 2>&1; then systemctl stop "$unit"; fi
  for ((i=0; i<50; i++)); do
    if ! pgrep -u smolbox-cleanup >/dev/null; then return 0; fi
    sleep 0.1
  done
  echo 'Owned worker processes remain.' >&2
  exit 1
}

case "$action" in
  prepare)
    [[ ! -e $root ]] || { echo 'Refusing to overwrite an existing experiment.' >&2; exit 1; }
    archive=/home/lab/input/smolvm-1.14.6-linux-x86_64.tar.gz
    printf '%s  %s\n' 94a1edb0c42b20ac562c3759ed216bab2cab9e27c382f6560969144f7bd1dce3 "$archive" | sha256sum --check
    useradd --system --user-group --home-dir "$root/home" --shell /usr/sbin/nologin smolbox-cleanup
    install -d -m 0755 "$root"
    install -d -o smolbox-cleanup -g lab -m 0770 "$root/home" "$root/data" "$root/run"
    install -d -m 0755 /opt/smolbox/cleanup-runtime-1.14.6
    tar -xzf "$archive" --strip-components=1 -C /opt/smolbox/cleanup-runtime-1.14.6
    zstd --decompress --sparse /opt/smolbox/cleanup-runtime-1.14.6/storage-template.ext4.zst
    zstd --decompress --sparse /opt/smolbox/cleanup-runtime-1.14.6/overlay-template.ext4.zst
    # Keep both registry and VM data on this single bounded filesystem. The
    # previous separated-metadata deployment cannot reproduce this regression.
    mount -t tmpfs -o size=536870912,mode=0770,nodev,nosuid,uid="$(id -u smolbox-cleanup)",gid="$(id -g lab)" smolbox-cleanup "$root/data"
    mount -t tmpfs -o size=4194304,mode=0770,nodev,nosuid,uid="$(id -u smolbox-cleanup)",gid="$(id -g lab)" smolbox-cleanup-run "$root/run"
    ;;
  start)
    version=${2:?Expected 1.14.1 or 1.14.6}
    case "$version" in
      1.14.1) runtime=/opt/smolbox/runtime ;;
      1.14.6) runtime=/opt/smolbox/cleanup-runtime-1.14.6 ;;
      *) exit 1 ;;
    esac
    stop_worker
    [[ $(findmnt -n -o SOURCE --target "$root/data") == smolbox-cleanup ]] || exit 1
    [[ $(findmnt -n -o FSTYPE --target "$root/data") == tmpfs ]] || exit 1
    [[ ! -L $root/data && ! -L $root/run ]] || exit 1
    # This is explicit reset of this experiment's state after process teardown,
    # never evidence that an API delete succeeded.
    find "$root/data" "$root/run" -xdev -mindepth 1 -delete
    cat > "/run/systemd/system/$unit" <<UNIT
[Unit]
Description=SmolVM shared storage cleanup regression
ConditionVirtualization=kvm
[Service]
Type=exec
User=smolbox-cleanup
Group=lab
SupplementaryGroups=kvm
Environment=HOME=$root/home
Environment=SMOLVM_DATA_DIR=$root/data
Environment=XDG_DATA_HOME=$root/data
Environment=XDG_CACHE_HOME=$root/data
Environment=SMOLVM_VM_UID_DROP=off
Environment=SMOLVM_DISABLE_SHARED_EXTRACT=1
Environment=SMOLVM_FILE_TRANSFER_MAX_BYTES=1048576
ExecStart=$runtime/smolvm serve start --listen unix://$root/run/api.sock
RuntimeMaxSec=300s
TimeoutStopSec=5s
KillMode=control-group
Restart=no
OOMPolicy=stop
MemoryMax=2G
MemorySwapMax=0
CPUQuota=200%
TasksMax=128
LimitCORE=0
UMask=0007
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$root
ReadOnlyPaths=/opt/smolbox/runtime /opt/smolbox/cleanup-runtime-1.14.6 /opt/smolbox/catalog
TemporaryFileSystem=/tmp:rw,size=32M,mode=1777 /var/tmp:rw,size=32M,mode=1777
PrivateNetwork=yes
InaccessiblePaths=/run/dbus/system_bus_socket
DevicePolicy=closed
DeviceAllow=/dev/kvm rw
StandardOutput=journal
StandardError=journal
LogRateLimitIntervalSec=30s
LogRateLimitBurst=100
UNIT
    systemctl daemon-reload
    systemctl reset-failed "$unit" 2>/dev/null || true
    systemctl start "$unit"
    ;;
  restart)
    # Preserve the full data filesystem and its registry across this restart.
    stop_worker
    systemctl start "$unit"
    ;;
  stop) stop_worker ;;
  metrics)
    stat -f -c '%S %b %f %a' "$root/data"
    ;;
  *) exit 1 ;;
esac
