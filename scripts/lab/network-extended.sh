#!/usr/bin/env bash
# Never run these probes on macOS or the physical Linux host.
set -euo pipefail
[[ $(hostname) == smolbox-nested && $(systemd-detect-virt) == kvm && $EUID != 0 ]] || exit 1
source /etc/profile.d/smolbox-lab.sh
cd /opt/smolbox/source
cleanup() {
  sudo systemctl stop smolbox-network-fixture.service || true
  sudo bash scripts/lab/candidate-control.sh stop
  sudo rm -f /run/systemd/system/smolbox-qualification.service.d/70-network-floor.conf
  sudo systemctl daemon-reload
}
trap cleanup EXIT
attempt=${SMOLBOX_NETWORK_ATTEMPT:?Set a unique attempt identifier}
[[ $attempt =~ ^[a-z0-9]+$ ]] || exit 1
if [[ $# == 0 ]]; then set -- offline cidr4 cidr6 hosts strict; fi
for mode in "$@"; do
  cleanup
  if [[ $mode == strict ]]; then
    printf '[Service]\nEnvironment=SMOLVM_EGRESS_FLOOR=strict\n' | sudo tee /run/systemd/system/smolbox-qualification.service.d/70-network-floor.conf > /dev/null
    sudo systemctl daemon-reload
  fi
  sudo bash scripts/lab/candidate-control.sh start
  pid=$(systemctl show smolbox-qualification.service -p MainPID --value)
  [[ $pid != 0 ]] || exit 1
  for addr in 1.1.1.1 198.18.0.10 198.18.0.11 10.77.0.10 169.254.169.254; do
    sudo nsenter -t "$pid" -n ip address add "$addr/32" dev lo
  done
  for addr in 2001:db8::10 2001:db8::11 fd00::10 2606:4700:4700::1111; do
    sudo nsenter -t "$pid" -n ip -6 address add "$addr/128" dev lo
  done
  [[ $(sudo nsenter -t "$pid" -n ip -o link show | wc -l) == 1 ]] || exit 1
  sudo nsenter -t "$pid" -n ip route show > "/home/lab/qualification/extended-${mode}-routes.txt"
  sudo nsenter -t "$pid" -n ip -6 route show >> "/home/lab/qualification/extended-${mode}-routes.txt"
  sudo systemd-run --unit=smolbox-network-fixture --collect --property=RuntimeMaxSec=300 \
    --property=MemoryMax=256M --property=TasksMax=32 --property=CPUQuota=50% \
    --setenv=ERL_FLAGS='+S 1:1 +A 1' --setenv=ERL_CRASH_DUMP=/dev/null \
    --setenv=PATH=/opt/toolchains/elixir/1.20.4-otp-29/bin:/opt/toolchains/erlang/29.0.6/bin:/usr/bin:/bin \
    /usr/bin/nsenter -t "$pid" -n /opt/toolchains/elixir/1.20.4-otp-29/bin/elixir /opt/smolbox/source/scripts/lab/network-extended-endpoints.exs
  sleep 2
  sudo nsenter -t "$pid" -n /usr/bin/env ERL_FLAGS='+S 1:1 +A 1' \
    PATH=/opt/toolchains/elixir/1.20.4-otp-29/bin:/opt/toolchains/erlang/29.0.6/bin:/usr/bin:/bin \
    elixir scripts/lab/network-extended-positive.exs
  elixir scripts/lab/run-check.exs "network-extended-${mode}-${attempt}" 0 mix run scripts/lab/network-extended.exs "$mode"
  cleanup
  sudo bash scripts/lab/kvm-fds.sh smolbox-qual > "/home/lab/qualification/network-extended-${mode}-kvm.txt"
  [[ ! -s /home/lab/qualification/network-extended-${mode}-kvm.txt ]] || exit 1
done
