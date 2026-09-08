#!/usr/bin/env bash
# Run only on the authorized Linux host, with interactive sudo.
set -euo pipefail
umask 077

[[ $(uname -s) == Linux && $(uname -m) == x86_64 && $EUID == 0 ]] || {
  echo 'Requires root on the authorized x86_64 Linux host.' >&2; exit 1;
}
operator=${1:?Usage: sudo bash install-host.sh OPERATOR}
[[ $operator =~ ^[a-z_][a-z0-9_-]*$ && $operator != root ]] || exit 1
id "$operator" >/dev/null
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for name in launch-vm.sh smolbox-lab@.service; do
  [[ -f $source_dir/$name && ! -L $source_dir/$name ]] || exit 1
done

account=smolbox-lab
volume=/var/lib/smolbox-lab
backing=/var/lib/smolbox-lab-store.img
config=/etc/smolbox-lab

# Refuse to adopt a pre-existing account or storage from another installation.
if [[ ! -f $config/owner ]]; then
  for path in "$config" "$volume" "$backing"; do
    [[ ! -e $path && ! -L $path ]] || { echo "Already exists: $path" >&2; exit 1; }
  done
  ! getent passwd "$account" >/dev/null || exit 1
  ! getent group "$account" >/dev/null || exit 1
  install -d -m 0700 "$config"
  printf '%s\n' "$operator" > "$config/owner"
fi
[[ $(cat "$config/owner") == "$operator" ]] || exit 1
[[ -c /dev/kvm && $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] || exit 1
[[ $(cat /sys/module/kvm_intel/parameters/nested 2>/dev/null) == Y ]] || {
  echo 'This host recipe requires the already-enabled Intel nested KVM configuration.' >&2
  exit 1
}

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
  qemu-system-x86 qemu-utils cloud-image-utils socat jq shellcheck

if ! getent passwd "$account" >/dev/null; then
  useradd --system --user-group --no-create-home --home-dir "$volume/home" \
    --shell /usr/sbin/nologin "$account"
fi
[[ $(getent passwd "$account" | cut -d: -f6) == "$volume/home" ]] || exit 1
usermod -a -G kvm "$account"
usermod -a -G "$account" "$operator"

if [[ ! -f $backing ]]; then
  available=$(df -B1 --output=avail /var/lib | tail -1 | tr -d ' ')
  (( available >= 192 * 1024 * 1024 * 1024 )) || {
    echo 'Need 128 GiB for the lab plus at least 64 GiB left free on the host.' >&2; exit 1;
  }
  # Real allocation prevents a sparse backing file from exhausting unrelated storage later.
  fallocate -l 128G "$backing"
  chmod 0600 "$backing"
  mkfs.ext4 -q -E nodiscard -m 1 -L smolbox-lab "$backing"
fi
[[ ! -L $backing && $(stat -c %U "$backing") == root ]] || exit 1
[[ $(stat -c %s "$backing") == 137438953472 ]] || exit 1
[[ $(blkid -s LABEL -o value "$backing") == smolbox-lab ]] || exit 1
# Also repair a reservation if an older mkfs discarded its preallocated extents.
# fallocate preserves existing bytes; it allocates holes without rewriting data.
fallocate -l 128G "$backing"
(( $(stat -c %b "$backing") * 512 >= 137438953472 )) || exit 1
install -d -m 0700 "$volume"
fstab_line="$backing $volume ext4 loop,nodev,nosuid,noexec 0 0"
if ! grep -Fqx "$fstab_line" /etc/fstab; then
  ! grep -Fq "$volume" /etc/fstab || { echo 'Conflicting fstab entry.' >&2; exit 1; }
  printf '%s\n' "$fstab_line" >> /etc/fstab
fi
systemctl daemon-reload
mountpoint -q "$volume" || mount "$volume"
[[ $(findmnt -n -o LABEL --target "$volume") == smolbox-lab ]] || exit 1
chown "$account:$account" "$volume"
chmod 2770 "$volume"
for directory in home images seed evidence staging; do
  install -d -o "$account" -g "$account" -m 2770 "$volume/$directory"
done

# systemd executes only this root-owned launcher. Writable lab files are data.
install -d -m 0755 /usr/local/libexec/smolbox-lab
install -m 0755 "$source_dir/launch-vm.sh" /usr/local/libexec/smolbox-lab/launch-vm
install -m 0644 "$source_dir/smolbox-lab@.service" /etc/systemd/system/smolbox-lab@.service
for mode in test probe; do
  install -d -m 0755 "/etc/systemd/system/smolbox-lab@$mode.service.d"
  deadline=45min
  [[ $mode != probe ]] || deadline=30s
  printf '[Service]\nRuntimeMaxSec=%s\n' "$deadline" \
    > "/etc/systemd/system/smolbox-lab@$mode.service.d/deadline.conf"
done

# Narrow operations for this lab only; no shell, arbitrary units, or QEMU arguments.
sudoers_tmp=$(mktemp)
trap 'rm -f "$sudoers_tmp"' EXIT
for mode in provision test probe; do
  for action in start stop reset-failed; do
    printf '%s ALL=(root) NOPASSWD: /usr/bin/systemctl %s smolbox-lab@%s.service\n' \
      "$operator" "$action" "$mode" >> "$sudoers_tmp"
  done
done
printf '%s ALL=(root) NOPASSWD: /usr/bin/systemctl kill --signal=STOP smolbox-lab@probe.service\n' \
  "$operator" >> "$sudoers_tmp"
visudo -cf "$sudoers_tmp"
install -m 0440 "$sudoers_tmp" /etc/sudoers.d/smolbox-lab
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/smolbox-lab@.service
dpkg-query -W qemu-system-x86 qemu-utils cloud-image-utils socat jq shellcheck \
  > "$config/packages.txt"
echo "Host setup installed. Reconnect SSH to obtain membership in $account. No VM started."
