#!/usr/bin/env bash
# Extend the approved bare fixture while its source is still running.
# All commands finish before capture; only synthetic data remains in RAM.
set -euo pipefail
umask 077
socket=${1:?Expected dedicated worker Unix socket}
creation=${2:?Expected saved bare fixture creation JSON}
output=${3:?Expected new absolute checkpoint output path}
[[ $socket == /* && -S $socket && $output == /*.smolcheckpoint && ! -e $output ]] || exit 1
name=$(jq -er .name "$creation")
[[ $name =~ ^sbck-[0-9]+-[0-9]+$ ]] || exit 1
request() { curl --fail --silent --show-error --max-time 120 --unix-socket "$socket" "$@"; }
request "http://localhost/api/v1/machines/$name" > "$output.inspect.json"
# The source must still match its saved identity and captured allocations.
jq -e --slurpfile source "$creation" '
  .state == "running" and .network == false and
  ([.name,.createdAt,.cpus,.memoryMb,.storageGb,.overlayGb] ==
   ($source[0] | [.name,.createdAt,.cpus,.memoryMb,.storageGb,.overlayGb]))' \
  "$output.inspect.json" >/dev/null
program=$(cat <<'PROGRAM'
set -eu
cat > /workspace/prepare.sh <<'PREPARE'
set -eu
# Decompress before aggregation so either failure is observed, even without pipefail.
gzip -dc /workspace/events.csv.gz > /dev/shm/events.csv
awk -F, '{count[$1]++; total[$1]+=$2} END {for (id in count) printf "%d %d %.0f\n", id, count[id], total[id]}' /dev/shm/events.csv > /dev/shm/stations.tsv
rm /dev/shm/events.csv
PREPARE
awk 'BEGIN {for (i=0; i<1000000; i++) printf "%d,%d\n", i%1000, (i*37)%10000}' > /workspace/events.csv
gzip -n /workspace/events.csv
sh /workspace/prepare.sh
# A prepared image can also load this small serialized table without re-aggregating.
cp /dev/shm/stations.tsv /workspace/stations-precomputed.tsv
awk '$1 == 42 {print}' /dev/shm/stations.tsv
PROGRAM
)
jq -n --arg program "$program" '{command:["/bin/sh","-c",$program],timeoutSecs:60}' > "$output.request.json"
request -H 'Content-Type: application/json' --data-binary "@$output.request.json" \
  "http://localhost/api/v1/machines/$name/exec" > "$output.exec.json"
jq -e '.exitCode == 0 and .stdout == "42 1000 5054000\n"' "$output.exec.json" >/dev/null
request --max-filesize 536870912 -X POST --output "$output" "http://localhost/api/v1/machines/$name/checkpoint"
printf 'Captured idle dataset checkpoint. Preserve creation evidence and verify source identity before cleanup.\n'
