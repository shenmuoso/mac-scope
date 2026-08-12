#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
NATIVE_ROOT=${SCRIPT_DIR:h}
CONFIGURATION=${1:-debug}
APP_DIR="$NATIVE_ROOT/build/MacScope.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
HELPERS_DIR="$CONTENTS_DIR/Library/Helpers"

swift build --package-path "$NATIVE_ROOT" --configuration "$CONFIGURATION" >&2
BIN_DIR=$(swift build --package-path "$NATIVE_ROOT" --configuration "$CONFIGURATION" --show-bin-path)

/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPERS_DIR"
/usr/bin/ditto "$BIN_DIR/MacScopeNative" "$MACOS_DIR/MacScopeNative"
/usr/bin/ditto "$BIN_DIR/MacScopeFanControlHelper" "$HELPERS_DIR/MacScopeFanControlHelper"
/bin/chmod 0755 "$HELPERS_DIR/MacScopeFanControlHelper"
/usr/bin/ditto "$NATIVE_ROOT/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -n "${MACSCOPE_VERSION:-}" ]]; then
    /usr/bin/plutil -replace CFBundleShortVersionString -string "$MACSCOPE_VERSION" "$CONTENTS_DIR/Info.plist"
fi
if [[ -n "${MACSCOPE_BUILD:-}" ]]; then
    /usr/bin/plutil -replace CFBundleVersion -string "$MACSCOPE_BUILD" "$CONTENTS_DIR/Info.plist"
fi
/usr/bin/ditto "$NATIVE_ROOT/Resources/MacScope.icns" "$RESOURCES_DIR/MacScope.icns"
/usr/bin/ditto "$NATIVE_ROOT/Resources/MacScopeDetailed.icns" "$RESOURCES_DIR/MacScopeDetailed.icns"
/usr/bin/ditto "$NATIVE_ROOT/Resources/GitHubMark.svg" "$RESOURCES_DIR/GitHubMark.svg"
for localization in "$NATIVE_ROOT"/Resources/*.lproj; do
    [[ -d "$localization" ]] || continue
    /usr/bin/ditto "$localization" "$RESOURCES_DIR/${localization:t}"
done

/usr/bin/codesign --force --sign - "$HELPERS_DIR/MacScopeFanControlHelper" >&2
/usr/bin/codesign --force --deep --sign - "$APP_DIR" >&2
/usr/bin/printf '%s\n' "$APP_DIR"
