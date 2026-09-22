#!/usr/bin/env bash
# Opt-in real PTY and durable recovery campaign, only in the disposable nested lab.
set -euo pipefail
[[ $(hostname) == smolbox-nested && $(systemd-detect-virt) == kvm && $EUID != 0 ]] || exit 1
source /etc/profile.d/smolbox-lab.sh
cd /opt/smolbox/source
attempt=${SMOLBOX_TERMINAL_ATTEMPT:-initial}
[[ $attempt =~ ^[a-z0-9]{1,20}$ ]] || exit 1
root=/home/lab/qualification/terminal-$attempt
umask 077
mkdir "$root"
mkdir "$root/objects"
head -c 32 /dev/urandom > "$root/fingerprint.key"
head -c 32 /dev/urandom > "$root/encryption.key"
trap 'sudo bash scripts/lab/candidate-control.sh stop' EXIT
export SMOLBOX_RUNTIME_VERSION=1.17.0 SMOLBOX_RUNTIME_URL=http://localhost
export SMOLBOX_RUNTIME_SOCKET=/srv/sbq/run/api.sock
export SMOLBOX_PYTHON_ARTIFACT=/opt/smolbox/catalog/python.smolmachine
export SMOLBOX_PYTHON_SHA256=76e71b388c2127a809fa25ecd01ac9d5e5498ee98c093e4d9f84fc874d5f36f2
export SMOLBOX_DATABASE_SOCKET_DIR=/var/run/postgresql SMOLBOX_DATABASE_PORT=5432 SMOLBOX_DATABASE_USER=lab SMOLBOX_DATABASE_NAME=smolbox_contract
export SMOLBOX_ARTIFACT_ROOT="$root/objects" SMOLBOX_FINGERPRINT_KEY_FILE="$root/fingerprint.key" SMOLBOX_ENCRYPTION_KEY_FILE="$root/encryption.key"
sudo bash scripts/lab/candidate-control.sh start
systemctl show smolbox-qualification.service -p RuntimeMaxUSec -p MemoryMax -p CPUQuotaPerSecUSec -p TasksMax > "$root/limits.txt"
mix test test/terminal_runtime --include runtime --warnings-as-errors > "$root/runtime.log" 2>&1
curl -fsS --unix-socket "$SMOLBOX_RUNTIME_SOCKET" http://localhost/api/v1/machines > "$root/after-runtime.json"
[[ $(cat "$root/after-runtime.json") == '{"machines":[]}' ]] || exit 1
sudo bash scripts/lab/candidate-control.sh metrics > "$root/runtime-metrics.txt"
sudo bash scripts/lab/candidate-control.sh start
(
  cd examples/durable_host
  mix test --warnings-as-errors > "$root/store.log" 2>&1
  SMOLBOX_EXECUTION_ID="terminal-$attempt-run" SMOLBOX_STORE_PARTITION="terminal-$attempt-run" mix run scripts/terminal.exs run > "$root/durable-run.log" 2>&1
  SMOLBOX_EXECUTION_ID="terminal-$attempt-recovery" SMOLBOX_STORE_PARTITION="terminal-$attempt-recovery" mix run scripts/terminal.exs interrupt > "$root/durable-interrupt.log" 2>&1
  # Upstream removes dead, formerly-running VMs on API startup. Persist a
  # verified stop before killing the worker cgroup, without releasing the slot.
  SMOLBOX_EXECUTION_ID="terminal-$attempt-recovery" SMOLBOX_STORE_PARTITION="terminal-$attempt-recovery" mix run scripts/terminal.exs stop-for-drain > "$root/durable-stop.log" 2>&1
)
# Old controller is gone. Stop and verify all dedicated worker processes before
# restarting the API against its retained private disks; this drains old requests.
sudo bash scripts/lab/candidate-control.sh restart
(
  cd examples/durable_host
  SMOLBOX_TERMINAL_QUIESCED=true SMOLBOX_EXECUTION_ID="terminal-$attempt-recovery" SMOLBOX_STORE_PARTITION="terminal-$attempt-recovery" mix run scripts/terminal.exs recover > "$root/durable-recover.log" 2>&1
)
curl -fsS --unix-socket "$SMOLBOX_RUNTIME_SOCKET" http://localhost/api/v1/machines > "$root/inventory.json"
[[ $(cat "$root/inventory.json") == '{"machines":[]}' ]] || exit 1
sudo bash scripts/lab/candidate-control.sh metrics > "$root/final-metrics.txt"
sudo bash scripts/lab/candidate-control.sh stop
sudo bash scripts/lab/kvm-fds.sh smolbox-qual > "$root/kvm-after.txt"
test ! -s "$root/kvm-after.txt"
trap - EXIT
echo 'Interactive terminal and durable recovery acceptance passed; worker stopped.'
