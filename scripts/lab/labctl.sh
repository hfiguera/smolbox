#!/usr/bin/env bash
# Host control and recovery; does not depend on the guest's worker or database.
set -euo pipefail
umask 007
[[ $(uname -s) == Linux && $EUID != 0 ]] || exit 1
lab=/var/lib/smolbox-lab
[[ $(findmnt -n -o LABEL --target "$lab") == smolbox-lab ]] || exit 1
action=${1:?Expected start, stop, capture, revise, seal, reset, status, or freeze-probe}
mode=${2:-test}
case "$mode" in provision|test|probe) ;; *) exit 1 ;; esac
unit=smolbox-lab@$mode.service
case "$action" in
  capture|status) ;;
  *)
    exec 8>"$lab/controller.lock"
    flock -n 8 || { echo 'Another lab control operation is in progress.' >&2; exit 1; }
    ;;
esac

qmp() {
  {
    printf '{"execute":"qmp_capabilities"}\n'
    printf '%s\n' "$1"
  } | timeout 5 socat -t 2 - "UNIX-CONNECT:$lab/control.sock"
}

status() {
  systemctl show "$unit" -p ActiveState -p SubState -p Result -p MainPID \
    -p InvocationID -p ExecMainCode -p ExecMainStatus -p RuntimeMaxUSec \
    -p MemoryMax -p MemorySwapMax -p MemoryPeak -p CPUUsageNSec -p TasksMax \
    -p ControlGroup -p CPUQuotaPerSecUSec
}

lock_stopped() {
  exec 9>"$lab/vm.lock"
  flock -n 9 || { echo 'A lab VM is running; refusing disk changes.' >&2; exit 1; }
  for other in provision test probe; do
    state=$(systemctl show "smolbox-lab@$other.service" -p ActiveState --value)
    case "$state" in inactive|failed) ;; *) echo "Lab unit is $state" >&2; exit 1 ;; esac
  done
}

case "$action" in
  start)
    [[ ! -f $lab/staging/recovery-required ]] || {
      echo 'Wait for pending recovery before starting another test.' >&2; exit 1;
    }
    for other in provision test probe; do
      state=$(systemctl show "smolbox-lab@$other.service" -p ActiveState --value)
      case "$state" in inactive|failed) ;; *) echo 'A lab VM is already active.' >&2; exit 1 ;; esac
    done
    if systemctl is-failed --quiet "$unit"; then
      sudo -n /usr/bin/systemctl reset-failed "$unit"
    fi
    if [[ $mode != provision ]]; then
      printf '%s\n' "$mode" > "$lab/staging/recovery-required"
    fi
    sudo -n /usr/bin/systemctl start "$unit"
    ;;
  stop)
    # A bounded capture can fail when QEMU is hung. Shutdown must still proceed.
    bash "$0" capture "$mode" || true
    sudo -n /usr/bin/systemctl stop "$unit"
    status > "$lab/evidence/$mode-stopped.txt"
    ;;
  status) status ;;
  capture)
    exec 7>"$lab/capture-$mode.lock"
    flock -w 6 7 || exit 1
    status > "$lab/evidence/$mode-status.txt"
    group=$(systemctl show "$unit" -p ControlGroup --value)
    if [[ $group == /system.slice/*/smolbox-lab@"$mode".service && -d /sys/fs/cgroup$group ]]; then
      for metric in memory.max memory.peak memory.events memory.swap.max cpu.max cpu.stat pids.max pids.current; do
        cat "/sys/fs/cgroup$group/$metric" > "$lab/evidence/$mode-$metric.txt"
      done
    fi
    # Fixed filenames and a 1 MiB serial ring prevent per-run log accumulation.
    qmp '{"execute":"query-kvm","id":"kvm"}' > "$lab/evidence/$mode-kvm.part"
    mv "$lab/evidence/$mode-kvm.part" "$lab/evidence/$mode-kvm.jsonl"
    qmp '{"execute":"ringbuf-read","arguments":{"device":"serial","size":1048576,"format":"base64"},"id":"serial"}' \
      > "$lab/evidence/$mode-serial.part"
    if jq -e 'select(.id == "serial") | .return | type == "string" and length > 0' \
      "$lab/evidence/$mode-serial.part" >/dev/null; then
      mv "$lab/evidence/$mode-serial.part" "$lab/evidence/$mode-serial.jsonl"
    else
      rm "$lab/evidence/$mode-serial.part"
    fi
    ;;
  revise)
    lock_stopped
    [[ ! -f $lab/staging/recovery-required && ! -e $lab/images/provision.qcow2 ]] || exit 1
    sha256sum --check "$lab/evidence/baseline.sha256"
    qemu-img create -f qcow2 -F qcow2 -b "$lab/images/baseline.qcow2" "$lab/images/provision.qcow2" 100G
    chmod 0660 "$lab/images/provision.qcow2"
    cp "$lab/evidence/baseline.sha256" "$lab/staging/revising-baseline"
    ;;
  seal)
    lock_stopped
    [[ -f $lab/evidence/provisioned.txt && -f $lab/images/provision.qcow2 ]] || exit 1
    if [[ -e $lab/images/baseline.qcow2 ]]; then
      [[ -f $lab/staging/revising-baseline ]] || exit 1
      sha256sum --check "$lab/staging/revising-baseline"
    fi
    qemu-img check "$lab/images/provision.qcow2"
    qemu-img convert -f qcow2 -O qcow2 "$lab/images/provision.qcow2" "$lab/images/baseline.part"
    qemu-img check "$lab/images/baseline.part"
    if [[ -e $lab/images/baseline.qcow2 ]]; then
      cp "$lab/evidence/baseline.sha256" "$lab/evidence/previous-baseline.sha256"
      chmod u+w "$lab/images/baseline.qcow2"
      rm -f "$lab/images/run.qcow2"
    fi
    mv -f "$lab/images/baseline.part" "$lab/images/baseline.qcow2"
    chmod 0440 "$lab/images/baseline.qcow2"
    sha256sum "$lab/images/baseline.qcow2" > "$lab/evidence/baseline.sha256"
    # Only this lab's working disk is removed, after the standalone baseline is verified.
    rm "$lab/images/provision.qcow2"
    rm -f "$lab/staging/revising-baseline"
    ;;
  reset)
    lock_stopped
    sha256sum --check "$lab/evidence/baseline.sha256"
    [[ ! -L $lab/images/run.qcow2 ]] || exit 1
    rm -f "$lab/images/run.qcow2"
    qemu-img create -f qcow2 -F qcow2 -b "$lab/images/baseline.qcow2" "$lab/images/run.qcow2" 100G
    chmod 0660 "$lab/images/run.qcow2"
    ;;
  freeze-probe)
    [[ $mode == probe ]] || exit 1
    systemctl is-active --quiet "$unit"
    sudo -n /usr/bin/systemctl kill --signal=STOP smolbox-lab@probe.service
    ;;
  *) exit 1 ;;
esac
