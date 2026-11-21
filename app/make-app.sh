#!/usr/bin/env bash
# Assemble a self-contained hc-remote.app bundle from the SwiftPM build output.
# Usage: app/make-app.sh [output-dir]   (default output: <repo>/build)
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$script_dir")"
native_build="${HCR_NATIVE_BUILD:-$repo_root/build}"
out_dir="${1:-$repo_root/build}"
app_dir="$out_dir/hc-remote.app"

if [[ ! -f "$native_build/libhcr_native.dylib" ]]; then
  echo "libhcr_native.dylib not found in $native_build (set HCR_NATIVE_BUILD)" >&2
  exit 1
fi

datachannel_dylib="$native_build/_deps/libdatachannel-build/libdatachannel.0.dylib"
if [[ ! -f "$datachannel_dylib" ]]; then
  echo "libdatachannel.0.dylib not found at $datachannel_dylib" >&2
  exit 1
fi

echo "building HcrApp (release, universal)…"
HCR_NATIVE_BUILD="$native_build" swift build -c release --arch arm64 --arch x86_64 --package-path "$script_dir"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Frameworks" "$app_dir/Contents/Resources"
if [[ -f "$script_dir/Resources/AppIcon.icns" ]]; then
  cp "$script_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/"
fi
[[ -f "$repo_root/LICENSE" ]] && cp "$repo_root/LICENSE" "$app_dir/Contents/Resources/"
[[ -f "$repo_root/deploy/THIRD-PARTY-LICENSES.txt" ]] && cp "$repo_root/deploy/THIRD-PARTY-LICENSES.txt" "$app_dir/Contents/Resources/"

bin_path="$(HCR_NATIVE_BUILD="$native_build" swift build -c release --arch arm64 --arch x86_64 --package-path "$script_dir" --show-bin-path)"
cp "$bin_path/HcrApp" "$app_dir/Contents/MacOS/hc-remote"

frameworks="$app_dir/Contents/Frameworks"
cp "$native_build/libhcr_native.dylib" "$frameworks/"
cp "$datachannel_dylib" "$frameworks/"

chmod u+w "$frameworks"/*.dylib

install_name_tool -id @rpath/libhcr_native.dylib "$frameworks/libhcr_native.dylib"
install_name_tool \
  -change @rpath/libdatachannel.0.dylib @loader_path/libdatachannel.0.dylib \
  "$frameworks/libhcr_native.dylib"

install_name_tool -id @rpath/libdatachannel.0.dylib "$frameworks/libdatachannel.0.dylib"

install_name_tool -add_rpath @executable_path/../Frameworks "$app_dir/Contents/MacOS/hc-remote"

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>hc-remote</string>
  <key>CFBundleDisplayName</key>
  <string>hc-remote</string>
  <key>CFBundleIdentifier</key>
  <string>org.hcremote.mac</string>
  <key>CFBundleExecutable</key>
  <string>hc-remote</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

signing_identity="${HCR_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q '"hcr-dev"'; then
    signing_identity="hcr-dev"
  else
    signing_identity="-"
  fi
fi
codesign --force --deep -s "$signing_identity" "$app_dir"
echo "signed with: $signing_identity"

echo "assembled: $app_dir"
