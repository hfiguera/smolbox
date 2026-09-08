#!/usr/bin/env bash
# Deliberate worker cgroup faults, inside the already bounded disposable VM.
set -euo pipefail
[[ $(hostname) == smolbox-nested && $EUID != 0 && $(systemd-detect-virt) == kvm ]] || exit 1
scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
report=/home/lab/qualification
unit=smolbox-qualification.service

for kind in cpu tasks memory; do
  sudo bash "$scripts/candidate-control.sh" start
  sudo bash "$scripts/candidate-control.sh" metrics | tee "$report/host-$kind-before.txt" >/dev/null
  set +e
  sudo bash "$scripts/candidate-control.sh" fault "$kind" 2>&1 | tee "$report/host-$kind-output.txt" >/dev/null
  status=$?
  set -e
  printf '%s\n' "$status" > "$report/host-$kind-status.txt"
  sudo bash "$scripts/candidate-control.sh" metrics | tee "$report/host-$kind-after.txt" >/dev/null
  sudo bash "$scripts/candidate-control.sh" stop
  for metric in result memory.peak memory.events cpu.stat pids.events; do
    sudo cat "/run/smolbox-qualification-evidence/$metric" | tee "$report/host-$kind-$metric.txt" >/dev/null
  done
  sudo cat /run/smolbox-qualification-evidence/{result,memory.peak,memory.events,cpu.stat,pids.events} \
    | tee "$report/host-$kind-final.txt" >/dev/null
  case "$kind" in
    cpu) awk '/nr_throttled/ { if ($2 > 0) passed=1 } END { exit !passed }' "$report/host-$kind-cpu.stat.txt" ;;
    tasks) awk '/^max / { if ($2 > 0) passed=1 } END { exit !passed }' "$report/host-$kind-pids.events.txt" ;;
    memory) grep -q '^oom-kill$' "$report/host-$kind-final.txt" ;;
  esac
  echo "Verified host $kind boundary and complete process removal."
done

# Weaken a control deliberately and prove admission refuses it before serve runs.
sudo systemctl set-property --runtime "$unit" MemoryMax=2G
if sudo systemctl start "$unit"; then
  sudo bash "$scripts/candidate-control.sh" stop
  echo 'Preflight incorrectly accepted a weaker limit.' >&2
  exit 1
fi
[[ $(systemctl show "$unit" -p MainPID --value) == 0 ]] || exit 1
systemctl show "$unit" -p Result -p ExecStartPre > "$report/weakened-limit.txt"
sudo systemctl set-property --runtime "$unit" MemoryMax=1536M
sudo bash "$scripts/candidate-control.sh" start
curl --fail --silent --max-time 5 --unix-socket /srv/sbq/run/api.sock http://localhost/health > "$report/recovered-health.json"
sudo bash "$scripts/candidate-control.sh" stop
echo 'Weaker configuration rejected; restored worker healthy.'
