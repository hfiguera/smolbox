#!/usr/bin/env bash
set -euo pipefail
[[ $(uname -s) == Linux ]] || { echo 'Run this through ssh linux, never on macOS.' >&2; exit 1; }
lab=/var/lib/smolbox-lab
exec ssh -F /dev/null -i "$lab/home/id_ed25519" -p 22460 \
  -o BatchMode=yes -o IdentitiesOnly=yes -o ForwardAgent=no \
  -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$lab/home/known_hosts" \
  -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
  lab@127.0.0.1 "$@"
