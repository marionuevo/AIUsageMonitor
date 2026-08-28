#!/bin/bash
# Builds ClaudeUsage.app (universal, no Xcode project required).
set -euo pipefail

cd "$(dirname "$0")"

APP="build/ClaudeUsage.app"
MIN_OS="13.0"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
ARCHS=()
for arch in arm64 x86_64; do
  if swiftc -O -whole-module-optimization \
       -target "${arch}-apple-macos${MIN_OS}" \
       -o "build/ClaudeUsage-${arch}" Sources/main.swift 2>/dev/null; then
    ARCHS+=("build/ClaudeUsage-${arch}")
  else
    echo "  (skipping ${arch}: SDK slice unavailable)"
  fi
done

if [ ${#ARCHS[@]} -eq 0 ]; then
  echo "Build failed: no architecture compiled." >&2
  exit 1
fi

lipo -create -output "$APP/Contents/MacOS/ClaudeUsage" "${ARCHS[@]}"
rm -f "${ARCHS[@]}"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>ClaudeUsage</string>
    <key>CFBundleDisplayName</key>     <string>Claude Usage</string>
    <key>CFBundleExecutable</key>      <string>ClaudeUsage</string>
    <key>CFBundleIdentifier</key>      <string>local.claudeusage</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSSupportsAutomaticTermination</key> <false/>
    <key>NSSupportsSuddenTermination</key>    <false/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (ad-hoc signing skipped)"

echo "Built $APP"
