#!/bin/sh
set -eu

cd "$(git rev-parse --show-toplevel)"

fail() {
  printf 'install-hooks: %s\n' "$*" >&2
  exit 1
}

if git config --get core.hooksPath >/dev/null; then
  fail 'core.hooksPath is already configured. Keep that hook setup and integrate the versioned hooks there.'
fi

hooks=$(git rev-parse --path-format=absolute --git-path hooks)
mkdir -p "$hooks"
scratch=$(mktemp -d "$hooks/.smolbox-install.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

cat > "$scratch/pre-commit" <<'HOOK'
#!/bin/sh
if [ -x .githooks/pre-commit ]; then exec .githooks/pre-commit "$@"; fi
HOOK

cat > "$scratch/pre-push" <<'HOOK'
#!/bin/sh
if [ -x .githooks/pre-push ]; then exec .githooks/pre-push "$@"; fi
previous=$(git rev-parse --git-path hooks/pre-push.smolbox-original) || exit
if [ -x "$previous" ]; then exec "$previous" "$@"; fi
HOOK

chmod +x "$scratch/pre-commit" "$scratch/pre-push"

if [ -e "$hooks/pre-commit" ] || [ -L "$hooks/pre-commit" ]; then
  cmp -s "$hooks/pre-commit" "$scratch/pre-commit" || fail 'an existing pre-commit hook needs manual integration.'
fi

if [ -e "$hooks/pre-push" ] || [ -L "$hooks/pre-push" ]; then
  if ! cmp -s "$hooks/pre-push" "$scratch/pre-push"; then
    previous="$hooks/pre-push.smolbox-original"
    if [ -e "$previous" ] || [ -L "$previous" ]; then
      cmp -s "$hooks/pre-push" "$previous" || fail 'the pre-push backup already exists.'
    else
      cp -pP "$hooks/pre-push" "$previous"
    fi
  fi
fi

mv "$scratch/pre-commit" "$scratch/pre-push" "$hooks/"
echo 'Installed SmolBox pre-commit and pre-push hooks.'
