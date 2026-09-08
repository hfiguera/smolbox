#!/usr/bin/env bash
# Sample live dedicated-account processes during a separately running campaign.
# This is observation evidence, not atomic attestation of every process lifetime.
set -euo pipefail
[[ $(hostname) == smolbox-nested && $EUID == 0 && $(systemd-detect-virt) == kvm ]] || exit 1
report=/home/lab/qualification/descendants-observation.txt
observed=0
for ((sample=0; sample<600; sample++)); do
  while read -r pid; do
    [[ -r /proc/$pid/status && -r /proc/$pid/cgroup ]] || continue
    state=$(awk '/^State:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)
    group=$(cat "/proc/$pid/cgroup" 2>/dev/null || true)
    [[ -n $state && $state != Z && -n $group ]] || continue
    if [[ $group != 0::/system.slice/smolbox-qualification.service ]]; then
      printf 'FAIL pid=%s state=%s cgroup=%s\n' "$pid" "$state" "$group" > "$report"
      exit 1
    fi
    observed=$((observed+1))
  done < <(pgrep -u smolbox-qual || true)
  sleep 0.5
done
[[ $observed -gt 0 ]] || { echo 'No live worker processes observed.' >&2; exit 1; }
printf 'PASS samples=%s live-process-observations=%s\n' "$sample" "$observed" > "$report"
chown lab:lab "$report"
chmod 0600 "$report"
cat "$report"
