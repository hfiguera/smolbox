#!/usr/bin/env bash
# Negative startup tests inside the disposable guest; no untrusted code runs.
set -euo pipefail
[[ $(hostname) == smolbox-nested && $EUID == 0 && $(systemd-detect-virt) == kvm ]] || exit 1
scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
unit=smolbox-qualification.service
dropin=/run/systemd/system/$unit.d/90-negative.conf
artifact=/opt/smolbox/catalog/node.smolmachine
backup=/run/smolbox-qualification-node.backup
report=/home/lab/qualification/admission.txt
[[ ! -e $dropin && ! -e $backup ]] || exit 1

restore() {
  systemctl stop "$unit"
  if [[ -f $backup ]]; then mv "$backup" "$artifact"; fi
  rm -f "$dropin"
  systemctl set-property --runtime "$unit" MemoryMax=1536M
  systemctl daemon-reload
  bash "$scripts/install-candidate.sh"
}
trap restore EXIT
bash "$scripts/candidate-control.sh" stop
: > "$report"

reject() {
  if systemctl start "$unit"; then
    echo 'Unsafe candidate unexpectedly started.' >&2
    exit 1
  fi
  # A deliberately bad Restart policy must not leave a queued start behind.
  systemctl stop "$unit"
  [[ $(systemctl show "$unit" -p MainPID --value) == 0 ]] || exit 1
  systemctl show "$unit" -p Result -p ExecStartPre >> "$report"
  if systemctl is-failed --quiet "$unit"; then systemctl reset-failed "$unit"; fi
}

systemctl set-property --runtime "$unit" MemoryMax=2G
reject
systemctl set-property --runtime "$unit" MemoryMax=1536M
printf 'weaker-memory: rejected\n' >> "$report"

mkdir -p "$(dirname "$dropin")"
printf '[Service]\nEnvironment=SMOLVM_LANDLOCK=off\n' > "$dropin"
systemctl daemon-reload
reject
rm "$dropin"
systemctl daemon-reload
printf 'disabled-landlock: rejected\n' >> "$report"

printf '[Service]\nPrivateNetwork=no\n' > "$dropin"
systemctl daemon-reload
reject
rm "$dropin"
systemctl daemon-reload
printf 'missing-private-network: rejected\n' >> "$report"

for setting in RuntimeMaxSec:0 KillMode:process Restart:always CPUQuota:200% TasksMax:192 MemorySwapMax:1G; do
  printf '[Service]\n%s=%s\n' "${setting%:*}" "${setting#*:}" > "$dropin"
  systemctl daemon-reload
  reject
  rm "$dropin"
  systemctl daemon-reload
  printf '%s: rejected\n' "$setting" >> "$report"
done

cp --preserve=all "$artifact" "$backup"
printf 'qualification-corruption' >> "$artifact"
reject
mv "$backup" "$artifact"
printf 'altered-artifact: rejected\n' >> "$report"

umount /srv/sbq/cache
reject
bash "$scripts/install-candidate.sh"
printf 'missing-storage-boundary: rejected\n' >> "$report"
bash "$scripts/candidate-control.sh" start
printf 'restored-worker: healthy\n' >> "$report"
bash "$scripts/candidate-control.sh" stop
chown lab:lab "$report"
chmod 0600 "$report"
