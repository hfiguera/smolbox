#!/usr/bin/env bash
# Administrative setup inside the disposable guest, never on the physical host.
set -euo pipefail
[[ $(uname -s) == Linux && $(hostname) == smolbox-nested && $EUID == 0 ]] || exit 1
[[ $(systemd-detect-virt) == kvm && -c /dev/kvm ]] || exit 1
scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=/srv/sbq
id smolbox-qual >/dev/null 2>&1 || useradd --system --user-group --home-dir "$root/home" \
  --shell /usr/sbin/nologin smolbox-qual
usermod -a -G kvm smolbox-qual
usermod -a -G smolbox-qual lab
mkdir -p "$root"/{home,control,cache,run} /home/lab/qualification /usr/local/libexec
chown lab:lab /home/lab/qualification
chmod 0700 /home/lab/qualification
chown smolbox-qual:smolbox-qual "$root/home" "$root/run"
chmod 0750 "$root/home"
chmod 0770 "$root/run"
for item in control:64M cache:768M run:4M; do
  path=$root/${item%:*}
  if ! mountpoint -q "$path"; then
    [[ -z $(ls -A "$path") ]] || { echo 'Refusing to cover existing data.' >&2; exit 1; }
    mode=0700
    [[ ${item%:*} != run ]] || mode=0770
    mount -t tmpfs -o "size=${item#*:},mode=$mode,uid=$(id -u smolbox-qual),gid=$(id -g smolbox-qual),nodev,nosuid,noexec" \
      smolbox-qualification "$path"
  fi
done
install -m 0755 "$scripts/worker-preflight.sh" /usr/local/libexec/smolbox-qualification-preflight
install -m 0755 "$scripts/candidate-policy.sh" /usr/local/libexec/smolbox-qualification-policy
install -m 0755 "$scripts/candidate-capture.sh" /usr/local/libexec/smolbox-qualification-capture
install -m 0644 "$scripts/smolbox-qualification.service" /etc/systemd/system/smolbox-qualification.service
systemd-analyze verify /etc/systemd/system/smolbox-qualification.service
systemctl daemon-reload
printf 'qualification-host-file-canary\n' > /etc/smolbox-qualification-canary
chmod 0600 /etc/smolbox-qualification-canary
echo 'Candidate installed; no execution started.'
