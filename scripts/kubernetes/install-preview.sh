#!/usr/bin/env bash
# Administrator-only preview infrastructure, entirely inside the lab guest.
set -euo pipefail
umask 077
[[ $EUID == 0 && $(hostname) == smolbox-k3s && $(systemd-detect-virt) == kvm ]] || exit 1
scripts=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ $scripts == /home/lab/smolbox-kubernetes ]] || exit 1
test -f /etc/smolbox-kubernetes-lab/pins.json
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
cd "$scripts"
python3 - <<'PY'
from qualify import MANAGER, owned_object
from smoke import Kubernetes
kube = Kubernetes()
labels = {"app.kubernetes.io/managed-by": MANAGER}
owned_object(kube, "namespace", "smolbox-preview", {
    "apiVersion": "v1", "kind": "Namespace", "metadata": {"name": "smolbox-preview", "labels": labels}})
owned_object(kube, "networkpolicy", "offline", {
    "apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
    "metadata": {"name": "offline", "namespace": "smolbox-preview", "labels": labels},
    "spec": {"podSelector": {}, "policyTypes": ["Ingress", "Egress"], "ingress": [], "egress": []}}, "smolbox-preview")
owned_object(kube, "runtimeclass", "smolbox-preview", {
    "apiVersion": "node.k8s.io/v1", "kind": "RuntimeClass",
    "metadata": {"name": "smolbox-preview", "labels": labels}, "handler": "smolvm",
    "overhead": {"podFixed": {"cpu": "250m", "memory": "512Mi"}},
    "scheduling": {"nodeSelector": {"smolvm-runtime": "true", "kubernetes.io/hostname": "smolbox-k3s",
                                     "kubernetes.io/arch": "amd64"}}})
PY
install -D -m 0644 "$scripts/offline_guard.py" /usr/local/lib/smolbox-kubernetes/offline_guard.py
cat > /etc/systemd/system/smolbox-preview-offline.service <<'UNIT'
[Unit]
Description=SmolBox preview namespace bridge isolation
After=k3s.service
Requires=k3s.service
[Service]
Type=exec
ExecStartPre=/usr/bin/python3 /usr/local/lib/smolbox-kubernetes/offline_guard.py install
ExecStart=/usr/bin/python3 /usr/local/lib/smolbox-kubernetes/offline_guard.py serve
Restart=on-failure
RestartSec=5s
MemoryMax=256M
TasksMax=32
CPUQuota=25%
UMask=0077
NoNewPrivileges=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable smolbox-preview-offline.service
# Restart after installing code: an already running Python process otherwise
# keeps its old program while a file hash would describe the replacement.
systemctl restart smolbox-preview-offline.service
python3 /usr/local/lib/smolbox-kubernetes/offline_guard.py once
echo 'Preview offline guard installed inside the disposable node.'
