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
#   4. the app is launched, and it starts a broker daemon from its own bundled copy (Contents/Resources/bin/layr8-broker),
#      which `file` also reads as x86_64. A packaged app starts a daemon only for a chosen profile, so the smoke first writes
#      the choice the app reads (<userData>/profile.json, profile smoke/x64), and that profile's file
#      ~/.config/layr8/smoke/x64.json: without it the app's main script throws before it starts anything and Electron shows
#      only an error dialog (LAYR8-2109, run 44825106863). The file is a placeholder, no credential: a loopback agent DID, a node
#      URL on the discard port (ws://127.0.0.1:9, no node answers) and an API key that is not one. A smoke/x64 file that is not
#      that placeholder is never overwritten. ~/.layr8 is made too (0700), or the app would have nowhere to open the daemon's
#      log. No other layr8-broker may be where the app looks for an installed one (~/.local/bin, /opt/homebrew/bin,
#      /usr/local/bin, PATH), so the bundled copy is the only one it can start. It passes when the daemon's log, which the
#      app opens for that profile (~/.layr8/broker-smoke.x64.log), says `listening on <its socket>`: the daemon got past its
#      config and agent DID checks and took its socket. A process seen running is not enough, as a daemon that refuses its
#      config is seen too before it exits. With no node to reach, the daemon stays up (measured for 90 s on Linux at
#      layr8-broker 2f85e4a9), polling the node. It does not prove enrolment or a node connection. ~/.local/bin is not checked:
#      on a HOME with no broker installed, the app copies nothing there (src/broker/desktop-install.ts, "not-installed");
#   5. the app is still running a few seconds later.
#
# What the smoke saw is kept in $RUNNER_TEMP/layr8-x64-smoke (the workflow uploads it, red or green): the app's stderr and
# stdout apart, a process list every 10 s, `file` on the app and the broker, the daemon's log, and what the app's windows say
# (dialog.txt: an error dialog's words, read with osascript through System Events; if that is not allowed, its refusal).
# A failure from step 4 on also prints their last lines.
#
# The last line of every run is one plain line: "x64 smoke: broker started (<version>) on <tag>", or
# "x64 smoke: FAILED at <step>: <why> (<tag>)". Uses sh, uname, sysctl, defaults, lipo, file, ps, osascript, sed, grep,
# tail, cat, chmod, cp, rm and mkdir.
set -u

tag="${1:-}"
on="${tag:-the newest build on next}"
step="1 Intel"
app_pid=""
waited=""
diag="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/layr8-x64-smoke"
mkdir -p "$diag"
profile="smoke/x64"
daemon_log="$HOME/.layr8/broker-smoke.x64.log"
# A process list (the app, brokers, Claude) and ~/.local/bin, appended to ps.txt.
snapshot() {
  { echo "--- ${waited:-?}s"
    ps -axww -o pid,ppid,stat,etime,command 2>&1 | grep -i -e '[L]ayr8' -e '[l]ayr8-broker' -e '[c]laude'
    ls -la "$HOME/.local/bin" 2>&1; } >> "$diag/ps.txt"
}
# What the app's windows say, into dialog.txt: an error in the app's main script reaches no log, only Electron's dialog
# ("A JavaScript error occurred in the main process"). osascript is given 10 s, as a permission prompt could hold it.
# Kept only when it says something.
dialog() {
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $app_pid) to get value of every static text of every window" > "$diag/dialog.txt" 2>&1 &
  o=$!
  i=0
  while kill -0 "$o" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
  kill "$o" 2>/dev/null
  grep -q '[^[:space:]]' "$diag/dialog.txt" 2>/dev/null || rm -f "$diag/dialog.txt"
}
# Everything kept so far, and the last lines of each, into the job's output.
dump() {
  [ -z "$app_pid" ] || { snapshot; dialog; }
  [ ! -e "$daemon_log" ] || cp "$daemon_log" "$diag/daemon.log"
  ls -la "$HOME/.layr8" "$HOME/Library/Application Support/Layr8" > "$diag/state.txt" 2>&1
  for f in dialog.txt app.stderr app.stdout daemon.log file.txt state.txt; do
    [ ! -s "$diag/$f" ] || { echo "--- $f (last 40 lines)"; tail -40 "$diag/$f"; }
  done
  [ ! -s "$diag/ps.txt" ] || { echo "--- ps.txt (last snapshot)"; sed -n '/^--- /h;/^--- /!H;${x;p;}' "$diag/ps.txt"; }
}
fail() {
  [ "${step%% *}" -lt 4 ] || dump
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
printf '%s\n' "$bundled" > "$diag/bundled-version.json"
file "$broker" "$app/Contents/MacOS/Layr8" > "$diag/file.txt" 2>&1
kind="$(file -b "$broker" 2>&1)"
case "$kind" in *x86_64*) ;; *) fail "file reads the bundled broker as \"$kind\", not x86_64" ;; esac
# The app starts an installed broker in preference to its own copy (desktop/src/core/daemon-link.mjs installedBroker):
# none may be there, or a daemon seen below would not be the bundled one.
old_ifs="$IFS"; IFS=:
for d in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin $PATH; do
  [ ! -e "$d/layr8-broker" ] || { IFS="$old_ifs"; fail "$d/layr8-broker exists, so the app would start that broker, not its own copy"; }
done
IFS="$old_ifs"
# The profile's file, a placeholder with no credential (src/config.ts loadConfig needs nodeUrl and apiKey, daemon.ts and
# snapshot.mjs agentDidOf need agentDid). 0600 in 0700 folders, as an enrolment writes it.
placeholder='{"agentDid":"did:web:127.0.0.1:agents:smoke","nodeUrl":"ws://127.0.0.1:9","apiKey":"not-a-key"}'
config="$HOME/.config/layr8/smoke/x64.json"
if [ -e "$config" ]; then
  [ "$(cat "$config")" = "$placeholder" ] || fail "~/.config/layr8/smoke/x64.json exists and is not the smoke's placeholder; the smoke does not overwrite a profile"
else
  (umask 077 && mkdir -p "${config%/*}" && printf '%s\n' "$placeholder" > "$config") || fail "could not write ~/.config/layr8/smoke/x64.json"
fi
chmod 700 "$HOME/.config/layr8" "${config%/*}"
(umask 077 && mkdir -p "$HOME/.layr8") && chmod 700 "$HOME/.layr8" || fail "could not make ~/.layr8"
support="$HOME/Library/Application Support/Layr8"
mkdir -p "$support"
printf '{"profile":"%s"}\n' "$profile" > "$support/profile.json"
log="$diag/app.stderr"
"$app/Contents/MacOS/Layr8" > "$diag/app.stdout" 2> "$log" &
app_pid=$!
waited=0
# The daemon's own line (src/broker/log.ts: "[layr8-broker] <time> listening on <socket> (v<version>)").
listening='layr8-broker] .* listening on .*/\.layr8/broker-smoke\.x64\.sock '
until grep -q -e "$listening" "$daemon_log" 2>/dev/null; do
  [ $((waited % 10)) -ne 0 ] || snapshot
  kill -0 "$app_pid" 2>/dev/null || { app_pid=""; fail "the app exited before its broker daemon said it is listening; its last line: $(tail -1 "$log")"; }
  if [ "$waited" -ge "${SMOKE_WAIT:-120}" ]; then
    if [ -s "$daemon_log" ]; then fail "the app's broker daemon did not say it is listening within ${SMOKE_WAIT:-120}s (last line of ~/.layr8/broker-smoke.x64.log: $(tail -1 "$daemon_log"))"
    else fail "the app's broker daemon did not say it is listening within ${SMOKE_WAIT:-120}s (~/.layr8/broker-smoke.x64.log is empty)"; fi
  fi
  sleep 1
  waited=$((waited + 1))
done
snapshot
[ ! -e "$daemon_log" ] || cp "$daemon_log" "$diag/daemon.log"

# ---- 5 ----
step="5 running"
sleep "${SMOKE_SETTLE:-5}"
kill -0 "$app_pid" 2>/dev/null || { app_pid=""; fail "the app exited after its broker started; its last line: $(tail -1 "$log")"; }
kill "$app_pid" 2>/dev/null
echo "x64 smoke: broker started ($(printf '%s' "$bundled" | version_of)) on $on"
