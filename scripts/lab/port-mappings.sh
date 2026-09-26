#!/usr/bin/env bash
# Run only in the disposable nested lab, with the selected qualified candidate installed.
set -euo pipefail
[[ $(hostname) == smolbox-nested && $(systemd-detect-virt) == kvm && $EUID != 0 ]] || exit 1
source /etc/profile.d/smolbox-lab.sh
cd /opt/smolbox/source
attempt=${SMOLBOX_PORT_ATTEMPT:-initial}
[[ $attempt =~ ^[a-z0-9]{1,20}$ ]] || exit 1
root=/home/lab/qualification/ports-$attempt
umask 077
mkdir "$root"
mkdir "$root/objects"
head -c 32 /dev/urandom > "$root/fingerprint.key"
head -c 32 /dev/urandom > "$root/encryption.key"
trap 'sudo systemctl stop smolbox-network-fixture.service 2>/dev/null || true; sudo bash scripts/lab/candidate-control.sh stop' EXIT
sudo bash scripts/lab/candidate-control.sh start
pid=$(systemctl show smolbox-qualification.service -p MainPID --value)
[[ $pid != 0 ]] || exit 1
for addr in 198.18.0.10 198.18.0.11; do
  sudo nsenter -t "$pid" -n ip address add "$addr/32" dev lo
done
sudo nsenter -t "$pid" -n ip address add 1.1.1.1/32 dev lo
[[ $(sudo nsenter -t "$pid" -n ip -o link show | wc -l) == 1 ]] || exit 1
sudo systemd-run --unit=smolbox-network-fixture --collect --property=RuntimeMaxSec=300 \
  --property=MemoryMax=256M --property=TasksMax=32 --property=CPUQuota=50% \
  --setenv=ERL_FLAGS='+S 1:1 +A 1' --setenv=ERL_CRASH_DUMP=/dev/null \
  --setenv=PATH=/opt/toolchains/elixir/1.20.4-otp-29/bin:/opt/toolchains/erlang/29.0.6/bin:/usr/bin:/bin \
  /usr/bin/nsenter -t "$pid" -n /opt/toolchains/elixir/1.20.4-otp-29/bin/elixir /opt/smolbox/source/scripts/lab/network-endpoints.exs
sleep 2

# The application runs as lab, outside the worker's resource cgroup, but joins
# its isolated network namespace so it can reach worker-local published ports.
nsrun() {
  sudo nsenter -t "$pid" -n runuser -u lab -- env \
    ERL_ROOTDIR=/opt/toolchains/erlang/29.0.6 ERL_FLAGS='+S 4:4' MIX_ENV=test \
    PATH=/opt/toolchains/elixir/1.20.4-otp-29/bin:/opt/toolchains/erlang/29.0.6/bin:/usr/bin:/bin \
    SMOLBOX_RUNTIME_VERSION=${SMOLBOX_RUNTIME_VERSION:-1.19.0} SMOLBOX_RUNTIME_URL=http://localhost \
    SMOLBOX_RUNTIME_SOCKET=/srv/sbq/run/api.sock \
    SMOLBOX_PYTHON_ARTIFACT=/opt/smolbox/catalog/python.smolmachine \
    SMOLBOX_PYTHON_SHA256=76e71b388c2127a809fa25ecd01ac9d5e5498ee98c093e4d9f84fc874d5f36f2 \
    SMOLBOX_PORT_ALLOWED_IP=198.18.0.10 SMOLBOX_PORT_DENIED_IP=198.18.0.11 SMOLBOX_PORT_OUTBOUND_PORT=8088 \
    SMOLBOX_DATABASE_SOCKET_DIR=/var/run/postgresql SMOLBOX_DATABASE_PORT=5432 \
    SMOLBOX_DATABASE_USER=lab SMOLBOX_DATABASE_NAME=smolbox_contract \
    SMOLBOX_ARTIFACT_ROOT="$root/objects" SMOLBOX_FINGERPRINT_KEY_FILE="$root/fingerprint.key" \
    SMOLBOX_ENCRYPTION_KEY_FILE="$root/encryption.key" \
    SMOLBOX_HTTP_PORT=28731 SMOLBOX_EXECUTION_ID="ports-1170-$attempt" SMOLBOX_STORE_PARTITION="ports-1170-$attempt" \
    "$@"
}
nsrun mix test test/ports_runtime/ports_runtime_test.exs --include runtime --warnings-as-errors > "$root/runtime.log" 2>&1
(
  cd examples/durable_host
  nsrun mix run scripts/persistent_http.exs prepare > "$root/http-prepare.log" 2>&1
  nsrun mix run scripts/persistent_http.exs resume > "$root/http-resume.log" 2>&1
)
curl -fsS --unix-socket /srv/sbq/run/api.sock http://localhost/api/v1/machines > "$root/inventory.json"
sudo bash scripts/lab/candidate-control.sh metrics > "$root/metrics.txt"
sudo systemctl stop smolbox-network-fixture.service
sudo bash scripts/lab/candidate-control.sh stop
sudo bash scripts/lab/kvm-fds.sh smolbox-qual > "$root/kvm-after.txt"
test ! -s "$root/kvm-after.txt"
echo 'Linux port forwarding, outbound controls, host conflicts and durable HTTP recovery passed.'
