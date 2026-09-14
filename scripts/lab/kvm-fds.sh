#!/usr/bin/env bash
# Inspect one explicitly owned account inside the disposable guest.
set -euo pipefail
[[ $(uname -s) == Linux && $(hostname) == smolbox-nested && $EUID == 0 ]] || exit 1
account=${1:-smolbox-worker}
case "$account" in smolbox-worker|smolbox-qual|smolbox-cleanup|lab) ;; *) exit 1 ;; esac
id "$account" >/dev/null
for pid in $(pgrep -u "$account"); do
  for descriptor in /proc/"$pid"/fd/*; do
    target=$(readlink "$descriptor") || continue
    case "$target" in
      /dev/kvm|anon_inode:kvm*) printf '%s %s\n' "$descriptor" "$target" ;;
    esac
  done
done
