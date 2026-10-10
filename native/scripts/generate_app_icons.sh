#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
NATIVE_ROOT=${SCRIPT_DIR:h}
RESOURCE_DIR="$NATIVE_ROOT/Resources"
ICON_DOCUMENT="$RESOURCE_DIR/MacScope.icon"
ICON_DEVELOPER_DIR=${DEVELOPER_DIR:-$(/usr/bin/xcode-select --print-path)}
ICON_TOOL="$ICON_DEVELOPER_DIR/../Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ ! -x "$ICON_TOOL" ]]; then
    /usr/bin/printf 'Xcode 27 with Icon Composer is required to regenerate the icon.\n' >&2
    exit 69
fi
TEMP_DIR=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/macscope-icons.XXXXXX")

cleanup() {
  /bin/rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

/usr/bin/xcrun actool "$ICON_DOCUMENT" \
    --compile "$TEMP_DIR" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon MacScope \
    --output-partial-info-plist "$TEMP_DIR/IconInfo.plist" \
    --output-format human-readable-text
/usr/bin/ditto "$TEMP_DIR/Assets.car" "$RESOURCE_DIR/Assets.car"
/usr/bin/ditto "$TEMP_DIR/MacScope.icns" "$RESOURCE_DIR/MacScope.icns"
"$ICON_TOOL" "$ICON_DOCUMENT" --export-image \
    --output-file "$RESOURCE_DIR/MacScopeIcon.png" \
    --platform macOS --rendition Default \
    --width 1024 --height 1024 --scale 1 --design-generation 27

"$ICON_TOOL" "$ICON_DOCUMENT" --export-image \
    --output-file "$TEMP_DIR/Dark.png" \
    --platform macOS --rendition Dark \
    --width 1024 --height 1024 --scale 1 --design-generation 27
/usr/bin/swift "$SCRIPT_DIR/render_dock_icon.swift" \
    "$RESOURCE_DIR/MacScopeIcon.png" "$RESOURCE_DIR/MacScopeDockLight.png"
/usr/bin/swift "$SCRIPT_DIR/render_dock_icon.swift" \
    "$TEMP_DIR/Dark.png" "$RESOURCE_DIR/MacScopeDockDark.png"

/usr/bin/printf 'Generated MacScope app icon in %s\n' "$RESOURCE_DIR"
