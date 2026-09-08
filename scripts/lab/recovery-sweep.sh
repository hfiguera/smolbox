#!/usr/bin/env bash
set -euo pipefail
umask 007
[[ $(uname -s) == Linux && $EUID != 0 ]] || exit 1
lab=/var/lib/smolbox-lab
[[ $(findmnt -n -o LABEL --target "$lab") == smolbox-lab && -w $lab/staging && -w $lab/evidence ]] || exit 1
[[ -f $lab/staging/recovery-required ]] || exit 0
# Bound this fixed diagnostic file; payload/test output has its own Elixir cap.
ulimit -f 16384
exec > "$lab/evidence/recovery-last.log" 2>&1
read -r mode < "$lab/staging/recovery-required"
case "$mode" in test|probe) ;; *) exit 1 ;; esac
unit=smolbox-lab@$mode.service
scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
state=$(systemctl show "$unit" -p ActiveState --value)
case "$state" in
  inactive|failed) ;;
  *)
    if ! bash "$scripts/labctl.sh" capture "$mode"; then
      echo 'Guest control is unavailable; retained the last successful bounded capture.'
    fi
    exit 0
    ;;
esac
[[ $(systemctl show "$unit" -p MainPID --value) == 0 ]] || exit 1

# Fixed evidence slots, independent of the guest's disk, worker, DB and SSH.
bash "$scripts/labctl.sh" status "$mode" > "$lab/evidence/$mode-recovery-status.txt"
bash "$scripts/labctl.sh" reset "$mode" > "$lab/evidence/$mode-rebuild.txt"
qemu-img info --output=json "$lab/images/run.qcow2" > "$lab/evidence/$mode-rebuilt-image.json"
date -u +%FT%TZ > "$lab/evidence/$mode-recovered-at.txt"
rm "$lab/staging/recovery-required"
# A replacement disk is ready. No guest command or test is automatically replayed.
