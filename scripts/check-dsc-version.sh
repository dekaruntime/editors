#!/bin/sh
# Drift check: every client's pinned dsc version must match the repo-root
# DSC_VERSION file, the single source of truth. Fails the build if someone
# bumps one pin without the others.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WANT="$(tr -d '[:space:]' < "$ROOT/DSC_VERSION")"
if [ -z "$WANT" ]; then
  echo "::error::DSC_VERSION file is empty"
  exit 1
fi

fail() {
  echo "::error::$1"
  exit 1
}

# Zed compiles the pin straight from the file via include_str!, so it cannot
# drift by itself — but guard the include so a refactor cannot silently
# re-hardcode a version there.
grep -q 'include_str!("../../DSC_VERSION")' "$ROOT/zed/src/lib.rs" \
  || fail "zed/src/lib.rs no longer includes the repo-root DSC_VERSION file"

# VS Code's pin is generated from the file at build time
# (scripts/sync-dsc-version.js) and the generated source is committed, so a
# hand-edit or a missed regen shows up here.
grep -q "export const DSC_VERSION = '$WANT';" "$ROOT/vscode/src/dsc-version.ts" \
  || fail "vscode/src/dsc-version.ts is stale; run scripts/sync-dsc-version.js (want $WANT)"

# Neovim prefers the repo-root file at runtime with a fallback constant for
# installs outside the repo. The dynamic check below cannot see the fallback
# while the repo file exists (the file wins), so also pin the fallback text.
grep -q "M.DSC_VERSION = pinned_version() or '$WANT'" "$ROOT/nvim/lua/deka/discovery.lua" \
  || fail "nvim fallback pin is stale; keep it in step with the root file (want $WANT)"
GOT="$(nvim --headless -u NONE -l "$ROOT/scripts/print-nvim-dsc-version.lua" "$ROOT" 2>/dev/null)"
[ "$GOT" = "$WANT" ] \
  || fail "nvim plugin resolves dsc v$GOT, expected v$WANT"

echo "dsc version pins in step: $WANT"
