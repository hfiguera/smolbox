#!/usr/bin/env bash
# Invoked as root INSIDE the disposable outer VM, never on the physical host.
set -euo pipefail
[[ $(uname -s) == Linux && $(hostname) == smolbox-nested && $EUID == 0 ]] || exit 1
[[ $(systemd-detect-virt) == kvm ]] || exit 1
input=/home/lab/input
(cd "$input" && sha256sum --check SHA256SUMS)
[[ -c /dev/kvm ]] || modprobe kvm_intel
[[ -c /dev/kvm ]] || { echo 'Nested KVM is unavailable.' >&2; exit 1; }

mkdir -p /opt/smolbox/{runtime,catalog,source} /opt/toolchains
tar -xzf "$input/smolvm.tar.gz" --strip-components=1 -C /opt/smolbox/runtime
# Materialize the released sparse templates during provisioning, before any API deadline.
zstd --decompress --sparse --force /opt/smolbox/runtime/storage-template.ext4.zst
zstd --decompress --sparse --force /opt/smolbox/runtime/overlay-template.ext4.zst
tar -xzf "$input/toolchains.tar.gz" -C /opt/toolchains
tar -xf "$input/source.tar" -C /opt/smolbox/source
cp "$input/"{python,node}.smolmachine /opt/smolbox/catalog/
chmod 0644 /opt/smolbox/catalog/*.smolmachine
cp "$input/SHA256SUMS" /opt/smolbox/input-sha256.txt
cp "$input/source-commit.txt" /opt/smolbox/source-commit.txt
cat > /etc/profile.d/smolbox-lab.sh <<'ENV'
export ERL_ROOTDIR=/opt/toolchains/erlang/29.0.6
export PATH=/opt/toolchains/elixir/1.20.4-otp-29/bin:/opt/toolchains/erlang/29.0.6/bin:$PATH
export SMOLBOX_RUNTIME_URL=http://127.0.0.1:19470
export SMOLBOX_PYTHON_ARTIFACT=/opt/smolbox/catalog/python.smolmachine
export SMOLBOX_JS_ARTIFACT=/opt/smolbox/catalog/node.smolmachine
export MIX_ENV=test
export ERL_FLAGS='+S 4:4'
ENV
chmod 0644 /etc/profile.d/smolbox-lab.sh
id smolbox-worker >/dev/null 2>&1 || useradd --system --user-group --create-home \
  --home-dir /srv/smolbox-worker --shell /usr/sbin/nologin smolbox-worker
usermod -a -G kvm smolbox-worker
chown -R smolbox-worker:smolbox-worker /opt/smolbox/runtime
chown -R lab:lab /opt/smolbox/source

cat > /etc/systemd/system/smolbox-worker.service <<'UNIT'
[Unit]
Description=Pinned SmolVM worker in disposable qualification guest
After=network.target
[Service]
User=smolbox-worker
Group=smolbox-worker
SupplementaryGroups=kvm
Environment=HOME=/srv/smolbox-worker
Environment=SMOLVM_DATA_DIR=/srv/smolbox-worker/data
Environment=SMOLVM_FILE_TRANSFER_MAX_BYTES=1048576
ExecStart=/opt/smolbox/runtime/smolvm serve start --listen 127.0.0.1:19470
KillMode=control-group
TimeoutStopSec=15s
Restart=no
LimitCORE=0
StandardOutput=journal
StandardError=journal
LogRateLimitIntervalSec=30s
LogRateLimitBurst=100
[Install]
WantedBy=multi-user.target
UNIT
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/smolbox-lab.conf <<'JOURNAL'
[Journal]
SystemMaxUse=32M
RuntimeMaxUse=16M
MaxFileSec=1day
JOURNAL
systemctl restart systemd-journald
systemctl daemon-reload
systemctl enable smolbox-worker.service

runuser -l lab -c 'set -e; elixir --version; cd /opt/smolbox/source; mix local.hex --force; mix local.rebar --force; mix deps.get; mix compile --warnings-as-errors'
dpkg-query -W > /opt/smolbox/guest-packages.txt
uname -a > /opt/smolbox/guest-kernel.txt
sha256sum /opt/smolbox/runtime/smolvm-bin /opt/smolbox/runtime/lib/libkrun.so \
  > /opt/smolbox/runtime-sha256.txt
touch /opt/smolbox/provisioned
echo 'Provisioned. Reboot to the installed kernel, check KVM, then seal while powered off.'
