#!/usr/bin/env bash
# Root preflight checks the effective supervisor policy before the worker starts.
set -euo pipefail
[[ $(hostname) == smolbox-nested && $EUID == 0 && $(systemd-detect-virt) == kvm ]] || exit 1
unit=smolbox-qualification.service
# Only the explicit long-execution campaign extends the outer worker deadline.
# CPU, memory, task, filesystem and isolation controls are unchanged.
case ${SMOLBOX_QUALIFICATION_SECONDS:-300} in
  300) deadline=5min ;;
  900) deadline=15min ;;
  *) exit 1 ;;
esac
for setting in RuntimeMaxUSec:$deadline TimeoutStopUSec:5s KillMode:control-group \
  SendSIGKILL:yes Restart:no OOMPolicy:stop; do
  [[ $(systemctl show "$unit" -p "${setting%:*}" --value) == "${setting#*:}" ]] || exit 1
done
