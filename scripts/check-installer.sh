#!/bin/sh
# Run from the root of layr8/layr8-desktop (LAYR8-2452). install.sh, installer-pin.json and README.md are written together from
# layr8-broker's desktop/install.sh (desktop/scripts/installer-files.mjs), so they can only be changed together. This fails when:
#   - installer-pin.json is not a 40-hex commit and a 64-hex digest;
#   - install.sh here is not the installer the pin names (one byte of difference is enough);
#   - the pinned commit holds another install.sh than this branch does;
#   - README.md does not give the install command for the pinned commit, names a branch in it, or names gh anywhere.
# With --online (the daily run, no pull request needed) it also reads the published address, raw.githubusercontent.com at the
# pinned commit, with curl, and fails when that is not the pinned installer or cannot be read: a read that failed is not a pass.
# Needs the full history (the pinned commit is read from it). Uses sh, sed, grep, shasum, awk, git, cmp (and curl with --online).
set -eu
fail() { echo "check-installer: $*" >&2; exit 1; }

[ -f installer-pin.json ] || fail "installer-pin.json is missing"
commit="$(sed -n 's/^  "commit": "\([0-9a-f]\{40\}\)",\{0,1\}$/\1/p' installer-pin.json)"
digest="$(sed -n 's/^  "sha256": "\([0-9a-f]\{64\}\)",\{0,1\}$/\1/p' installer-pin.json)"
[ -n "$commit" ] && [ -n "$digest" ] || fail "installer-pin.json has no 40-hex commit and 64-hex digest"

[ -f install.sh ] || fail "install.sh is missing"
got="$(shasum -a 256 install.sh | awk '{print $1}')"
[ "$got" = "$digest" ] || fail "install.sh is not the pinned installer (sha256:$got; the pin says sha256:$digest). Re-publish it from layr8-broker's desktop/install.sh"

git cat-file -e "$commit^{commit}" 2>/dev/null || fail "the pinned commit $commit is not in this checkout (fetch the whole history)"
git show "$commit:install.sh" | cmp -s - install.sh || fail "install.sh at the pinned commit $commit is not the install.sh on this branch"

[ -f README.md ] || fail "README.md is missing"
grep -Fq "curl -fsSL https://raw.githubusercontent.com/layr8/layr8-desktop/$commit/install.sh | sh" README.md || fail "README.md does not give the install command for the pinned commit $commit"
if grep -Eq 'raw\.githubusercontent\.com/layr8/layr8-desktop/(main|master|HEAD)/' README.md; then fail "README.md installs from a branch; it must name the pinned commit"; fi
if grep -Eq '(^|[^A-Za-z0-9_])gh([^A-Za-z0-9_]|$)' README.md; then fail "README.md names gh; the install needs no gh"; fi
if [ "${1:-}" = "--online" ]; then
  url="https://raw.githubusercontent.com/layr8/layr8-desktop/$commit/install.sh"
  body="$(mktemp)"
  trap 'rm -f "$body"' EXIT
  curl -fsSL --proto '=https' --tlsv1.2 "$url" > "$body" 2>/dev/null || fail "could not read the published address $url. This is not a pass: nothing was compared"
  pub="$(shasum -a 256 "$body" | awk '{print $1}')"
  [ "$pub" = "$digest" ] || fail "the published address $url is not the pinned installer (sha256:$pub; the pin says sha256:$digest)"
  echo "check-installer: the published address serves the pinned installer"
fi
echo "check-installer: install.sh, installer-pin.json and README.md agree (pinned commit $commit, sha256:$digest)"
