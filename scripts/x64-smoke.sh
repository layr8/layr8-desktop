#!/bin/sh
# The Intel smoke of a release (LAYR8-2109; owner rule 60f672cc, run on macos-15-intel per rule 7aabe0fc). Run from the root of
# layr8/layr8-desktop by .github/workflows/x64-smoke.yml on GitHub's hosted Intel Mac, after each release is published:
#
#   sh scripts/x64-smoke.sh [<tag>]
#
# It runs beside the release and gates nothing: no job needs it and promotion does not wait for it. A red run is seen on this
# repository's Actions page only, and is raised to the owner by whoever reads it; it is not a stop by itself.
#
#   1. this is an Intel Mac: uname -m is x86_64 AND the CPU says it is not Apple silicon (Rosetta on Apple silicon reports
#      x86_64 too, and is not a real Intel run);
#   2. install.sh of this checkout (the published installer) installs the newest build on next into this HOME, as a person
#      would, so the installer's Intel path runs too. With <tag>, that build must be <tag> (the feed can lag the release by a
#      minute: it is tried again);
#   3. the app, its broker and its Claude binary are x86_64 only, and the Claude binary runs;
#   4. the app is launched, and its bundled broker starts: it installs itself to ~/.local/bin (`__desktop-install`, which the
#      app runs at its first start on a person's own HOME), and the copy there carries the bundled broker's build;
#   5. the app is still running a few seconds later.
#
# The last line of every run is one plain line: "x64 smoke: broker started (<version>) on <tag>", or
# "x64 smoke: FAILED at <step>: <why> (<tag>)". Uses sh, uname, sysctl, defaults, lipo, sed and grep.
set -u

tag="${1:-}"
on="${tag:-the newest build on next}"
step="1 Intel"
app_pid=""
fail() {
  [ -z "$app_pid" ] || kill "$app_pid" 2>/dev/null
  echo "x64 smoke: FAILED at $step: $* ($on)"
  exit 1
}
commit_of() { sed -n 's/.*"commit":"\([0-9a-f]\{40\}\)".*/\1/p'; }
version_of() { sed -n 's/^{"version":"\([^"]*\)".*/\1/p'; }

# ---- 1 ----
[ "$(uname -m)" = "x86_64" ] || fail "uname -m is $(uname -m), not x86_64"
[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ] || fail "this CPU is Apple silicon (Rosetta, not a real Intel run)"

# ---- 2 ----
step="2 install"
app="$HOME/Applications/Layr8.app"
tries="${SMOKE_TRIES:-5}"
n=0
while :; do
  n=$((n + 1))
  out="$(LAYR8_UPDATE_CHANNEL=next LAYR8_NO_OPEN=1 LAYR8_ALLOW_DOWNGRADE=1 sh ./install.sh 2>&1)"
  rc=$?
  echo "$out"
  version="$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
  if [ "$rc" = "0" ] && { [ -z "$tag" ] || [ "v$version" = "$tag" ]; }; then break; fi
  [ "$n" -lt "$tries" ] || fail "install.sh exited $rc and installed ${version:-nothing}$([ -n "$tag" ] && echo ", not $tag")"
  sleep "${SMOKE_RETRY_SECONDS:-30}"
done
[ -n "$tag" ] || on="v$version"
echo "$out" | grep -q -- '-x64\.zip' || fail "install.sh did not install the x64 zip"

# ---- 3 ----
step="3 x86_64"
broker="$app/Contents/Resources/bin/layr8-broker"
claude="$app/Contents/Resources/app/node_modules/@anthropic-ai/claude-agent-sdk-darwin-x64/claude"
for f in "$app/Contents/MacOS/Layr8" "$broker" "$claude"; do
  [ -f "$f" ] || fail "${f#"$app"/} is missing"
  a="$(lipo -archs "$f" 2>/dev/null)"
  [ "$a" = "x86_64" ] || fail "${f#"$app"/} is ${a:-not a Mach-O}, not x86_64"
done
"$claude" --version > /dev/null 2>&1 || fail "the Claude binary does not run"

# ---- 4 ----
step="4 broker"
bundled="$("$broker" version --json 2>/dev/null)" || fail "the bundled broker does not run"
want="$(printf '%s' "$bundled" | commit_of)"
[ -n "$want" ] || fail "the bundled broker reports no build commit: $bundled"
log="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/layr8-x64-smoke-app.log"
"$app/Contents/MacOS/Layr8" > "$log" 2>&1 &
app_pid=$!
installed="$HOME/.local/bin/layr8-broker"
waited=0
until [ -x "$installed" ] && [ "$("$installed" version --json 2>/dev/null | commit_of)" = "$want" ]; do
  kill -0 "$app_pid" 2>/dev/null || { app_pid=""; fail "the app exited before its broker started; its last line: $(tail -1 "$log")"; }
  [ "$waited" -lt "${SMOKE_WAIT:-120}" ] || fail "the app's broker did not install itself to ~/.local/bin within ${SMOKE_WAIT:-120}s"
  sleep 1
  waited=$((waited + 1))
done

# ---- 5 ----
step="5 running"
sleep "${SMOKE_SETTLE:-5}"
kill -0 "$app_pid" 2>/dev/null || { app_pid=""; fail "the app exited after its broker started; its last line: $(tail -1 "$log")"; }
kill "$app_pid" 2>/dev/null
echo "x64 smoke: broker started ($(printf '%s' "$bundled" | version_of)) on $on"
