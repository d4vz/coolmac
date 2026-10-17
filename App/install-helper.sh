#!/bin/bash
# Installs the coolmac-helper bundled inside CoolMac.app as a root
# LaunchDaemon. Run from inside the app bundle:
#   CoolMac.app/Contents/Resources/install-helper.sh
# macOS will prompt for your admin password (GUI dialog).
set -euo pipefail
RESOURCES="$(cd "$(dirname "$0")" && pwd)"

# Stage outside protected folders: a root process spawned by osascript
# has no TCC permission to read ~/Documents, ~/Downloads, etc.
STAGE="$(mktemp -d /tmp/coolmac-install.XXXXXX)"
cp "$RESOURCES/coolmac-helper" "$STAGE/coolmac-helper"
cp "$RESOURCES/com.coolmac.helper.plist" "$STAGE/com.coolmac.helper.plist"

osascript -e "do shell script \"
  install -d -m 755 /Library/PrivilegedHelperTools && \
  install -m 755 -o root -g wheel '$STAGE/coolmac-helper' /Library/PrivilegedHelperTools/coolmac-helper && \
  install -m 644 -o root -g wheel '$STAGE/com.coolmac.helper.plist' /Library/LaunchDaemons/com.coolmac.helper.plist && \
  launchctl bootout system/com.coolmac.helper 2>/dev/null; \
  launchctl bootstrap system /Library/LaunchDaemons/com.coolmac.helper.plist && \
  launchctl kickstart -k system/com.coolmac.helper
\" with administrator privileges"
rm -rf "$STAGE"
echo "OK: helper installed, socket at /var/run/coolmac.sock"
