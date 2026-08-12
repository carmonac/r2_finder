#!/bin/bash
# bundle.sh — assemble "R2 Finder.app" from a SwiftPM build.
#
# Bundle layout:
#
#   R2 Finder.app/
#   └── Contents/
#       ├── Info.plist
#       ├── MacOS/rs_2finder
#       └── Resources/{AppIcon.icns, r2_finder.png, 7zz, rsync}
#
# Usage:  Scripts/bundle.sh [version] [config]
#   version  App version for Info.plist, tag-style "v1.4.3" accepted
#            (leading 'v' is stripped). Default: 0.0.0-dev
#   config   SwiftPM build configuration to take the binary from
#            (release | debug). Default: release
#
# The binary must already exist:  swift build -c <config>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.0.0-dev}"
CONFIG="${2:-release}"

# Strip a leading 'v' from tag-style versions (e.g. "v1.4.0" -> "1.4.0")
VERSION="${VERSION#v}"

BINARY=".build/${CONFIG}/rs_2finder"
APP=".build/R2 Finder.app"

if [[ ! -x "$BINARY" ]]; then
    echo "error: $BINARY not found – run 'swift build -c ${CONFIG}' first" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1) Info.plist
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>R2 Finder</string>
  <key>CFBundleDisplayName</key>       <string>R2 Finder</string>
  <key>CFBundleIdentifier</key>        <string>com.example.r2finder</string>
  <key>CFBundleVersion</key>           <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleExecutable</key>        <string>rs_2finder</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleSignature</key>         <string>????</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSPrincipalClass</key>          <string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <!-- macOS 15+ gates every local-network access (mDNS browsing and the
       port-445 subnet scan) behind user consent. Without this key the
       system denies both silently and the RED section stays empty. -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>R2 Finder busca ordenadores y servidores de archivos en tu red local para mostrarlos en la barra lateral.</string>
  <!-- Bonjour service types the app is allowed to browse for. -->
  <key>NSBonjourServices</key>
  <array>
    <string>_smb._tcp</string>
    <string>_afpovertcp._tcp</string>
    <string>_device-info._tcp</string>
  </array>
</dict>
</plist>
PLIST

# 2) Executable
cp "$BINARY" "$APP/Contents/MacOS/rs_2finder"

# 3) Resources: icon, logo, bundled 7zz + rsync
cp AppIcon.icns  "$APP/Contents/Resources/AppIcon.icns"
cp r2_finder.png "$APP/Contents/Resources/r2_finder.png"
cp bin/7zz       "$APP/Contents/Resources/7zz"
cp bin/rsync     "$APP/Contents/Resources/rsync"
chmod 755 "$APP/Contents/Resources/7zz" "$APP/Contents/Resources/rsync"

# 4) Signature. SwiftPM leaves the binary ad-hoc "linker-signed", which does
#    not seal Info.plist — so the privacy usage strings above are ignored and
#    the local-network permission never sticks. Signing the bundle fixes both.
#    Set CODESIGN_IDENTITY to a Developer ID to get a stable identity across
#    builds (with ad-hoc "-" the app is a new app to TCC after every rebuild,
#    so macOS asks for local network access again).
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" \
         --identifier com.example.r2finder \
         "$APP"

echo "OK: $APP (version ${VERSION}, signed with '${IDENTITY}')"
