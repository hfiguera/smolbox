#!/usr/bin/env bash
set -euo pipefail
umask 007
[[ $(uname -s) == Linux && $(id -un) == smolbox-lab ]] || exit 1
lab=/var/lib/smolbox-lab
mode=${1:?Expected provision, test, or probe}
case "$mode" in
  provision) disk=$lab/images/provision.qcow2; restriction=off ;;
  test|probe) disk=$lab/images/run.qcow2; restriction=on ;;
  *) exit 1 ;;
esac
[[ -r $disk && -r $lab/seed/cloud-init.iso && -w /dev/kvm ]] || exit 1
[[ $(findmnt -n -o LABEL --target "$lab") == smolbox-lab ]] || exit 1

# One lock covers every mode and is held by QEMU for its complete lifetime.
exec 9>"$lab/vm.lock"
flock -n 9 || { echo 'Another lab VM is already running.' >&2; exit 1; }
rm -f "$lab/control.sock"
exec /usr/bin/qemu-system-x86_64 \
  -name smolbox-lab -machine q35,accel=kvm -cpu host -smp 4 -m 8192 \
  -nodefaults -no-user-config -display none -monitor none \
  -qmp "unix:$lab/control.sock,server=on,wait=off" \
  -chardev ringbuf,id=serial,size=1048576 -serial chardev:serial \
  -drive "file=$disk,if=virtio,format=qcow2,cache=none,discard=unmap" \
  -drive "file=$lab/seed/cloud-init.iso,if=virtio,format=raw,readonly=on" \
  -netdev "user,id=net0,ipv6=off,restrict=$restriction,hostfwd=tcp:127.0.0.1:22460-:22" \
  -device virtio-net-pci,netdev=net0 \
  -device virtio-rng-pci -boot order=c
