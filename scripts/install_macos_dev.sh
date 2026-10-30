#!/usr/bin/env bash
# Per-user development installer for XUNA Desktop Agent on macOS (UDC-3 §5.6.4, §5.6.6).
#
# Invariants:
# - Never runs as root (EUID 0) and never installs a root LaunchDaemon.
# - Copies the app bundle to ~/Applications/XUNA.app.
# - Ensures ~/Library/Application Support/XUNA/host-policy.json has mode 0600.
# - Registers ~/Library/LaunchAgents/ai.xuna.desktop.agent.plist for start at login.

set -euo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "Error: XUNA Desktop Agent must be installed as a standard user, never as root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_APP="${1:-${SCRIPT_DIR}/../build/macos/Build/Products/Release/xuna_desktop.app}"
INSTALL_DIR="${HOME}/Applications"
TARGET_APP="${INSTALL_DIR}/XUNA.app"
SUPPORT_DIR="${HOME}/Library/Application Support/XUNA"
POLICY_FILE="${SUPPORT_DIR}/host-policy.json"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
PLIST_FILE="${LAUNCH_AGENTS_DIR}/ai.xuna.desktop.agent.plist"

if [[ ! -d "${BUILD_APP}" ]]; then
  echo "Error: macOS Release bundle not found at ${BUILD_APP}. Run 'fvm flutter build macos --release' first." >&2
  exit 1
fi

mkdir -p "${INSTALL_DIR}"
rm -rf "${TARGET_APP}"
cp -R "${BUILD_APP}" "${TARGET_APP}"

mkdir -p "${SUPPORT_DIR}"
chmod 700 "${SUPPORT_DIR}"

if [[ ! -f "${POLICY_FILE}" ]]; then
  cat > "${POLICY_FILE}" <<'EOF'
{
  "schemaVersion": 1,
  "families": {
    "media": "allow",
    "app": "allow",
    "url": "allow",
    "workflow": "allow"
  },
  "apps": [],
  "urlDomains": [
    "github.com"
  ],
  "workflows": [],
  "players": [
    "spotify",
    "music"
  ]
}
EOF
fi

chmod 600 "${POLICY_FILE}"

mkdir -p "${LAUNCH_AGENTS_DIR}"
cat > "${PLIST_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>ai.xuna.desktop.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>${TARGET_APP}/Contents/MacOS/xuna_desktop</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
EOF

chmod 644 "${PLIST_FILE}"
echo "Installed XUNA Desktop Agent to ${TARGET_APP} with mode 0600 on ${POLICY_FILE}."

