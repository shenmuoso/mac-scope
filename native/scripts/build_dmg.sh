#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
NATIVE_ROOT=${SCRIPT_DIR:h}
CONFIGURATION=${1:-release}
OUTPUT_PATH=${2:-"$NATIVE_ROOT/build/MacScope-0.4.11.dmg"}
STAGING_DIR="$NATIVE_ROOT/build/dmg-root"

case "$CONFIGURATION" in
    debug|release) ;;
    *)
        /usr/bin/printf 'Unsupported configuration: %s\n' "$CONFIGURATION" >&2
        /usr/bin/printf 'Usage: %s [debug|release] [output.dmg]\n' "$0" >&2
        exit 64
        ;;
esac

APP_PATH=$("$SCRIPT_DIR/build_app.sh" "$CONFIGURATION")

/bin/rm -rf "$STAGING_DIR"
/bin/mkdir -p "$STAGING_DIR" "${OUTPUT_PATH:h}"
/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/MacScope.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"

/bin/rm -f "$OUTPUT_PATH"
/usr/bin/hdiutil create \
    -volname "MacScope" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$OUTPUT_PATH"

/bin/rm -rf "$STAGING_DIR"
/usr/bin/printf '%s\n' "$OUTPUT_PATH"
