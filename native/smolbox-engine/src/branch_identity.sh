# Fixed bare-guest initialization, invoked only through receipt-bound agent IO.
# Positional values are validated by the engine and never interpolated as code.
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
child=$1
nonce=$2
host_epoch=$3
mid=$(printf '%.32s' "$nonce")
old_mid=$(cat /etc/machine-id 2>/dev/null || true)
[ "$old_mid" != "$mid" ]
umask 077
printf '%s' "$nonce" > /dev/urandom
hostname "$child"
printf '%s\n' "$child" > /etc/hostname
printf '%s\n' "$mid" > /etc/machine-id
if [ -f /var/lib/dbus/machine-id ] && [ ! -L /var/lib/dbus/machine-id ]; then
    printf '%s\n' "$mid" > /var/lib/dbus/machine-id
fi
if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    command -v ssh-keygen >/dev/null
    rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
    ssh-keygen -A >/dev/null 2>&1
    ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1
fi
rm -rf /var/lib/cloud/instance /var/lib/cloud/instances/* /var/lib/cloud/data/instance-id
if [ "$host_epoch" != 0 ]; then
    date -u -s "@$host_epoch" >/dev/null 2>&1 || printf '%s\n' 'clock-reset-unconfirmed' >&2
fi
[ "$(cat /etc/machine-id)" = "$mid" ]
[ "$(cat /etc/hostname)" = "$child" ]
# Match the public SDK forkpoint protocol without releasing the parked helper.
mkdir -p /run/smolvm/forkpoint
printf '%s\n' smolvm-forkpoint-restored-v1 > /run/smolvm/forkpoint/restored
printf 'smolbox-branch-identity-v1 %s\n' "$nonce"
