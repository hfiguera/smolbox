#!/usr/bin/env bash
# Refuse a candidate whose installed controls differ from the tested contract.
set -euo pipefail
[[ $(uname -s) == Linux && $(hostname) == smolbox-nested && $(id -un) == smolbox-qual ]] || exit 1
[[ $(systemd-detect-virt) == kvm && -r /dev/kvm && -w /dev/kvm ]] || exit 1
[[ $(uname -m) == x86_64 && $(uname -r) == 6.8.0-139-generic ]] || exit 1
grep -Eq '(^|,)landlock(,|$)' /sys/kernel/security/lsm
group=/sys/fs/cgroup/system.slice/smolbox-qualification.service
[[ $(cat /proc/self/cgroup) == 0::/system.slice/smolbox-qualification.service ]] || exit 1
[[ $(cat "$group/memory.max") == 1610612736 && $(cat "$group/memory.swap.max") == 0 ]] || exit 1
[[ $(cat "$group/cpu.max") == '100000 100000' && $(cat "$group/pids.max") == 96 ]] || exit 1
[[ $HOME == /srv/sbq/home && $XDG_CACHE_HOME == /srv/sbq/cache && $XDG_DATA_HOME == /srv/sbq/control ]] || exit 1
[[ ${SMOLVM_DATA_DIR:-} == '' && $SMOLVM_SECCOMP == enforce && $SMOLVM_LANDLOCK == enforce ]] || exit 1
[[ $SMOLVM_FILE_TRANSFER_MAX_BYTES == 1048576 && $SMOLVM_DISABLE_SHARED_EXTRACT == 1 ]] || exit 1
for item in control:67108864 cache:805306368 run:4194304; do
  path=/srv/sbq/${item%:*}
  [[ $(findmnt -n -o FSTYPE --target "$path") == tmpfs ]] || exit 1
  [[ $(df -B1 --output=size "$path" | tail -1 | tr -d ' ') == "${item#*:}" ]] || exit 1
  [[ $(stat -c %u "$path") == "$(id -u)" ]] || exit 1
done
[[ $(find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n') == lo ]] || exit 1
[[ ! -w /opt/smolbox/runtime/smolvm-bin && ! -w /opt/smolbox/catalog/python.smolmachine ]] || exit 1
printf '%s\n' \
  '8caeb3b6e7d834493a578b0fe8bd1e7aa02e68fba6d61bcf70fdbec41a27ce68  /opt/smolbox/runtime/smolvm' \
  'bb2432804d4bf5d6cbb688d3af160a6a01c99194830f0099d64f291d4ad62373  /opt/smolbox/runtime/smolvm-bin' \
  '3f021ac366152b33c7c329f893804fa9adda5d4352fac4b88214ae28fb89ebd0  /opt/smolbox/runtime/lib/libkrun.so' \
  '767495f52bd786e6e0b0fa1b04adf40dea44b80019f6953ca6eb6394cc90d264  /opt/smolbox/runtime/lib/libkrunfw.so' \
  'bbeabaa935ff859438e418515dff0ca514e757a99ffc834d6cbb06447de4b8ca  /opt/smolbox/runtime/agent-rootfs/usr/local/bin/smolvm-agent' \
  '76e71b388c2127a809fa25ecd01ac9d5e5498ee98c093e4d9f84fc874d5f36f2  /opt/smolbox/catalog/python.smolmachine' \
  '768b8d2158a75abd90ccc73a65a83717aebfe37e62ed91d0db0bb731584df776  /opt/smolbox/catalog/node.smolmachine' \
  | sha256sum --check --status
