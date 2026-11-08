#!/usr/bin/env bash
# Copies UnilitixCore's Swift sources into ios/Classes/UnilitixCore so they
# compile inside this plugin's pod (no CocoaPods trunk or SPM-in-pods needed).
#
#   scripts/sync-ios-core.sh [path/to/UnilitixCore]   (default ../unilitix-ios/UnilitixCore)
#
# Since 3.0.0 the plugin is a thin wrapper over UnilitixCore's public facade
# (Unilitix.swift: start, track, screen, identify, setConsent, setWrapper,
# recordExternalError, addExternalSnapshot, captureExternalScreenshot,
# setExternalScreenCapture, currentSessionId, isReplaySampled, ...), so the
# facade is vendored too (needs UnilitixCore 0.8.0+). The plugin also uses
# ScreenshotCapture.captureWindow / render / encode to draw Dart-masked
# frames. Everything else (sessions, queue, uploads, crashes, app hangs) is
# the engine's.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="${1:-../unilitix-ios/UnilitixCore}/Sources/UnilitixCore"
DEST=ios/Classes/UnilitixCore
[ -d "$SRC" ] || { echo "UnilitixCore sources not found at $SRC" >&2; exit 1; }
VERSION=$(sed -n 's/.*public static let current = "\(.*\)".*/\1/p' "$SRC/Transport.swift")
rm -rf "$DEST"
mkdir -p "$DEST/Generated"
for f in "$SRC"/*.swift "$SRC"/Generated/*.swift; do
  rel=${f#"$SRC"/}
  { echo "// VENDORED from UnilitixCore $VERSION ($rel) by scripts/sync-ios-core.sh."
    echo "// Do not edit here; change UnilitixCore and re-run the script."
    echo
    cat "$f"; } > "$DEST/$rel"
done
case "$VERSION" in
  0.[0-7].*) echo "warning: UnilitixCore $VERSION predates 0.8.0; the plugin needs 0.8.0's facade API" >&2 ;;
esac
echo "Synced UnilitixCore $VERSION into $DEST"
