#!/usr/bin/env bash
# All addresses and responders are confined to the disposable worker net namespace.
set -euo pipefail
[[ $(hostname) == smolbox-nested && $(systemd-detect-virt) == kvm && $EUID != 0 ]] || exit 1
source /etc/profile.d/smolbox-lab.sh
cd /opt/smolbox/source
trap 'sudo systemctl stop smolbox-network-fixture.service || true; sudo bash scripts/lab/candidate-control.sh stop' EXIT
if [[ $# == 0 ]]; then set -- offline cidr hosts; fi
attempt=${SMOLBOX_NETWORK_ATTEMPT:-initial}
[[ $attempt =~ ^[a-z0-9]+$ ]] || exit 1
for mode in "$@"; do
  sudo systemctl stop smolbox-network-fixture.service || true
  sudo bash scripts/lab/candidate-control.sh start
  pid=$(systemctl show smolbox-qualification.service -p MainPID --value)
  [[ $pid != 0 ]] || exit 1
  for addr in 1.1.1.1 198.18.0.10 198.18.0.11; do
    sudo nsenter -t "$pid" -n ip address add "$addr/32" dev lo
  done
  # The worker namespace has no interface or route to the outer host network.
  [[ $(sudo nsenter -t "$pid" -n ip -o link show | wc -l) == 1 ]] || exit 1
  sudo systemd-run --unit=smolbox-network-fixture --collect --property=RuntimeMaxSec=300 \
    --property=MemoryMax=256M --property=TasksMax=32 --property=CPUQuota=50% \
    --setenv=ERL_FLAGS='+S 1:1 +A 1' --setenv=ERL_CRASH_DUMP=/dev/null \
    --setenv=PATH=/opt/toolchains/elixir/1.20.4-otp-29/bin:/opt/toolchains/erlang/29.0.6/bin:/usr/bin:/bin \
    /usr/bin/nsenter -t "$pid" -n /opt/toolchains/elixir/1.20.4-otp-29/bin/elixir /opt/smolbox/source/scripts/lab/network-endpoints.exs
  sleep 2
  # Both positive-control endpoints must actually respond before a deny counts.
  for addr in 198.18.0.10 198.18.0.11; do
    sudo nsenter -t "$pid" -n timeout 3 bash -c 'exec 3<>/dev/tcp/'"$addr"'/8088; read -r reply <&3; [[ $reply == fixture-ok ]]'
  done
  elixir scripts/lab/run-check.exs "network-${mode}-${attempt}-runner" 0 mix run scripts/lab/network-access.exs "$mode"
  if [[ $mode == hosts && ${SMOLBOX_NETWORK_MANAGED:-false} == true ]]; then
    elixir scripts/lab/run-check.exs "network-managed-${attempt}-runner" 0 mix run scripts/lab/network-managed.exs
  fi
  sudo systemctl stop smolbox-network-fixture.service
  sudo bash scripts/lab/candidate-control.sh stop
  sudo bash scripts/lab/kvm-fds.sh smolbox-qual > "/home/lab/qualification/network-${mode}-kvm.txt"
  [[ ! -s /home/lab/qualification/network-${mode}-kvm.txt ]] || exit 1
done
