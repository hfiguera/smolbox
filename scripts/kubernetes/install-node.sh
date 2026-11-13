#!/usr/bin/env bash
# All privileged changes stay inside the new, disposable Kubernetes VM.
set -euo pipefail
umask 077
[[ $EUID == 0 && $(hostname) == smolbox-k3s && $(systemd-detect-virt) == kvm ]] || exit 1
scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ $scripts == /home/lab/smolbox-kubernetes ]] || exit 1
[[ -c /dev/kvm ]] || modprobe kvm_intel
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
  ca-certificates curl jq python3 zstd iproute2 util-linux
for name in k3s smolvm; do
  file=$scripts/$name
  [[ $name != smolvm ]] || file=$scripts/smolvm.tar.gz
  printf '%s  %s\n' "$(jq -r ".$name.sha256" "$scripts/pins.json")" "$file" | sha256sum --check
done
version=$(jq -r .smolvm.version "$scripts/pins.json")
runtime=/opt/smolvm-$version-linux-x86_64
owner=/etc/smolbox-kubernetes-lab
if [[ ! -e $owner ]]; then
  [[ ! -e /var/lib/rancher/k3s && ! -e $runtime ]] || exit 1
  install -d -m 0700 "$owner"
  cp "$scripts/pins.json" "$owner/pins.json"
fi
cmp "$scripts/pins.json" "$owner/pins.json"
if [[ ! -d $runtime ]]; then
  tar --extract --gzip --file "$scripts/smolvm.tar.gz" --directory /opt --no-same-owner
fi
test -x "$runtime/containerd-shim-smolvm-v2"
for template in storage overlay; do
  if [[ ! -f $runtime/$template-template.ext4 ]]; then
    zstd --decompress --sparse -o "$runtime/$template-template.ext4" \
      "$runtime/$template-template.ext4.zst"
  fi
done
if ! cmp -s "$scripts/k3s" /usr/local/bin/k3s; then
  install -m 0755 "$scripts/k3s" /usr/local/bin/k3s.part
  mv -f /usr/local/bin/k3s.part /usr/local/bin/k3s
fi
for command in kubectl crictl ctr; do
  ln -sfn k3s "/usr/local/bin/$command"
done
ln -sfn "$runtime/containerd-shim-smolvm-v2" /usr/local/bin/containerd-shim-smolvm-v2
mkdir -p /etc/rancher/k3s /var/lib/rancher/k3s/agent/etc/containerd
mkdir -p /var/lib/smolbox-kubernetes/{data,cache,config}
cat > /etc/rancher/k3s/config.yaml <<'YAML'
node-name: smolbox-k3s
node-label:
  - smolvm-runtime=true
write-kubeconfig-mode: "0600"
disable:
  - traefik
  - servicelb
  - local-storage
secrets-encryption: true
kubelet-arg:
  - image-gc-high-threshold=65
  - image-gc-low-threshold=50
YAML
cat > /var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl <<'TOML'
{{ template "base" . }}
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.smolvm]
  runtime_type = 'io.containerd.smolvm.v2'
  sandboxer = 'podsandbox'
TOML
cat > /etc/systemd/system/k3s.service <<UNIT
[Unit]
Description=SmolBox development Kubernetes node
After=network-online.target
Wants=network-online.target
[Service]
Type=notify
ExecStart=/usr/local/bin/k3s server
KillMode=process
Delegate=yes
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
LimitNPROC=infinity
TasksMax=infinity
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=SMOLVM_LIB_DIR=$runtime/lib
Environment=SMOLVM_AGENT_ROOTFS=$runtime/agent-rootfs
Environment=XDG_DATA_HOME=/var/lib/smolbox-kubernetes/data
Environment=XDG_CACHE_HOME=/var/lib/smolbox-kubernetes/cache
Environment=XDG_CONFIG_HOME=/var/lib/smolbox-kubernetes/config
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now k3s
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
until kubectl get node smolbox-k3s >/dev/null 2>&1; do
  (( SECONDS < 600 )) || { echo 'K3s startup timed out; inspect its journal inside the guest.' >&2; exit 1; }
  sleep 3
done
kubectl wait --for=condition=Ready node/smolbox-k3s --timeout=180s
kubectl apply -f "$runtime/kubernetes/runtimeclass.yaml"
k3s --version
kubectl get nodes -o wide
echo 'K3s node and the real SmolVM RuntimeClass are installed.'
