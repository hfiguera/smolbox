#!/usr/bin/env bash
# Runs only as the operator on the authorized host; shares the existing lab lock.
set -euo pipefail
umask 077
[[ $(hostname) == pop-os && $(uname -m) == x86_64 && $EUID != 0 ]] || exit 1
lab=/var/lib/smolbox-lab
root=$lab/kubernetes
[[ $(findmnt -n -o LABEL --target "$root") == smolbox-lab ]] || exit 1
[[ -f $root/owner && $(cat "$root/owner") == "$(id -un)" && -w /dev/kvm ]] || exit 1
exec 9>"$lab/vm.lock"
flock -n 9 || { echo 'Another SmolBox lab VM is running.' >&2; exit 1; }
exec /usr/bin/qemu-system-x86_64 \
  -name smolbox-kubernetes-lab -machine q35,accel=kvm -cpu host -smp 4 -m 8192 \
  -nodefaults -no-user-config -display none -monitor none \
  -qmp "unix:$root/control.sock,server=on,wait=off" \
  -chardev ringbuf,id=serial,size=1048576 -serial chardev:serial \
  -drive "file=$root/node.qcow2,if=virtio,format=qcow2,cache=none,discard=unmap" \
  -drive "file=$root/cloud-init.iso,if=virtio,format=raw,readonly=on" \
  -netdev 'user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:22470-:22,hostfwd=tcp:127.0.0.1:16443-:6443' \
  -device virtio-net-pci,netdev=net0 -device virtio-rng-pci -boot order=c
