#!/usr/bin/env bash
# Run on ssh linux after both warmups, with the pinned toolchain on PATH.
# Both workers must be dedicated, independently bounded, and empty.
set -euo pipefail
[[ $(uname -s) == Linux && $(hostname) == pop-os ]] || exit 1
bench=${1:?Expected direct worker directory}
nested=${2:?Expected nested worker directory}
guest=${3:?Expected host-side guest SSH helper}
for path in "$bench" "$nested" "$guest"; do
  [[ $path =~ ^/[a-zA-Z0-9/_.-]+$ ]] || exit 1
done
export MIX_ENV=prod ERL_FLAGS='+S 2:2'
cd "$bench/consumer"
for sample in 1 2 3 4 5 6; do
  if (( sample % 2 )); then order='direct nested'; else order='nested direct'; fi
  for label in $order; do
    date -u +%FT%TZ
    test "$(du -sm "$bench" | cut -f1)" -lt 8192
    test "$(df -Pm "$bench" | awk 'NR==2 {print $4}')" -gt 8192
    outer=$(systemctl show smolbox-lab@test.service -p ControlGroup --value)
    [[ $outer == /system.slice/*/smolbox-lab@test.service ]] || exit 1
    cat "/sys/fs/cgroup$outer/cpu.stat" > "$bench/$label-$sample-outer-before.txt"
    cat /proc/loadavg > "$bench/$label-$sample-load-before.txt"
    if [[ $label == direct ]]; then
      timeout -k 10 480 mix run ../nested-kvm.exs "$bench" direct "$sample"
    else
      bash "$guest" "set -eu; source /etc/profile.d/smolbox-lab.sh; export MIX_ENV=prod ERL_FLAGS='+S 2:2'; test \"\$(du -sm $nested | cut -f1)\" -lt 8192; cd $nested/consumer; timeout -k 10 480 mix run ../nested-kvm.exs $nested nested $sample"
    fi
    cat "/sys/fs/cgroup$outer/cpu.stat" > "$bench/$label-$sample-outer-after.txt"
  done
done
