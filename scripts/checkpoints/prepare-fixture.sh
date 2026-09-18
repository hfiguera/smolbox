#!/usr/bin/env bash
# Ordinary bounded probe only. Use a dedicated, empty smolvm 1.16.1 worker.
# Captures an idle offline guest with synthetic disk and RAM data; no user code.
set -euo pipefail
umask 077
socket=${1:?Expected dedicated worker Unix socket}
output=${2:?Expected absolute new checkpoint output path}
[[ $socket == /* && -S $socket && $output == /*.smolcheckpoint && ! -e $output ]] || exit 1
name="sbck-$(date +%s)-$$"
request() {
  curl --fail --silent --show-error --max-time 120 --unix-socket "$socket" "$@"
}
# Keep creation evidence available to the operator if a transport response is lost.
request -H 'Content-Type: application/json' -d "{\"name\":\"$name\",\"cpus\":1,\"memoryMb\":256,\"storageGb\":1,\"overlayGb\":1,\"network\":false}" \
  http://localhost/api/v1/machines > "$output.create.json"
request -H 'Content-Type: application/json' -d '{}' "http://localhost/api/v1/machines/$name/start?branchable=true" > "$output.start.json"
request -H 'Content-Type: application/json' -d '{"command":["/bin/sh","-c","mkdir -p /workspace; echo baseline >/workspace/baseline; echo warm >/dev/shm/smolbox-marker"],"timeoutSecs":10}' \
  "http://localhost/api/v1/machines/$name/exec" > "$output.exec.json"
request --max-filesize 536870912 -X POST --output "$output" "http://localhost/api/v1/machines/$name/checkpoint"
printf 'Captured %s from %s. Verify the saved replies, approve the checkpoint, and delete the source using its saved creation evidence.\n' "$output" "$name"
