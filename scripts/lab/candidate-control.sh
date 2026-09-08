#!/usr/bin/env bash
# Root operations confined to the candidate account inside the disposable VM.
set -euo pipefail
[[ $(hostname) == smolbox-nested && $EUID == 0 && $(systemd-detect-virt) == kvm ]] || exit 1
root=/srv/sbq
unit=smolbox-qualification.service
group=/sys/fs/cgroup/system.slice/$unit
action=${1:?Expected start, stop, metrics, deadline, or fault}

wait_stopped() {
  # systemd can return before init has reaped the last orphan. Observe absence;
  # never erase state or admit another execution while an owned process remains.
  for ((attempt=0; attempt<50; attempt++)); do
    if [[ $(systemctl show "$unit" -p MainPID --value) == 0 ]] && ! pgrep -u smolbox-qual >/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo 'Owned worker processes remain after the bounded stop observation.' >&2
  return 1
}

case "$action" in
  deadline)
    seconds=${2:?Expected 300 seconds}
    [[ $seconds == 300 ]] || exit 1
    [[ $(systemctl show "$unit" -p MainPID --value) == 0 ]] || exit 1
    mkdir -p "/run/systemd/system/$unit.d"
    printf '[Service]\nRuntimeMaxSec=%ss\n' "$seconds" > "/run/systemd/system/$unit.d/60-qualification-deadline.conf"
    systemctl daemon-reload
    ;;
  start)
    systemctl stop "$unit"
    wait_stopped
    for path in "$root/control" "$root/cache" "$root/run"; do
      [[ $(findmnt -n -o SOURCE --target "$path") == smolbox-qualification ]] || exit 1
      [[ ! -L $path && $(stat -c %u "$path") == "$(id -u smolbox-qual)" ]] || exit 1
      find "$path" -xdev -mindepth 1 -delete
    done
    rm -f "$root/run/api.sock"
    if systemctl is-failed --quiet "$unit"; then systemctl reset-failed "$unit"; fi
    systemctl start "$unit"
    for ((attempt=0; attempt<50; attempt++)); do
      if curl --fail --silent --max-time 1 --unix-socket "$root/run/api.sock" http://localhost/health > /dev/null; then
        exit 0
      fi
      sleep 0.1
    done
    echo 'Candidate did not become healthy before its setup deadline.' >&2
    systemctl stop "$unit"
    exit 1
    ;;
  stop)
    systemctl stop "$unit"
    wait_stopped
    ;;
  metrics)
    systemctl show "$unit" -p ActiveState -p Result -p MainPID -p InvocationID -p MemoryPeak -p TasksCurrent
    if [[ -d $group ]]; then
      for metric in memory.current memory.peak memory.events memory.max memory.swap.max cpu.max cpu.stat pids.current pids.max pids.events; do
        printf '%s\n' "$metric"
        # OOM or deadline teardown can remove the cgroup during this observation.
        cat "$group/$metric" 2>/dev/null || printf 'removed\n'
      done
    fi
    df -B1 "$root/control" "$root/cache" "$root/run"
    ;;
  fault)
    kind=${2:?Expected memory, tasks, or cpu}
    systemctl is-active --quiet "$unit"
    [[ -d $group && $(cat "$group/memory.max") == 1610612736 ]] || exit 1
    # Place only this owned injector in the actual worker cgroup. This separately
    # tests the host boundary, without equating guest children with host tasks.
    echo "$$" > "$group/cgroup.procs"
    cd "$root"
    case "$kind" in
      memory)
        exec runuser -u smolbox-qual -- /usr/bin/env \
          ERL_ROOTDIR=/opt/toolchains/erlang/29.0.6 \
          ERL_CRASH_DUMP=/dev/null \
          PATH=/opt/toolchains/elixir/1.20.4-otp-29/bin:/opt/toolchains/erlang/29.0.6/bin:/usr/bin:/bin \
          ERL_FLAGS='+S 1:1 +A 1' elixir -e ':binary.copy(<<42>>, 2 * 1024 * 1024 * 1024) |> byte_size() |> IO.puts()'
        ;;
      tasks)
        exec runuser -u smolbox-qual -- bash -c 'for ((i=0;i<110;i++)); do sleep 8 & done; wait'
        ;;
      cpu)
        exec runuser -u smolbox-qual -- timeout 8 bash -c 'for ((i=0;i<4;i++)); do yes > /dev/null & done; wait'
        ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
