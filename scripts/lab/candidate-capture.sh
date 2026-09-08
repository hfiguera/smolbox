#!/usr/bin/env bash
# Trusted systemd stop hook retains counters before the cgroup disappears.
set -euo pipefail
[[ $(hostname) == smolbox-nested && $EUID == 0 ]] || exit 1
report=/run/smolbox-qualification-evidence
group=/sys/fs/cgroup/system.slice/smolbox-qualification.service
mkdir -p "$report"
chmod 0700 "$report"
printf '%s\n' "${SERVICE_RESULT:-unknown}" > "$report/result"
for metric in memory.peak memory.events cpu.stat pids.events; do
  if [[ -r $group/$metric ]]; then
    cat "$group/$metric" > "$report/$metric"
  else
    printf 'unavailable\n' > "$report/$metric"
  fi
done
