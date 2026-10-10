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
DEPLOYMENT_TARGET=13.0

if [[ -n "${MACSCOPE_SDK_PATH:-}" ]]; then
    SDK_PATH="$MACSCOPE_SDK_PATH"
elif [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
else
    SDK_PATH=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
fi

SDK_VERSION=$(/usr/bin/plutil -extract Version raw "$SDK_PATH/SDKSettings.plist")
BUILD_ARGUMENTS=(
    --package-path "$NATIVE_ROOT"
    --configuration "$CONFIGURATION"
    --sdk "$SDK_PATH"
    -Xlinker -platform_version
    -Xlinker macos
    -Xlinker "$DEPLOYMENT_TARGET"
    -Xlinker "$SDK_VERSION"
)

swift build "${BUILD_ARGUMENTS[@]}" >&2
BIN_DIR=$(swift build "${BUILD_ARGUMENTS[@]}" --show-bin-path)

for executable in MacScopeNative MacScopeFanControlHelper; do
    RECORDED_SDK=$(/usr/bin/vtool -show-build "$BIN_DIR/$executable" | /usr/bin/awk '$1 == "sdk" { print $2; exit }')
    if [[ "$RECORDED_SDK" != "$SDK_VERSION" ]]; then
        /usr/bin/printf '%s records SDK %s; expected %s\n' "$executable" "$RECORDED_SDK" "$SDK_VERSION" >&2
        exit 65
    fi
done

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
/usr/bin/ditto "$NATIVE_ROOT/Resources/Assets.car" "$RESOURCES_DIR/Assets.car"
/usr/bin/ditto "$NATIVE_ROOT/Resources/MacScopeDockLight.png" "$RESOURCES_DIR/MacScopeDockLight.png"
/usr/bin/ditto "$NATIVE_ROOT/Resources/MacScopeDockDark.png" "$RESOURCES_DIR/MacScopeDockDark.png"
/usr/bin/ditto "$NATIVE_ROOT/Resources/GitHubMark.svg" "$RESOURCES_DIR/GitHubMark.svg"
for localization in "$NATIVE_ROOT"/Resources/*.lproj; do
    [[ -d "$localization" ]] || continue
    /usr/bin/ditto "$localization" "$RESOURCES_DIR/${localization:t}"
done

/usr/bin/codesign --force --sign - "$HELPERS_DIR/MacScopeFanControlHelper" >&2
/usr/bin/codesign --force --deep --sign - "$APP_DIR" >&2
/usr/bin/printf '%s\n' "$APP_DIR"
