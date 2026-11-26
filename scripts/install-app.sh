#!/usr/bin/env bash
# scripts/install-app.sh [HOST] [BUNDLE]: install the signed app in ~/Applications, on this Mac or on HOST over SSH.
#
# BUNDLE defaults to build/<APP_EXECUTABLE>.app (scripts/release-app.sh leaves the published build there). The bundle must be signed
# with a certificate (an installed app updates itself only from a build carrying the same designated requirement, so the first install
# has to be a signed build). The copy is checked where it lands (`codesign --verify --strict -R=<requirement>`: the requirement's text
# alone proves nothing), a running copy is asked to quit (it is a reader: if it does not quit, nothing is replaced), and the new
# bundle is swapped in by rename; the old one stays as .<APP_EXECUTABLE>.app.previous until the next install. One install at a time
# (a lock folder), a staging folder unique to each run, never over a newer build unless FORCE=1, the previous bundle put back on a
# failure. Nothing else is set: which archive the app opens is chosen in its Settings.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/product.env
HOST="${1:-}"
SRC="${2:-build/$APP_EXECUTABLE.app}"
[ -d "$SRC/Contents" ] || { echo "no bundle at $SRC: run scripts/release-app.sh (or scripts/bundle.sh with SIGN_IDENTITY) first" >&2; exit 1; }
codesign --verify --strict "$SRC"
REQ="$(codesign -d -r- "$SRC" 2>&1 | sed -n 's/^designated => //p')"
[[ $REQ == *"certificate leaf"* ]] || { echo "$SRC is not certificate-signed ($REQ); refusing" >&2; exit 1; }
codesign --verify --strict "-R=$REQ" "$SRC"
[[ $REQ != *"'"* && $REQ != *$'\n'* ]] || { echo "the requirement cannot be passed on: $REQ" >&2; exit 1; }
VERSION="$(defaults read "$(cd "$SRC" && pwd)/Contents/Info.plist" CFBundleShortVersionString)"
BUILD="$(defaults read "$(cd "$SRC" && pwd)/Contents/Info.plist" CFBundleVersion)"

# Runs where the app is installed, with NEW = a staging folder unique to this run holding the bundle (one install at a time under
# a lock, never over a newer build unless FORCE=1, the previous bundle restored on any failure). The name and identifier come in
# the environment (APP_NAME, APP_EXECUTABLE, BUNDLE_ID), like REQ and NEW.
# shellcheck disable=SC2016  # expanded where it runs
SWAP='set -eu
A="$HOME/Applications"; APP="$A/$APP_EXECUTABLE.app"; LOCK="$A/.$APP_EXECUTABLE.install.lock"
mkdir "$LOCK" 2>/dev/null || { echo "another install holds $LOCK; nothing replaced" >&2; rm -rf "$NEW"; exit 1; }
PREV=""
cleanup() { rc=$?; if [ $rc -ne 0 ] && [ -n "$PREV" ] && [ -d "$PREV" ]; then rm -rf "$APP"; mv "$PREV" "$APP" && echo "restored the previous bundle" >&2; fi; rm -rf "$NEW" "$LOCK"; exit $rc; }
trap cleanup EXIT
codesign --verify --strict "-R=$REQ" "$NEW/$APP_EXECUTABLE.app" || { echo "the copy here is not signed with the expected certificate; nothing replaced" >&2; exit 1; }
BIN="$APP/Contents/MacOS/$APP_EXECUTABLE"
running() { pgrep -f "^$BIN( |\$)" || true; }
if [ -n "$(running)" ]; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do [ -z "$(running)" ] && break; sleep 0.5; done
  [ -z "$(running)" ] || { echo "$APP_NAME is still open; quit it and run this again. Nothing replaced." >&2; exit 1; }
fi
# read after the quit: the app may have installed a staged update of its own as it quit
HAVE=$( [ -d "$APP" ] && defaults read "$APP/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo 0)
NEWB=$(defaults read "$NEW/$APP_EXECUTABLE.app/Contents/Info.plist" CFBundleVersion)
case "$HAVE" in *[!0-9]*|"") HAVE=0 ;; esac
if [ "$HAVE" -gt "$NEWB" ] && [ "${FORCE:-0}" != 1 ]; then echo "build $HAVE is installed, newer than $NEWB; nothing replaced (FORCE=1 to go back)" >&2; exit 1; fi
rm -rf "$A/.$APP_EXECUTABLE.app.previous"
if [ -e "$APP" ]; then PREV="$A/.$APP_EXECUTABLE.app.previous"; mv "$APP" "$PREV"; fi
mv "$NEW/$APP_EXECUTABLE.app" "$APP"
codesign --verify --strict "-R=$REQ" "$APP"
PREV=""   # done: the previous bundle stays beside it as .$APP_EXECUTABLE.app.previous
echo "installed: $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString) ($(defaults read "$APP/Contents/Info.plist" CFBundleVersion)) at $APP"'

echo "installing $APP_NAME $VERSION ($BUILD) on ${HOST:-this Mac}"
if [ -z "$HOST" ]; then
    mkdir -p "$HOME/Applications"
    NEW="$(mktemp -d "$HOME/Applications/.$APP_EXECUTABLE.incoming.XXXXXX")"
    ditto "$SRC" "$NEW/$APP_EXECUTABLE.app"
    REQ="$REQ" NEW="$NEW" FORCE="${FORCE:-0}" APP_NAME="$APP_NAME" APP_EXECUTABLE="$APP_EXECUTABLE" BUNDLE_ID="$BUNDLE_ID" bash -c "$SWAP"
else
    OS="$(ssh "$HOST" 'sw_vers -productVersion')"
    [ "${OS%%.*}" -ge 14 ] || { echo "$HOST runs macOS $OS; the app needs 14 or later. Nothing installed." >&2; exit 1; }
    NEW="$(ssh "$HOST" "mkdir -p ~/Applications && mktemp -d ~/Applications/.$APP_EXECUTABLE.incoming.XXXXXX")"
    [[ $NEW =~ ^/[A-Za-z0-9/._-]+$ ]] || { echo "unexpected staging folder on $HOST: $NEW" >&2; exit 1; }
    rsync -a "$SRC/" "$HOST:$NEW/$APP_EXECUTABLE.app/"
    ssh "$HOST" "REQ='$REQ' NEW='$NEW' FORCE='${FORCE:-0}' APP_NAME='$APP_NAME' APP_EXECUTABLE='$APP_EXECUTABLE' BUNDLE_ID='$BUNDLE_ID'; export REQ NEW FORCE APP_NAME APP_EXECUTABLE BUNDLE_ID; bash -c $(printf %q "$SWAP")"
fi
