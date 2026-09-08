#!/usr/bin/env bash
set -euo pipefail
[[ $(uname -s) == Linux && $(hostname) == smolbox-nested && $EUID != 0 ]] || exit 1
# shellcheck source=/dev/null
source /etc/profile.d/smolbox-lab.sh
cd /opt/smolbox/source
mix run /home/lab/input/network-probe.exs
mix run /home/lab/input/nested-probe.exs
elixir scripts/ci.exs bounded --report /home/lab/runtime.json --timeout 600 --expected-tests 14 -- \
  mix test test/runtime --include runtime --warnings-as-errors
curl --fail --silent --show-error --max-time 5 http://127.0.0.1:19470/api/v1/machines \
  | jq -e '.machines == []'
echo 'All nested guest checks passed with empty worker inventory.'
