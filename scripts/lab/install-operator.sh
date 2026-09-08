#!/usr/bin/env bash
# Unprivileged installation on ssh linux after the administrator's bootstrap.
set -euo pipefail
[[ $(uname -s) == Linux && $EUID != 0 ]] || exit 1
scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ $scripts == /home/humberto/smolbox-lab-bootstrap ]] || exit 1
unit_dir=$HOME/.config/systemd/user
mkdir -p "$unit_dir"
for unit in smolbox-lab-recovery.service smolbox-lab-recovery.timer; do
  if [[ -e $unit_dir/$unit ]]; then
    grep -q 'Managed by SmolBox lab scripts' "$unit_dir/$unit" || {
      echo "Refusing to overwrite unrelated $unit" >&2; exit 1;
    }
  fi
done
cat > "$unit_dir/smolbox-lab-recovery.service" <<UNIT
# Managed by SmolBox lab scripts
[Unit]
Description=Rebuild a stopped disposable SmolBox lab
[Service]
Type=oneshot
# The already-running user manager may predate the new group membership.
# sg activates the administrator-granted group without restarting other workloads.
ExecStart=/usr/bin/sg smolbox-lab -c "/usr/bin/bash $scripts/recovery-sweep.sh"
TimeoutStartSec=90s
MemoryMax=512M
MemorySwapMax=0
CPUQuota=25%
TasksMax=32
LimitCORE=0
StandardOutput=null
StandardError=null
UNIT
cat > "$unit_dir/smolbox-lab-recovery.timer" <<'UNIT'
# Managed by SmolBox lab scripts
[Unit]
Description=Recover stopped SmolBox lab without guest access
[Timer]
OnActiveSec=15s
OnUnitActiveSec=15s
AccuracySec=1s
[Install]
WantedBy=timers.target
UNIT
systemd-analyze --user verify "$unit_dir/smolbox-lab-recovery.service" "$unit_dir/smolbox-lab-recovery.timer"
systemctl --user daemon-reload
loginctl --no-ask-password enable-linger "$(id -un)"
[[ $(loginctl show-user "$(id -un)" -p Linger --value) == yes ]] || exit 1
systemctl --user enable --now smolbox-lab-recovery.timer
echo 'Recovery timer installed. Physical-host systemd still enforces each VM deadline.'
