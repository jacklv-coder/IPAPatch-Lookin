#!/bin/sh

set -eu

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "usage: $0 /path/to/Patched.app" >&2
    exit 64
fi

INFO_PLIST="$APP_PATH/Info.plist"
if [ ! -f "$INFO_PLIST" ]; then
    echo "error: missing Info.plist in $APP_PATH" >&2
    exit 1
fi

APP_BINARY_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$INFO_PLIST")
APP_BINARY="$APP_PATH/$APP_BINARY_NAME"
PATCH_BINARY="$APP_PATH/Dylibs/IPAPatchFramework"

if [ ! -f "$APP_BINARY" ]; then
    echo "error: missing main executable: $APP_BINARY" >&2
    exit 1
fi

if [ ! -f "$PATCH_BINARY" ]; then
    echo "error: missing injected library: $PATCH_BINARY" >&2
    exit 1
fi

if ! otool -L "$APP_BINARY" | grep -q "@executable_path/Dylibs/IPAPatchFramework"; then
    echo "error: main executable does not load IPAPatchFramework" >&2
    exit 1
fi

if ! strings "$PATCH_BINARY" | grep -q "LookinServer - Will launch"; then
    echo "error: LookinServer was not linked into IPAPatchFramework" >&2
    exit 1
fi

REMAINING_APP_EXTENSION=$(find "$APP_PATH" -type d -name "*.appex" -print -quit)
if [ -n "$REMAINING_APP_EXTENSION" ]; then
    echo "error: Embedded app extension was not removed: $REMAINING_APP_EXTENSION" >&2
    exit 1
fi

if [ -e "$APP_PATH/SC_Info" ]; then
    echo "error: App Store SC_Info metadata was not removed" >&2
    exit 1
fi

echo "Verified patched app:"
echo "  app: $APP_PATH"
echo "  executable: $APP_BINARY_NAME"
echo "  injection: @executable_path/Dylibs/IPAPatchFramework"
echo "  LookinServer: linked"
echo "  app extensions: removed"
echo "  App Store SC_Info: removed"

if codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
    echo "  signature: valid"
else
    echo "  signature: absent or invalid (expected for CODE_SIGNING_ALLOWED=NO builds)"
fi
