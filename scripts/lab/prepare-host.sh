#!/usr/bin/env bash
# All image construction and key generation happen on ssh linux.
set -euo pipefail
umask 007
[[ $(uname -s) == Linux && $(uname -m) == x86_64 && $EUID != 0 ]] || exit 1
lab=/var/lib/smolbox-lab
[[ $(findmnt -n -o LABEL --target "$lab") == smolbox-lab ]] || exit 1
exec 9>"$lab/vm.lock"
flock -n 9 || { echo 'Stop the lab VM before preparing images.' >&2; exit 1; }
[[ ! -e $lab/images/provision.qcow2 && ! -e $lab/images/baseline.qcow2 ]] || {
  echo 'Lab images already exist; refusing to overwrite them.' >&2; exit 1;
}

image=ubuntu-24.04-server-cloudimg-amd64.img
url=https://cloud-images.ubuntu.com/releases/noble/release-20260826
image_sha=d0fe84bb5f80853425fa6be28e2c106f30104c3cfe8611933f2e65c9b63f0e30
curl --fail --location --proto '=https' --proto-redir '=https' --max-time 900 \
  --max-filesize 2147483648 --output "$lab/images/$image.part" "$url/$image"
printf '%s  %s\n' "$image_sha" "$lab/images/$image.part" | sha256sum --check
mv "$lab/images/$image.part" "$lab/images/$image"
chmod 0440 "$lab/images/$image"

# Copy only the approved archives; never mutate the existing development worker.
cp /tmp/smolbox-v1.14.1-linux.tar.gz "$lab/staging/smolvm.tar.gz"
cp /tmp/smolbox-qualification/{python,node}.smolmachine "$lab/staging/"
cat > "$lab/staging/SHA256SUMS" <<'SUMS'
e91786c12808ce87655aa190eb5f6692672cd659a89367b5ec18dace5756af2f  smolvm.tar.gz
76e71b388c2127a809fa25ecd01ac9d5e5498ee98c093e4d9f84fc874d5f36f2  python.smolmachine
768b8d2158a75abd90ccc73a65a83717aebfe37e62ed91d0db0bb731584df776  node.smolmachine
SUMS
(cd "$lab/staging" && sha256sum --check SHA256SUMS)

# Reuse the previously validated Linux builds, with an exact bundle digest.
# No toolchain or VM is executed on the Mac.
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
  -C /tmp/smolbox-qualification/mise/installs \
  -cf - erlang/29.0.6 elixir/1.20.4-otp-29 | gzip -n > "$lab/staging/toolchains.tar.gz"
(cd "$lab/staging" && sha256sum toolchains.tar.gz >> SHA256SUMS)

[[ -f $lab/home/id_ed25519 ]] || {
  (umask 077; ssh-keygen -q -t ed25519 -N '' -C smolbox-disposable-lab -f "$lab/home/id_ed25519")
}
public_key=$(cat "$lab/home/id_ed25519.pub")
cat > "$lab/seed/user-data" <<YAML
#cloud-config
hostname: smolbox-nested
manage_etc_hosts: true
users:
  - name: lab
    groups: [adm, sudo, kvm]
    shell: /bin/bash
    lock_passwd: true
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    ssh_authorized_keys:
      - $public_key
disable_root: true
ssh_pwauth: false
package_update: true
packages:
  - ca-certificates
  - curl
  - git
  - build-essential
  - libssl3t64
  - libncurses6
  - libtinfo6
  - zstd
  - unzip
  - jq
  - strace
  - linux-generic
runcmd:
  - [modprobe, kvm_intel]
  - [systemctl, disable, --now, apt-daily.timer, apt-daily-upgrade.timer]
  - [systemctl, mask, apt-daily.service, apt-daily-upgrade.service]
YAML
printf 'instance-id: smolbox-lab-%s\nlocal-hostname: smolbox-nested\n' \
  "$(date -u +%Y%m%dT%H%M%SZ)" > "$lab/seed/meta-data"
cloud-localds "$lab/seed/cloud-init.iso" "$lab/seed/user-data" "$lab/seed/meta-data"
chmod 0640 "$lab/seed/"*
qemu-img create -f qcow2 -F qcow2 -b "$lab/images/$image" "$lab/images/provision.qcow2" 100G
chmod 0660 "$lab/images/provision.qcow2"
qemu-img info --output=json "$lab/images/provision.qcow2" > "$lab/evidence/provision-image.json"
printf '%s\n' "$url/$image" > "$lab/evidence/cloud-image-url.txt"
printf '%s\n' "$image_sha" > "$lab/evidence/cloud-image-sha256.txt"
echo 'Prepared the guest. Start smolbox-lab@provision.service next.'
