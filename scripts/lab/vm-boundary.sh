#!/usr/bin/env bash
set -euo pipefail
[[ $(hostname) == smolbox-nested && $EUID == 0 && $(systemd-detect-virt) == kvm ]] || exit 1
found=0
while read -r pid; do
  [[ -r /proc/$pid/cgroup ]] || continue
  [[ $(cat "/proc/$pid/cgroup") == 0::/system.slice/smolbox-qualification.service ]] || exit 1
  vm=0
  for fd in /proc/"$pid"/fd/*; do
    target=$(readlink "$fd" 2>/dev/null || true)
    [[ $target != anon_inode:kvm-vm ]] || vm=1
  done
  if [[ $vm == 1 ]]; then
    found=$((found+1))
    printf 'VMM PID %s\n' "$pid"
    for thread in /proc/"$pid"/task/*; do
      [[ -r $thread/status ]] || continue
      awk '/^(NoNewPrivs|Seccomp|Seccomp_filters|CapEff):/ { print }' "$thread/status"
      awk '/^NoNewPrivs:/ {n=$2} /^Seccomp:/ {s=$2} /^CapEff:/ {c=$2} END {exit !(n==1 && s==2 && c=="0000000000000000")}' "$thread/status"
    done
  fi
done < <(pgrep -u smolbox-qual)
[[ $found == 1 ]] || { echo 'Expected exactly one real KVM process.' >&2; exit 1; }
