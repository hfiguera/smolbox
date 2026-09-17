#!/usr/bin/env bash
# Dedicated benchmark worker; invoke inside its bounded systemd user service.
set -euo pipefail
[[ $(uname -s) == Linux && $EUID != 0 ]] || exit 1
root=${1:?Expected private benchmark directory}
[[ -d $root/runtime && -f $root/empty-config.toml ]] || exit 1
exec /usr/bin/env -i HOME="$root/home" XDG_DATA_HOME="$root/data" \
  XDG_CACHE_HOME="$root/cache" SMOLVM_DATA_DIR="$root/data" TMPDIR="$root/tmp" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  SMOLVM_CONFIG="$root/empty-config.toml" DOCKER_CONFIG="$root/docker" \
  SMOLVM_FILE_TRANSFER_MAX_BYTES=1048576 SMOLVM_DISABLE_SHARED_EXTRACT=1 \
  SMOLVM_GUEST_ROLLOUT_HOST_PORT=19634 SMOLVM_EGRESS_FLOOR=strict RUST_LOG=warn \
  "$root/runtime/smolvm" serve start --listen "unix://$root/api.sock"
