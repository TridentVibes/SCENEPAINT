#!/bin/zsh
set -eu
ROOT="${0:A:h}"
SCENE_APP="$ROOT/Build/ScenePaint.app"
if [[ "${SCENEPAINT_RELEASE:-0}" == "1" ]]; then SCENE_APP="$ROOT/Build/Release/ScenePaint.app"; fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
export TMPDIR="$ROOT/Temporary/"
export CLANG_MODULE_CACHE_PATH="$ROOT/Cache/Clang"
export SWIFT_MODULECACHE_PATH="$ROOT/Cache/Swift"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULECACHE_PATH" "$SCENE_APP/Contents/MacOS"
"$(/usr/bin/xcrun --find swiftc)" \
  -sdk "$(/usr/bin/xcrun --show-sdk-path)" \
  -module-cache-path "$SWIFT_MODULECACHE_PATH" \
  -target arm64-apple-macosx14.0 -parse-as-library -O \
  -file-prefix-map "$ROOT=/ScenePaint" -debug-prefix-map "$ROOT=/ScenePaint" \
  "$ROOT"/Sources/*.swift -o "$SCENE_APP/Contents/MacOS/ScenePaint"
mkdir -p "$SCENE_APP/Contents/Resources"
if [[ -f "$ROOT/Branding/ScenePaint.icns" ]]; then cp "$ROOT/Branding/ScenePaint.icns" "$SCENE_APP/Contents/Resources/ScenePaint.icns"; fi
cat > "$SCENE_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ScenePaint</string>
<key>CFBundleIdentifier</key><string>local.scenepaint.prototype</string>
<key>CFBundleName</key><string>ScenePaint</string>
<key>CFBundleIconFile</key><string>ScenePaint</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>local.scenepaint.project</string>
<key>UTTypeDescription</key><string>ScenePaint Project</string>
<key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
<key>UTTypeTagSpecification</key><dict>
<key>public.filename-extension</key><array><string>scenepaint</string></array>
</dict></dict></array>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>ScenePaint Project</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>local.scenepaint.project</string></array>
<key>LSTypeIsPackage</key><true/>
</dict></array>
</dict></plist>
PLIST
if [[ ! -f "$SCENE_APP/Contents/Resources/ScenePaint.icns" ]]; then /usr/bin/plutil -remove CFBundleIconFile "$SCENE_APP/Contents/Info.plist"; fi
if [[ "${SCENEPAINT_RELEASE:-0}" == "1" ]]; then
 /usr/bin/plutil -insert ScenePaintRelease -bool YES "$SCENE_APP/Contents/Info.plist"
 /usr/bin/plutil -replace CFBundleIdentifier -string local.scenepaint.release "$SCENE_APP/Contents/Info.plist"
fi
cp "$ROOT/LICENSE" "$SCENE_APP/Contents/Resources/ScenePaint Code License.txt"
/usr/bin/xattr -cr "$SCENE_APP"
/usr/bin/codesign --force --sign - "$SCENE_APP"
printf '\nBuilt: %s\n' "$SCENE_APP"
