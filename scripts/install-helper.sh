#!/bin/bash
# Build coolmac-helper and install it as a root LaunchDaemon.
# macOS will prompt for your admin password (GUI dialog).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Building release helper..."
swift build -c release --product coolmac-helper
BIN="$PWD/.build/release/coolmac-helper"
PLIST="$PWD/LaunchDaemon/com.coolmac.helper.plist"

# Stage outside ~/Documents: a root process spawned by osascript has no
# TCC permission to read protected folders, even as root.
STAGE="$(mktemp -d /tmp/coolmac-install.XXXXXX)"
cp "$BIN" "$STAGE/coolmac-helper"
cp "$PLIST" "$STAGE/com.coolmac.helper.plist"

echo "Installing (admin password prompt will appear)..."
osascript -e "do shell script \"
  install -d -m 755 /Library/PrivilegedHelperTools && \
  install -m 755 -o root -g wheel '$STAGE/coolmac-helper' /Library/PrivilegedHelperTools/coolmac-helper && \
  install -m 644 -o root -g wheel '$STAGE/com.coolmac.helper.plist' /Library/LaunchDaemons/com.coolmac.helper.plist && \
  launchctl bootout system/com.coolmac.helper 2>/dev/null; \
  launchctl bootstrap system /Library/LaunchDaemons/com.coolmac.helper.plist && \
  launchctl kickstart -k system/com.coolmac.helper
\" with administrator privileges"
rm -rf "$STAGE"

sleep 1
if [ -S /var/run/coolmac.sock ]; then
  echo "OK: helper installed, socket at /var/run/coolmac.sock"
else
  echo "Helper installed but socket not found yet — check /var/log/coolmac-helper.log"
fi
