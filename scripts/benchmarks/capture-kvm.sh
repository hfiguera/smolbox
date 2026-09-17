#!/usr/bin/env bash
# Inspect only the explicitly owned worker cgroup, never other host workloads.
set -euo pipefail
group=${1:?Expected worker cgroup path}
[[ $(uname -s) == Linux && $group == /sys/fs/cgroup/*/smolbox-benchmark.service ]] || exit 1
while read -r pid; do
  for fd in /proc/"$pid"/fd/*; do
    target=$(readlink "$fd" || true)
    case "$target" in *kvm-vm*|*kvm-vcpu*) printf '%s %s\n' "$pid" "$target" ;; esac
  done
done < <(find "$group" -name cgroup.procs -exec cat {} +)
