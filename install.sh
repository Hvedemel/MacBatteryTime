#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# Installs to the current user's Applications folder, without administrator access.
# Move or copy the delivered .app manually if you prefer /Applications.
DESTINATION="${BATTERYTIME_INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$DESTINATION"
exec "$ROOT/build.sh" --output "$DESTINATION/BatteryTime.app" "$@"
