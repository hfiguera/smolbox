#!/usr/bin/env bash
# Select a reviewed distribution only inside the stopped disposable candidate.
set -euo pipefail
[[ $EUID == 0 && $(hostname) == smolbox-nested && $(systemd-detect-virt) == kvm ]] || exit 1
version=${1:?Expected 1.14.1 or 1.14.6}
case "$version" in
  1.14.1) runtime=/opt/smolbox/runtime ;;
  1.14.6) runtime=/opt/smolbox/runtime-1.14.6 ;;
  *) exit 1 ;;
esac
unit=smolbox-qualification.service
[[ $(systemctl show "$unit" -p MainPID --value) == 0 ]] || exit 1
! pgrep -u smolbox-qual >/dev/null || exit 1
[[ ! -L $runtime && -x $runtime/smolvm ]] || exit 1
[[ $("$runtime/smolvm" --version) == "smolvm $version" ]] || exit 1
directory=/run/systemd/system/$unit.d
install -d -m 0755 "$directory"
cat > "$directory/20-runtime.conf" <<UNIT
[Service]
Environment=SMOLBOX_CANDIDATE_VERSION=$version
ExecStart=
ExecStart=$runtime/smolvm serve start --listen unix:///srv/sbq/run/api.sock --seccomp enforce --landlock enforce
ReadOnlyPaths=$runtime
UNIT
systemctl daemon-reload
systemd-analyze verify "$unit"
printf 'Selected %s; the candidate startup preflight still verifies all pinned bytes.\n' "$version"
