#!/bin/sh
# Only the literal no-argument root entrypoint is authorized by sudoers.
set -eu
[ "$#" -eq 0 ] || exit 1
umask 077
exec /usr/bin/python3 -I -S -B /usr/local/lib/smolbox-node-authority/v1/authority_bootstrap.py
