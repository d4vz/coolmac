#!/bin/bash
# Revert fans to system Auto, then remove the coolmac root helper.
set -euo pipefail

# Best effort: hand fans back to macOS before the helper goes away.
python3 - <<'PY' || true
import socket
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect("/var/run/coolmac.sock")
    s.sendall(b"AUTO\n")
    print("Fans reverted to Auto:", s.recv(256).decode().strip())
    s.close()
except Exception as e:
    print(f"(could not send AUTO: {e})")
PY

echo "Removing helper (admin password prompt will appear)..."
osascript -e "do shell script \"
  launchctl bootout system/com.coolmac.helper 2>/dev/null; \
  rm -f /Library/LaunchDaemons/com.coolmac.helper.plist \
        /Library/PrivilegedHelperTools/coolmac-helper \
        /var/run/coolmac.sock
\" with administrator privileges"
echo "OK: helper removed."
