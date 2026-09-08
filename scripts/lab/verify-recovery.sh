#!/usr/bin/env bash
set -euo pipefail
umask 007
[[ $(uname -s) == Linux && $EUID != 0 ]] || exit 1
lab=/var/lib/smolbox-lab
scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ctl() { bash "$scripts/labctl.sh" "$@"; }
guest() { bash "$scripts/guest-ssh.sh" "$@"; }
wait_for_ssh() {
  for _attempt in $(seq 1 20); do
    if guest true >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo 'Private guest SSH did not become ready.' >&2
  return 1
}

[[ $(loginctl show-user "$(id -un)" -p Linger --value) == yes ]] || exit 1
systemctl --user is-active --quiet smolbox-lab-recovery.timer
ctl reset probe
ctl start probe
unit=smolbox-lab@probe.service
pid=$(systemctl show "$unit" -p MainPID --value)
invocation=$(systemctl show "$unit" -p InvocationID --value)
group=$(systemctl show "$unit" -p ControlGroup --value)
(( pid > 1 ))
[[ -n $invocation && -d /sys/fs/cgroup$group ]] || exit 1
wait_for_ssh
# These substitutions run inside the guest, not on the physical host.
# shellcheck disable=SC2016
guest 'test "$(getconf _NPROCESSORS_ONLN)" = 4 && test "$(sudo blockdev --getsize64 /dev/vda)" = 107374182400 && test -r /dev/kvm && printf disposable-only > /home/lab/disposable-marker'
guest 'getconf _NPROCESSORS_ONLN; head -1 /proc/meminfo; sudo blockdev --getsize64 /dev/vda; systemd-detect-virt' \
  > "$lab/evidence/probe-guest-allocations.txt"
ctl capture probe
jq -e 'select(.id == "kvm") | .return.enabled == true and .return.present == true' \
  "$lab/evidence/probe-kvm.jsonl" >/dev/null
if flock -n "$lab/vm.lock" true; then
  echo 'QEMU did not retain the exclusive VM lock.' >&2; exit 1
fi
if ctl start test > "$lab/evidence/concurrent-start.txt" 2>&1; then
  echo 'A concurrent test start was incorrectly accepted.' >&2; exit 1
fi

frozen_at=$(date +%s)
ctl freeze-probe probe
[[ $(ps -o stat= -p "$pid") == T* ]] || exit 1
echo 'QEMU is frozen. Waiting for the independent host deadline and recovery timer.'
for _attempt in $(seq 1 60); do
  [[ $(systemctl show "$unit" -p MainPID --value) != 0 ]] || break
  sleep 1
done
[[ $(systemctl show "$unit" -p MainPID --value) == 0 ]] || exit 1
[[ $(systemctl show "$unit" -p Result --value) == timeout ]] || exit 1
[[ ! -d /proc/$pid && ! -d /sys/fs/cgroup$group ]] || exit 1
[[ -z $(ss -ltnH sport = :22460) ]] || exit 1
terminated_at=$(date +%s)
(( $(stat -c %Y "$lab/evidence/probe-status.txt") > frozen_at )) || {
  echo 'The independent timer did not capture the frozen VM status.' >&2; exit 1;
}
ctl status probe > "$lab/evidence/probe-deadline-status.txt"

for _attempt in $(seq 1 90); do
  [[ -f $lab/staging/recovery-required ]] || break
  sleep 1
done
[[ ! -f $lab/staging/recovery-required ]] || exit 1
sha256sum --check "$lab/evidence/baseline.sha256"
jq -e '."virtual-size" == 107374182400 and ."actual-size" < 1048576 and ."dirty-flag" == false' \
  "$lab/evidence/probe-rebuilt-image.json" >/dev/null
recovered_at=$(date +%s)

ctl start test
wait_for_ssh
guest 'test ! -e /home/lab/disposable-marker && curl --fail --silent --max-time 5 http://127.0.0.1:19470/api/v1/machines' \
  > "$lab/evidence/replacement-inventory.json"
jq -e '.machines == []' "$lab/evidence/replacement-inventory.json" >/dev/null
replacement_pid=$(systemctl show smolbox-lab@test.service -p MainPID --value)
[[ $replacement_pid != "$pid" ]] || exit 1

jq -n --arg invocation "$invocation" --arg group "$group" \
  --argjson frozen_pid "$pid" --argjson replacement_pid "$replacement_pid" \
  --argjson frozen_at "$frozen_at" --argjson terminated_at "$terminated_at" \
  --argjson recovered_at "$recovered_at" \
  '{status: "passed", invocation: $invocation, original_cgroup: $group,
    frozen_pid: $frozen_pid, replacement_pid: $replacement_pid,
    frozen_at_unix: $frozen_at, terminated_at_unix: $terminated_at,
    recovered_at_unix: $recovered_at, host_deadline_result: "timeout",
    original_process_absent: true, original_cgroup_absent: true,
    management_port_closed_before_replacement: true, automatic_disk_rebuild: true,
    baseline_digest_verified: true, guest_marker_absent_after_rebuild: true,
    replacement_inventory_empty: true, exclusive_vm_lock_verified: true,
    periodic_capture_after_freeze: true,
    concurrent_start_rejected: true, operator_lingering: true}' \
  > "$lab/evidence/recovery.json"
echo 'Independent timeout, process teardown, automatic rebuild and clean replacement passed.'
