#!/usr/bin/env bash
# Root preflight checks the effective supervisor policy before the worker starts.
set -euo pipefail
[[ $(hostname) == smolbox-nested && $EUID == 0 && $(systemd-detect-virt) == kvm ]] || exit 1
unit=smolbox-qualification.service
for setting in RuntimeMaxUSec:5min TimeoutStopUSec:5s KillMode:control-group \
  SendSIGKILL:yes Restart:no OOMPolicy:stop; do
  [[ $(systemctl show "$unit" -p "${setting%:*}" --value) == "${setting#*:}" ]] || exit 1
done
