#!/bin/sh
# Layr8 desktop installer (LAYR8-1946). The customer build is not signed with an Apple certificate, so this script is
# the way in: it installs with curl, which sets no quarantine attribute, so the app opens with no right-click.
#
# Run it by the full commit it was published at, never by a branch or a tag (a branch or a tag can be moved):
#
#   curl -fsSL https://raw.githubusercontent.com/layr8/layr8-desktop/<40-hex commit>/install.sh | sh
#
# desktop/installer-pin.json names that commit and this file's digest; scripts/check-desktop-installer.mjs fails when the
# published copy is not this file.
#
# What it trusts: the public keys below (desktop/release-keys.json, kept equal by a test) and nothing the release page says.
# The release list only names a candidate. Every statement about the candidate (tag, version, channel, architecture, the
# zip's digest) is read from release.json AFTER its signature verified with /usr/bin/openssl. Any failed check stops the
# script with the reason; nothing is installed and nothing falls back to an unchecked path.
#
# Uses only what a Mac with no Command Line Tools has: curl, /usr/bin/openssl (LibreSSL), shasum, ditto, codesign,
# defaults, sw_vers, awk, sed, open. No python3, no gh, no Homebrew, no administrator password.
#
# Env:
#   LAYR8_UPDATE_CHANNEL  latest (default) or next (the team's). A channel given here is saved to
#                         ~/Library/Application Support/Layr8/update-channel.json, so the app's own update check follows it.
#   LAYR8_ALLOW_DOWNGRADE=1  install over a newer Layr8.app (a person who knows why)
#   LAYR8_NO_OPEN=1          do not open the app afterwards
set -eu

PRODUCT="io.layr8.desktop.internal"
HOST="https://github.com"
REPO="layr8/layr8-desktop"
PROTO="--proto =https --tlsv1.2"
APP_NAME="Layr8.app"

die() { echo "install: $*" >&2; exit 1; }
# The two sentences a person reads when no build can be installed (owner's words, rule ad19efbd, LAYR8-2452): the list or the manifest
# was READ and the answer is "none" / it was NOT read. Never the same sentence, each printed alone, each a refusal (exit 1).
say_none() { echo "No stable build is available yet. Nothing was installed." >&2; exit 1; }
say_not_read() { echo "Could not reach GitHub. Nothing was installed. Try again." >&2; exit 1; }

# BEGIN RELEASE KEYS (generated from desktop/release-keys.json; do not edit by hand)
KEY_COUNT=2
KEY_1_ID='desktop-release-2026-a'
KEY_1_PEM='-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEw75+imKO46WMttMfRAeAFFU15nww
m4ikUFzOWR4tr+3qcfMknPXYf9cKTr5jqeI9rGkfH35eYZ+nit/CSMuzIw==
-----END PUBLIC KEY-----'
KEY_2_ID='desktop-release-2026-b'
KEY_2_PEM='-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEghOALTbsHmVdZxTMVwpKDMHvixA2
IP2Yvwm0I9bJDwM4M2Bt4dYbtBA6pYEm/b5XtodyPcdHjcvSV8h454X6EQ==
-----END PUBLIC KEY-----'
# END RELEASE KEYS

# SemVer 2.0 comparison in awk: prints -1, 0 or 1; prints "bad" when either side is not a version.
semver_cmp() {
  awk -v a="$1" -v b="$2" '
    function parse(v, o,   m, n, i, p) {
      if (v !~ /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z.-]+)?$/) return 0
      sub(/\+.*$/, "", v)
      o["pre"] = ""
      i = index(v, "-")
      if (i) {
        o["pre"] = substr(v, i + 1); v = substr(v, 1, i - 1)
        n = split(o["pre"], q, ".")
        for (j = 1; j <= n; j++) if (q[j] ~ /^0[0-9]+$/) return 0
      }
      split(v, p, ".")
      o[1] = p[1] + 0; o[2] = p[2] + 0; o[3] = p[3] + 0
      return 1
    }
    BEGIN {
      if (!parse(a, x) || !parse(b, y)) { print "bad"; exit }
      for (k = 1; k <= 3; k++) if (x[k] != y[k]) { print (x[k] < y[k]) ? -1 : 1; exit }
      if (x["pre"] == "" || y["pre"] == "") { print (x["pre"] == y["pre"]) ? 0 : (x["pre"] == "" ? 1 : -1); exit }
      nx = split(x["pre"], P, "."); ny = split(y["pre"], Q, ".")
      n = (nx > ny) ? nx : ny
      for (k = 1; k <= n; k++) {
        if (k > nx) { print -1; exit }
        if (k > ny) { print 1; exit }
        pn = (P[k] ~ /^[0-9]+$/); qn = (Q[k] ~ /^[0-9]+$/)
        if (pn && qn) { if (P[k] + 0 != Q[k] + 0) { print (P[k] + 0 < Q[k] + 0) ? -1 : 1; exit } }
        else if (pn != qn) { print pn ? -1 : 1; exit }
        else if (P[k] != Q[k]) { print (P[k] < Q[k]) ? -1 : 1; exit }
      }
      print 0
    }'
}
# Dotted macOS versions ("14", "14.6", "15.1.1"): prints -1, 0 or 1, or "bad".
mac_cmp() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    if (a !~ /^[0-9]+(\.[0-9]+){0,2}$/ || b !~ /^[0-9]+(\.[0-9]+){0,2}$/) { print "bad"; exit }
    split(a, x, "."); split(b, y, ".")
    for (k = 1; k <= 3; k++) { p = x[k] + 0; q = y[k] + 0; if (p != q) { print (p < q) ? -1 : 1; exit } }
    print 0 }'
}
# The one value of a manifest line shaped `  "<key>": "<value>"` (the exact shape release.mjs writes); exactly one such line or none.
field() {
  n="$(grep -c "^  \"$1\": " "$work/release.json" || true)"
  [ "$n" = "1" ] || { echo ""; return 0; }
  sed -n "s/^  \"$1\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" "$work/release.json"
}

# The whole run is one function called on the last line: a download cut anywhere is a syntax error (or defines it and
# never calls it), so a truncated `curl | sh` can neither move the installed app aside nor leave it that way.
main() {
  # The private work folder is made next to the destination, on the same volume, so that the final move is one atomic rename
  # and a failure cannot leave half an app (a mv across volumes copies).
  dest="$HOME/Applications"
  mkdir -p "$dest" || die "could not make $dest"
  work="$(mktemp -d "$dest/.layr8-install.XXXXXX")" || die "could not make a private folder"
  trap 'rm -rf "$work"' EXIT
  trap 'exit 1' INT TERM HUP
  chmod 700 "$work"

  # ---- the Mac ----------------------------------------------------------------------------------------------------------
  [ "$(uname -s)" = "Darwin" ] || die "this app is for macOS only"
  # Apple silicon only. A terminal running under Rosetta reports x86_64, so ask the CPU itself.
  arm="$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)"
  [ "$arm" = "1" ] || die "this app needs a Mac with Apple silicon; this one is not"
  macos="$(sw_vers -productVersion)"

  channel="${LAYR8_UPDATE_CHANNEL:-latest}"
  case "$channel" in
    latest) accepted="latest" ;;
    next) accepted="next latest" ;;
    *) die "LAYR8_UPDATE_CHANNEL must be latest or next (got ${channel})" ;;
  esac

  # ---- 1. the candidate: only a name, never trusted ----------------------------------------------------------------------
  # Three readings, kept apart (LAYR8-2452): the list was read and names a build / it was read and there is none (say_none) / it was
  # not read (say_not_read). "Did not read" is never "none", and nothing here falls back to another channel or to an older build.
  if [ "$channel" = "next" ]; then
    # The newest release of any kind, prereleases included (the Atom feed lists them; drafts are not in it).
    feed="$(curl $PROTO -fsSL "$HOST/$REPO/releases.atom" 2>/dev/null)" || say_not_read
    tag="$(printf '%s' "$feed" | grep -o 'releases/tag/[^"]*' | head -1 | sed 's|releases/tag/||')" || tag=""
    [ -n "$tag" ] || say_none
  else
    # GitHub's latest release, which a prerelease never is; the redirect names its tag. Without a full release GitHub answers 404
    # (or sends the page of the whole list), and that is the answer "there is none".
    got="$(curl $PROTO -sSL -o /dev/null -w '%{http_code} %{url_effective}' "$HOST/$REPO/releases/latest" 2>/dev/null)" || say_not_read
    code="${got%% *}"
    url="${got#* }"
    case "$code" in
      200 | 404) : ;;
      *) say_not_read ;;
    esac
    tag="${url##*/releases/tag/}"
    [ "$tag" != "$url" ] || tag=""
    [ -n "$tag" ] || say_none
  fi
  printf '%s' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' || die "the ${channel} channel names a release that is not a build tag (${tag}); nothing was installed"

  # ---- 2. the manifest and its signature --------------------------------------------------------------------------------
  base="$HOST/$REPO/releases/download/$tag"
  code="$(curl $PROTO -sSL -o "$work/release.json" -w '%{http_code}' "$base/release.json" 2>/dev/null)" || say_not_read
  case "$code" in
    200) : ;;
    404) say_none ;;
    *) say_not_read ;;
  esac
  # The signature file is read by the same rule as release.json: a 404 is the server's answer that there is no signed build (none);
  # anything else (503, a cut connection, no route) is not-read. Never an explanation, never an install.
  code="$(curl $PROTO -sSL -o "$work/release.json.sig" -w '%{http_code}' "$base/release.json.sig" 2>/dev/null)" || say_not_read
  case "$code" in
    200) : ;;
    404) say_none ;;
    *) say_not_read ;;
  esac
  [ -s "$work/release.json.sig" ] || die "the signature of $tag is empty"

  signer=""
  i=0
  while [ "$i" -lt "${KEY_COUNT:-0}" ]; do
    i=$((i + 1))
    eval "kid=\$KEY_${i}_ID; kpem=\$KEY_${i}_PEM"
    printf '%s\n' "$kpem" > "$work/key.pem"
    if out="$(/usr/bin/openssl dgst -sha256 -verify "$work/key.pem" -signature "$work/release.json.sig" "$work/release.json" 2>&1)" && printf '%s' "$out" | grep -q 'Verified OK'; then
      signer="$kid"
      break
    fi
  done
  [ -n "$signer" ] || die "the signature of $tag does not verify against any release key this installer carries; nothing was installed"

  # ---- 3. only now is the manifest read ---------------------------------------------------------------------------------
  [ "$(field schema)" = "1" ] || die "the manifest schema is not 1"
  [ "$(field product)" = "$PRODUCT" ] || die "the manifest is for another product"
  [ "$(field keyId)" = "$signer" ] || die "the manifest names a key other than the one that signed it"
  version="$(field version)"
  mtag="$(field tag)"
  mchannel="$(field channel)"
  [ "$(semver_cmp "$version" "$version")" = "0" ] || die "the manifest version is not a version"
  case "$version" in *+*) die "the manifest version carries build metadata" ;; esac
  [ "$mtag" = "v$version" ] || die "the signed tag is not the signed version"
  [ "$mtag" = "$tag" ] || die "the manifest is for $mtag, but it was found under $tag"
  ok=""
  for c in $accepted; do [ "$c" = "$mchannel" ] && ok=1; done
  [ -n "$ok" ] || die "$tag is on the ${mchannel:-unknown} channel; you asked for ${channel}"
  [ "$(field arch)" = "arm64" ] || die "the build is not for Apple silicon"
  minmac="$(field minMacOS)"
  cmp="$(mac_cmp "$macos" "$minmac")"
  [ "$cmp" != "bad" ] || die "could not compare macOS $macos with the build's minimum ${minmac:-none}"
  [ "$cmp" -ge 0 ] || die "this build needs macOS $minmac or later; this Mac has $macos"

  # exactly one file, in the shape release.mjs writes
  names="$(sed -n 's/^    "\([^"]*\)": {$/\1/p' "$work/release.json")"
  [ "$(printf '%s\n' "$names" | grep -c .)" = "1" ] || die "the manifest does not list exactly one file"
  zipname="$names"
  printf '%s' "$zipname" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$' || die "the manifest names a file that is not a plain zip name"
  want_sha="$(sed -n 's/^      "sha256": "\([0-9a-f]\{64\}\)",$/\1/p' "$work/release.json")"
  want_bytes="$(sed -n 's/^      "bytes": \([1-9][0-9]\{0,14\}\)$/\1/p' "$work/release.json")"
  [ -n "$want_sha" ] && [ -n "$want_bytes" ] || die "the manifest has no usable digest and size for $zipname"

  # The signed bytes must be exactly the canonical manifest release.mjs writes, rebuilt here from the values just read: an
  # extra field, other spacing or a duplicate key would be read differently by this script and by the app's parser.
  printf '{\n  "schema": 1,\n  "product": "%s",\n  "version": "%s",\n  "tag": "%s",\n  "channel": "%s",\n  "arch": "arm64",\n  "minMacOS": "%s",\n  "files": {\n    "%s": {\n      "sha256": "%s",\n      "bytes": %s\n    }\n  },\n  "keyId": "%s"\n}\n' \
    "$PRODUCT" "$version" "$mtag" "$mchannel" "$minmac" "$zipname" "$want_sha" "$want_bytes" "$signer" > "$work/canonical.json"
  cmp -s "$work/canonical.json" "$work/release.json" || die "the signed manifest is not in the canonical form (an extra field, other spacing or a duplicate key)"

  # not over a newer app, and not over one whose version cannot be read: "did not read" is not "nothing to protect"
  if [ -e "$dest/$APP_NAME" ] && [ "${LAYR8_ALLOW_DOWNGRADE:-}" != "1" ]; then
    installed_version="$(defaults read "$dest/$APP_NAME/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
    c="$(semver_cmp "$version" "$installed_version")"
    case "$c" in
      1) : ;;
      0 | -1) die "the installed app is $installed_version, which is not older than $version; nothing was changed (LAYR8_ALLOW_DOWNGRADE=1 overrides)" ;;
      *) die "could not read the version of the installed app at $dest/$APP_NAME (read ${installed_version:-nothing}); nothing was changed (LAYR8_ALLOW_DOWNGRADE=1 overrides)" ;;
    esac
  fi

  # ---- 4. the zip -------------------------------------------------------------------------------------------------------
  curl $PROTO -fsSL "$base/$zipname" -o "$work/$zipname" || die "could not download $zipname"
  got_bytes="$(wc -c < "$work/$zipname" | tr -d ' ')"
  [ "$got_bytes" = "$want_bytes" ] || die "$zipname is $got_bytes bytes; the manifest says $want_bytes"
  got_sha="$(shasum -a 256 "$work/$zipname" | awk '{print $1}')"
  [ "$got_sha" = "$want_sha" ] || die "the SHA-256 of $zipname is $got_sha, not the manifest's $want_sha"

  # unpack from the same private folder the digest was taken in, into a new folder
  mkdir "$work/x"
  ditto -x -k "$work/$zipname" "$work/x" || die "could not unpack $zipname"
  app="$work/x/$APP_NAME"
  [ -d "$app" ] || die "the zip holds no $APP_NAME"
  # On an ad hoc build this proves only that the seal is intact (nothing changed since packaging), not who packaged it.
  codesign --verify --deep --strict "$app" 2>"$work/codesign.err" || die "the app's seal does not verify: $(head -1 "$work/codesign.err")"
  bundle_version="$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
  [ "$bundle_version" = "$version" ] || die "the app inside says ${bundle_version:-no version}, not the manifest's $version"

  # ---- 5. install -------------------------------------------------------------------------------------------------------
  old=""
  if [ -e "$dest/$APP_NAME" ]; then
    old="$dest/$APP_NAME.old-$$"
    mv "$dest/$APP_NAME" "$old" || die "could not move the installed app aside"
  fi
  if ! mv "$app" "$dest/$APP_NAME"; then
    [ -z "$old" ] || mv "$old" "$dest/$APP_NAME"
    die "could not put the new app in place; the old one is back"
  fi
  [ -z "$old" ] || rm -rf "$old"

  # the channel the person chose, for the app's own update check
  if [ -n "${LAYR8_UPDATE_CHANNEL:-}" ]; then
    data="$HOME/Library/Application Support/Layr8"
    mkdir -p "$data"
    printf '{"channel":"%s"}\n' "$channel" > "$data/update-channel.json"
  fi

  echo "Installed Layr8 $version ($channel channel) to $dest/$APP_NAME"
  echo "  signed by release key $signer; $zipname sha256:$got_sha"
  [ "${LAYR8_NO_OPEN:-}" = "1" ] || open "$dest/$APP_NAME"
}

main "$@"
