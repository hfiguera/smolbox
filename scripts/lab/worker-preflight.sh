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
file_cap=${SMOLBOX_QUALIFICATION_FILE_BYTES:-1048576}
[[ $file_cap == 1048576 || $file_cap == 16777216 ]] || exit 1
[[ $file_cap == 1048576 || ${SMOLBOX_CANDIDATE_VERSION:-} == 1.17.0 || ${SMOLBOX_CANDIDATE_VERSION:-} == 1.19.0 ]] || exit 1
[[ $SMOLVM_FILE_TRANSFER_MAX_BYTES == "$file_cap" && $SMOLVM_DISABLE_SHARED_EXTRACT == 1 ]] || exit 1
for item in control:67108864 cache:805306368 run:4194304; do
  path=/srv/sbq/${item%:*}
  [[ $(findmnt -n -o FSTYPE --target "$path") == tmpfs ]] || exit 1
  [[ $(df -B1 --output=size "$path" | tail -1 | tr -d ' ') == "${item#*:}" ]] || exit 1
  [[ $(stat -c %u "$path") == "$(id -u)" ]] || exit 1
done
[[ $(find /sys/class/net -mindepth 1 -maxdepth 1 -printf '%f\n') == lo ]] || exit 1
case "${SMOLBOX_CANDIDATE_VERSION:-1.14.1}" in
  1.14.1)
    runtime=/opt/smolbox/runtime
    binary=bb2432804d4bf5d6cbb688d3af160a6a01c99194830f0099d64f291d4ad62373
    krun=3f021ac366152b33c7c329f893804fa9adda5d4352fac4b88214ae28fb89ebd0
    agent=bbeabaa935ff859438e418515dff0ca514e757a99ffc834d6cbb06447de4b8ca
    ;;
  1.14.6)
    runtime=/opt/smolbox/runtime-1.14.6
    binary=cc1f9b5f14613191ca83c706d52f4350f69b69a6c431c867cd662b51cb36d7d6
    krun=af43ad572bffe052d94d3d8d38beebc0b0f1e7d832f25ad6d352d5d919c0ddd1
    agent=067539a55bd72bb05d54472ca153fb4dea0be0239069c9f1a21aa610e26da020
    ;;
  1.16.0)
    runtime=/opt/smolbox/runtime-1.16.0
    binary=487f20b84053ce6441c67d4d8af35fc028d3bfc7fcfd2da4309c070930fe46a1
    krun=2a58b2fcd8975972c6c1eba0aa687ad0e7844069209d9e56e3bdb4afe6e9fbf7
    agent=4dff5e8e6a29e79fb4856e8043b8fc05b047044714149ce928f20f75ed18db7a
    ;;
  1.16.1)
    runtime=/opt/smolbox/runtime-1.16.1
    binary=017f61853a8f19450472052080f95cd8ef5b80b61d1715e4524c67ea085f11a5
    krun=60ba3b23ba12dee1fb31265d0ba8d69ad8b91b0c81634eb8748f116e0ea122b4
    agent=d83b7a0cda0af6351b463700c7268f0016443536d4396910b9dc21165fb790ea
    ;;
  1.17.0)
    runtime=/opt/smolbox/runtime-1.17.0
    binary=40b9bc8f24f7cc77c371db4784742e6b6724f09a11b83d63776b944734b7912d
    krun=02a694ac055703fe32f2412fd6d79a7387c15226be058db03aadb750dc32ba9e
    agent=1a41b572dd0ad1767c31a38854d26c286e850646d2610eb770dc5e91579028ef
    ;;
  1.19.0)
    runtime=/opt/smolbox/runtime-1.19.0
    binary=9133f40b13e0d08bb0c7b1c939c0ee4d656681445fd739db9a37ed4b14500582
    krun=64aa19dcaf67e3fba981f6861cd08b9af341a7c06e7277f68d761cc4718fd393
    agent=0e7f06cfb00d6701b96194f38b1d585e16f1471b24a4075af1c65ce870e9f091
    ;;
  *) exit 1 ;;
esac
[[ ! -w $runtime/smolvm-bin && ! -w /opt/smolbox/catalog/python.smolmachine ]] || exit 1
printf '%s\n' \
  "8caeb3b6e7d834493a578b0fe8bd1e7aa02e68fba6d61bcf70fdbec41a27ce68  $runtime/smolvm" \
  "$binary  $runtime/smolvm-bin" \
  "$krun  $runtime/lib/libkrun.so" \
  "767495f52bd786e6e0b0fa1b04adf40dea44b80019f6953ca6eb6394cc90d264  $runtime/lib/libkrunfw.so" \
  "$agent  $runtime/agent-rootfs/usr/local/bin/smolvm-agent" \
  '76e71b388c2127a809fa25ecd01ac9d5e5498ee98c093e4d9f84fc874d5f36f2  /opt/smolbox/catalog/python.smolmachine' \
  '768b8d2158a75abd90ccc73a65a83717aebfe37e62ed91d0db0bb731584df776  /opt/smolbox/catalog/node.smolmachine' \
  | sha256sum --check --status
