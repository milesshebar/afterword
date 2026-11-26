#!/usr/bin/env bash
# scripts/release-app.sh DEST: publish a signed app build for the app's optional self-updater.
#
# DEST is an rsync destination (host:folder) or a local folder: the archive folder's app-releases/ on the machine that runs
# `archivectl serve-web`, which serves it at /api/app/release and /api/app/release/<build>/archive. Point the app at that server
# with `defaults write <BUNDLE_ID> updateServer https://your-host/` (the updater is off until you do).
#
# SIGN_IDENTITY names a code-signing certificate in this Mac's keychain (a self-signed one works). Every installed copy refuses a
# build whose designated requirement differs from its own (identifier + certificate leaf), so always publish with the same one.
# Steps: build and sign with scripts/bundle.sh, check the requirement names the certificate leaf, stamp a version (1.<commits>)
# and a build number (UTC timestamp, so newer is larger), zip with ditto --keepParent, write <APP_EXECUTABLE>-<build>.zip and
# <APP_EXECUTABLE>-<build>.json, and last replace latest.json (renamed into place, so a client never sees a manifest before its zip).
# Keeps the five newest builds.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/product.env
DEST="${1:?usage: scripts/release-app.sh DEST (host:folder or a local folder)}"
IDENTITY="${SIGN_IDENTITY:?set SIGN_IDENTITY to the code-signing certificate builds are signed with}"
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" || { echo "no code-signing identity \"$IDENTITY\" in this Mac's keychain" >&2; exit 1; }
[ -z "$(git status --porcelain -- Sources Package.swift scripts/bundle.sh)" ] || echo "warning: uncommitted changes under Sources/ are in this build" >&2

BUILD="$(date -u +%Y%m%d%H%M%S)"
VERSION="1.$(git rev-list --count HEAD)"
COMMIT="$(git rev-parse --short HEAD)"
MA_VERSION="$VERSION" MA_BUILD="$BUILD" SIGN_IDENTITY="$IDENTITY" scripts/bundle.sh
APP=build/$APP_EXECUTABLE.app
REQ="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
[[ $REQ == *"certificate leaf"* ]] || { echo "not signed with a certificate ($REQ); refusing to publish" >&2; exit 1; }
codesign --verify --strict "-R=$REQ" "$APP"
[ "$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleVersion)" = "$BUILD" ] || { echo "build number not stamped" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ZIP="$APP_EXECUTABLE-$BUILD.zip"
ditto -c -k --keepParent "$APP" "$TMP/$ZIP"
SHA="$(shasum -a 256 "$TMP/$ZIP" | awk '{print $1}')"
SIZE="$(stat -f %z "$TMP/$ZIP")"
python3 - "$TMP/$APP_EXECUTABLE-$BUILD.json" "$VERSION" "$BUILD" "$SHA" "$SIZE" "$REQ" "$COMMIT" <<'PY'
import json, sys, datetime
out, version, build, sha, size, req, commit = sys.argv[1:]
json.dump({"version": version, "build": int(build), "sha256": sha, "size": int(size), "requirement": req,
           "published_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "commit": commit}, open(out, "w"))
PY
cp "$TMP/$APP_EXECUTABLE-$BUILD.json" "$TMP/.latest.json.tmp"

if [[ $DEST == *:* ]]; then
    HOST="${DEST%%:*}"; DIR="${DEST#*:}"; DIR="${DIR%/}"
    q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
    ssh "$HOST" "mkdir -p $(q "$DIR")"
    # -s: rsync passes the path itself (no remote shell word splitting)
    rsync -ts "$TMP/$ZIP" "$TMP/$APP_EXECUTABLE-$BUILD.json" "$TMP/.latest.json.tmp" "$HOST:$DIR/"
    ssh "$HOST" "cd $(q "$DIR") && [ \"\$(sha256sum $ZIP | cut -d' ' -f1)\" = $SHA ] && mv .latest.json.tmp latest.json && ls -1 | grep -E '^$APP_EXECUTABLE-[0-9]+\.zip\$' | sort -r | tail -n +6 | while read -r old; do rm -f \"\$old\" \"\${old%.zip}.json\"; done"
else
    mkdir -p "$DEST"
    cp "$TMP/$ZIP" "$TMP/$APP_EXECUTABLE-$BUILD.json" "$TMP/.latest.json.tmp" "$DEST/"
    mv "$DEST/.latest.json.tmp" "$DEST/latest.json"
fi
echo "published $APP_NAME $VERSION (build $BUILD, $SIZE bytes, sha256 $SHA, commit $COMMIT) to $DEST"
