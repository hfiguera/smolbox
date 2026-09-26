#!/usr/bin/env bash
# Opt-in startup workload qualification inside the disposable nested Linux lab.
set -euo pipefail
[[ $(hostname) == smolbox-nested && $(systemd-detect-virt) == kvm && $EUID != 0 ]] || exit 1
source /etc/profile.d/smolbox-lab.sh
cd /opt/smolbox/source
attempt=${SMOLBOX_WORKLOAD_ATTEMPT:-initial}
[[ $attempt =~ ^[a-z0-9]{1,20}$ ]] || exit 1
root=/home/lab/qualification/workload-$attempt
umask 077
mkdir "$root"
mkdir "$root/objects"
head -c 32 /dev/urandom > "$root/fingerprint.key"
head -c 32 /dev/urandom > "$root/encryption.key"
phase() {
  local name=$1
  shift
  printf '\nSMOLBOX_PHASE_BEGIN %s\n' "$name"
  local status=0
  timeout --signal=TERM --kill-after=5s 240 "$@" 2>&1 | (ulimit -f 2048; tee "$root/$name.log") || status=$?
  printf '\nSMOLBOX_PHASE_END %s %s %s\n' "$name" "$status" "$(sha256sum "$root/$name.log" | cut -d ' ' -f 1)"
  return "$status"
}
cleanup() {
  local status=$?
  trap - EXIT
  phase cleanup sudo bash scripts/lab/candidate-control.sh stop || status=1
  exit "$status"
}
trap cleanup EXIT
export SMOLBOX_RUNTIME_VERSION=${SMOLBOX_RUNTIME_VERSION:-1.19.0} SMOLBOX_RUNTIME_URL=http://localhost
export SMOLBOX_RUNTIME_SOCKET=/srv/sbq/run/api.sock
export SMOLBOX_PYTHON_ARTIFACT=/opt/smolbox/catalog/python.smolmachine
export SMOLBOX_PYTHON_SHA256=76e71b388c2127a809fa25ecd01ac9d5e5498ee98c093e4d9f84fc874d5f36f2
export SMOLBOX_DATABASE_SOCKET_DIR=/var/run/postgresql SMOLBOX_DATABASE_PORT=5432 SMOLBOX_DATABASE_USER=lab SMOLBOX_DATABASE_NAME=smolbox_contract
export SMOLBOX_ARTIFACT_ROOT="$root/objects" SMOLBOX_FINGERPRINT_KEY_FILE="$root/fingerprint.key" SMOLBOX_ENCRYPTION_KEY_FILE="$root/encryption.key"
export SMOLBOX_EXECUTION_ID="workload-$attempt" SMOLBOX_STORE_PARTITION="workload-$attempt"
(
  cd examples/durable_host
  phase store mix test --warnings-as-errors
)
phase worker-start sudo bash scripts/lab/candidate-control.sh start
phase startup-failure mix test test/workload_runtime --include runtime --warnings-as-errors
phase limits systemctl show smolbox-qualification.service -p RuntimeMaxUSec -p MemoryMax -p CPUQuotaPerSecUSec -p TasksMax
(
  cd examples/durable_host
  phase prepare mix run scripts/workload.exs prepare
  phase resume mix run scripts/workload.exs resume
)
phase inventory curl -fsS --max-time 10 --unix-socket "$SMOLBOX_RUNTIME_SOCKET" http://localhost/api/v1/machines
[[ $(cat "$root/inventory.log") == '{"machines":[]}' ]] || exit 1
phase metrics sudo bash scripts/lab/candidate-control.sh metrics
phase worker-stop sudo bash scripts/lab/candidate-control.sh stop
phase kvm-after sudo bash scripts/lab/kvm-fds.sh smolbox-qual
test ! -s "$root/kvm-after.log"
trap - EXIT
echo 'Workload acceptance passed; worker stopped.'
