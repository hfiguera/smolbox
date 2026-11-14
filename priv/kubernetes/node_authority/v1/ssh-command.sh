#!/bin/sh
# Forced command for the evidence principal. Never evaluate the supplied token.
set -eu
[ "$#" -eq 0 ] || exit 1
[ "${SSH_ORIGINAL_COMMAND-}" = smolbox-node-authority-v1 ] || exit 1
exec /usr/bin/sudo -n -- /usr/local/libexec/smolbox-node-authority
