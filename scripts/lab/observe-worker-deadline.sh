#!/usr/bin/env bash
# Observe only the disposable candidate; never shorten its real unit deadline.
set -euo pipefail
[[ $(hostname) == smolbox-nested && $EUID == 0 && $(systemd-detect-virt) == kvm ]] || exit 1
unit=smolbox-qualification.service
[[ $(systemctl show "$unit" -p RuntimeMaxUSec --value) == 5min ]] || exit 1
started=$(systemctl show "$unit" -p ActiveEnterTimestampMonotonic --value)
[[ $started =~ ^[0-9]+$ ]] || exit 1
observe_after=$((started / 1000000 + 270))
samples=0
while systemctl is-active --quiet "$unit"; do
  read -r uptime _idle < /proc/uptime
  if (( ${uptime%.*} >= observe_after )); then
    if boundary=$(bash /opt/smolbox/source/scripts/lab/vm-boundary.sh); then
      samples=$((samples+1))
      printf 'uptime=%s %s\n' "$uptime" "${boundary%%$'\n'*}"
    else
      # Unit shutdown can race the read. A missing VM while the unit remains
      # active is a failed observation, not evidence that its deadline killed it.
      ! systemctl is-active --quiet "$unit" || exit 1
    fi
  fi
  sleep 1
done
(( samples > 0 )) || exit 1
result=$(systemctl show "$unit" -p Result --value)
[[ $result == timeout ]] || exit 1
printf 'live_vm_samples=%s\nresult=%s\n' "$samples" "$result"
