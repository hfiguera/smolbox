#!/usr/bin/env bash
# Run sequentially inside the restricted test VM after install-candidate.sh.
set -euo pipefail
[[ $(hostname) == smolbox-nested && $EUID != 0 && $(systemd-detect-virt) == kvm ]] || exit 1
# shellcheck source=/dev/null
source /etc/profile.d/smolbox-lab.sh
export SMOLBOX_LINUX_CANDIDATE=true
export SMOLBOX_RUNTIME_SOCKET=/srv/sbq/run/api.sock
export SMOLBOX_RUNTIME_URL=http://localhost
export SMOLBOX_DATABASE_SOCKET_DIR=/var/run/postgresql
export SMOLBOX_DATABASE_PORT=5432
export SMOLBOX_DATABASE_USER=lab
export SMOLBOX_DATABASE_NAME=smolbox_contract
export SMOLBOX_PYTHON_SHA256=76e71b388c2127a809fa25ecd01ac9d5e5498ee98c093e4d9f84fc874d5f36f2
cd /opt/smolbox/source
sudo bash scripts/lab/candidate-control.sh start
elixir scripts/lab/run-check.exs runtime-final 14 mix test test/runtime --include runtime --warnings-as-errors
cd examples/durable_host
mix ecto.migrate
elixir ../../scripts/lab/run-check.exs store-final 16 mix test test/store_test.exs test/machine_index_test.exs --warnings-as-errors
elixir ../../scripts/lab/run-check.exs durable-final 25 mix test test/recovery_runtime_test.exs --include runtime --warnings-as-errors
sudo bash /opt/smolbox/source/scripts/lab/candidate-control.sh stop
