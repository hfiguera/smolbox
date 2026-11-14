#!/usr/bin/env bash
# Administrator-only evidence infrastructure inside the disposable node.
set -euo pipefail
umask 077
[[ $EUID == 0 && $(hostname) == smolbox-k3s && $(systemd-detect-virt) == kvm ]] || exit 1
scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ $scripts == /home/lab/smolbox-kubernetes ]] || exit 1
target=/usr/local/lib/smolbox-kubernetes/node-history
# Never replace an enrolled inspector or reset a history epoch. Its existing
# source must match before a repeated setup can even touch the program files.
files=(node_lifecycle.py node_history.py node_inspector.py offline_guard.py qualify.py smoke.py websocket_probe.py)
if [[ -e /var/lib/smolbox-kubernetes/node-history-enrollment.json ]]; then
  for name in "${files[@]}"; do cmp "$scripts/$name" "$target/$name"; done
  echo 'Node history already enrolled; no reset or replacement performed.'
  exit 0
fi
install -d -m 0755 "$target"
for name in "${files[@]}"; do install -m 0644 "$scripts/$name" "$target/$name"; done
python3 "$target/node_inspector.py" install
