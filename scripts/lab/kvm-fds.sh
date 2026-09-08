#!/usr/bin/env bash
# Inspect only the disposable guest's dedicated worker, while its one VM runs.
set -euo pipefail
[[ $(uname -s) == Linux && $(hostname) == smolbox-nested && $EUID == 0 ]] || exit 1
for pid in $(pgrep -u smolbox-worker); do
  for descriptor in /proc/"$pid"/fd/*; do
    target=$(readlink "$descriptor") || continue
    case "$target" in
      /dev/kvm|anon_inode:kvm*) printf '%s %s\n' "$descriptor" "$target" ;;
    esac
  done
done
