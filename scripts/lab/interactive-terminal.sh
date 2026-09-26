#!/usr/bin/env bash
# Opt-in real PTY and durable recovery campaign, only in the disposable nested lab.
set -euo pipefail
[[ $(hostname) == smolbox-nested && $(systemd-detect-virt) == kvm && $EUID != 0 ]] || exit 1
source /etc/profile.d/smolbox-lab.sh
cd /opt/smolbox/source
attempt=${SMOLBOX_TERMINAL_ATTEMPT:-initial}
[[ $attempt =~ ^[a-z0-9]{1,20}$ ]] || exit 1
scope=${SMOLBOX_TERMINAL_SCOPE:-all}
[[ $scope == all || $scope == recovery ]] || exit 1
root=/home/lab/qualification/terminal-$attempt
umask 077
mkdir "$root"
mkdir "$root/objects"
head -c 32 /dev/urandom > "$root/fingerprint.key"
head -c 32 /dev/urandom > "$root/encryption.key"
# Stream each bounded phase to the physical-host capture as well as its guest log.
# A failed command retains its output/status; no phase is replayed automatically.
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
phase worker-start sudo bash scripts/lab/candidate-control.sh start
phase limits systemctl show smolbox-qualification.service -p RuntimeMaxUSec -p MemoryMax -p CPUQuotaPerSecUSec -p TasksMax
if [[ $scope == all ]]; then
  phase runtime mix test test/terminal_runtime --include runtime --warnings-as-errors
  phase after-runtime curl -fsS --max-time 10 --unix-socket "$SMOLBOX_RUNTIME_SOCKET" http://localhost/api/v1/machines
  [[ $(cat "$root/after-runtime.log") == '{"machines":[]}' ]] || exit 1
  phase runtime-metrics sudo bash scripts/lab/candidate-control.sh metrics
  phase worker-reset sudo bash scripts/lab/candidate-control.sh start
fi
(
  cd examples/durable_host
  if [[ $scope == all ]]; then
    phase store mix test --warnings-as-errors
    phase durable-run env SMOLBOX_EXECUTION_ID="terminal-$attempt-run" SMOLBOX_STORE_PARTITION="terminal-$attempt-run" mix run scripts/terminal.exs run
  fi
  phase durable-interrupt env SMOLBOX_EXECUTION_ID="terminal-$attempt-recovery" SMOLBOX_STORE_PARTITION="terminal-$attempt-recovery" mix run scripts/terminal.exs interrupt
  # Preserve the disks before draining old requests; this does NOT resolve uncertainty.
  phase durable-stop env SMOLBOX_EXECUTION_ID="terminal-$attempt-recovery" SMOLBOX_STORE_PARTITION="terminal-$attempt-recovery" mix run scripts/terminal.exs stop-for-drain
)
phase worker-drain sudo bash scripts/lab/candidate-control.sh restart
(
  cd examples/durable_host
  phase durable-recover env SMOLBOX_TERMINAL_QUIESCED=true SMOLBOX_EXECUTION_ID="terminal-$attempt-recovery" SMOLBOX_STORE_PARTITION="terminal-$attempt-recovery" mix run scripts/terminal.exs recover
)
phase inventory curl -fsS --max-time 10 --unix-socket "$SMOLBOX_RUNTIME_SOCKET" http://localhost/api/v1/machines
[[ $(cat "$root/inventory.log") == '{"machines":[]}' ]] || exit 1
phase final-metrics sudo bash scripts/lab/candidate-control.sh metrics
phase worker-stop sudo bash scripts/lab/candidate-control.sh stop
phase kvm-after sudo bash scripts/lab/kvm-fds.sh smolbox-qual
test ! -s "$root/kvm-after.log"
trap - EXIT
echo "Interactive terminal $scope acceptance passed; worker stopped."
