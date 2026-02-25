#!/bin/bash
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────
SCHEME="anubis-oss"
REPO_ROOT="$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)"
PROJECT_DIR="$REPO_ROOT/anubis"
ARCHIVE_PATH="/tmp/anubis-release/anubis-oss.xcarchive"
EXPORT_DIR="/tmp/anubis-release/export"
APP_NAME="anubis.app"
ZIP_NAME="anubis-oss.zip"
SIGNING_IDENTITY="${ANUBIS_SIGNING_IDENTITY:?Set ANUBIS_SIGNING_IDENTITY env var (e.g. 'Developer ID Application: Name (TEAMID)')}"
TEAM_ID="${ANUBIS_TEAM_ID:?Set ANUBIS_TEAM_ID env var (e.g. 'J7NK5LQP48')}"
KEYCHAIN_PROFILE="${ANUBIS_KEYCHAIN_PROFILE:-notarytool}"

# ─── Parse args ──────────────────────────────────────────────────
VERSION=""
SKIP_NOTARIZE=false
SKIP_GITHUB=false

usage() {
    echo "Usage: $0 --version <tag> [--skip-notarize] [--skip-github]"
    echo ""
    echo "  --version        Release tag — sets the app version automatically."
    echo "                   Accepts: v2.3.0, v2.3, 2.3.0, or 2.3"
    echo "                   The 'v' prefix and patch '.0' are stripped for the"
    echo "                   Xcode version (e.g. v2.3.0 → 2.3). Both"
    echo "                   MARKETING_VERSION and CURRENT_PROJECT_VERSION are"
    echo "                   updated in the pbxproj before archiving."
    echo "  --skip-notarize  Skip notarization (for testing)"
    echo "  --skip-github    Build and sign only, don't create GitHub release"
    echo ""
    echo "Examples:"
    echo "  $0 --version v2.3.0"
    echo "  $0 --version v2.3.0 --skip-github"
    echo "  $0 --version 2.3 --skip-notarize --skip-github"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --skip-notarize) SKIP_NOTARIZE=true; shift ;;
        --skip-github) SKIP_GITHUB=true; shift ;;
        *) usage ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    usage
fi

echo "══════════════════════════════════════════════════════════"
echo "  Anubis OSS Release Pipeline — $VERSION"
echo "══════════════════════════════════════════════════════════"
echo ""

# ─── Step 1: Stamp version into pbxproj ─────────────────────────
# Strip 'v' prefix and trailing '.0' patch: v2.3.0 → 2.3, v2.3 → 2.3
XCODE_VERSION="${VERSION#v}"            # remove leading 'v'
XCODE_VERSION="${XCODE_VERSION%.0}"     # remove trailing '.0' if present

PBXPROJ="$PROJECT_DIR/anubis.xcodeproj/project.pbxproj"
echo "→ Setting version to $XCODE_VERSION in pbxproj..."

# Update both MARKETING_VERSION and CURRENT_PROJECT_VERSION for the anubis target
# (lines with values like 2.1 or 2.2 — only in target build configs, not test targets which use 1)
sed -i '' -E "s/(MARKETING_VERSION = )[0-9]+\.[0-9]+;/\1${XCODE_VERSION};/g" "$PBXPROJ"
sed -i '' -E "s/(CURRENT_PROJECT_VERSION = )[0-9]+\.[0-9]+;/\1${XCODE_VERSION};/g" "$PBXPROJ"

# Verify
FOUND_MV=$(grep -c "MARKETING_VERSION = ${XCODE_VERSION};" "$PBXPROJ")
FOUND_CPV=$(grep -c "CURRENT_PROJECT_VERSION = ${XCODE_VERSION};" "$PBXPROJ")
echo "  MARKETING_VERSION = $XCODE_VERSION  (${FOUND_MV} occurrences)"
echo "  CURRENT_PROJECT_VERSION = $XCODE_VERSION  (${FOUND_CPV} occurrences)"

if [[ "$FOUND_MV" -lt 2 || "$FOUND_CPV" -lt 2 ]]; then
    echo "  ⚠ Expected at least 2 occurrences each (Debug + Release). Check pbxproj."
    exit 1
fi

# ─── Step 2: Clean build directory ──────────────────────────────
echo "→ Cleaning build directory..."
rm -rf /tmp/anubis-release
mkdir -p /tmp/anubis-release

# ─── Step 3: Archive ─────────────────────────────────────────────
echo "→ Archiving $SCHEME (Release)..."
xcodebuild archive \
    -project "$PROJECT_DIR/anubis.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -quiet \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual 2>&1 | grep -v "^warning:"

echo "  Archive created at $ARCHIVE_PATH"

# ─── Step 4: Export ──────────────────────────────────────────────
echo "→ Creating export options plist..."
EXPORT_PLIST="/tmp/anubis-release/exportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
PLIST

echo "→ Exporting archive..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    -exportPath "$EXPORT_DIR" \
    -quiet 2>&1 | grep -v "^warning:"

echo "  Exported to $EXPORT_DIR"

# Verify the app exists
if [[ ! -d "$EXPORT_DIR/$APP_NAME" ]]; then
    echo "ERROR: $APP_NAME not found in export directory"
    ls -la "$EXPORT_DIR"
    exit 1
fi

# ─── Step 5: Fix Sparkle framework for Gatekeeper ───────────────
# Sparkle's SPM binary has non-standard symlinks in the framework root
# (Autoupdate, Updater.app, XPCServices) that cause spctl to reject the
# app with "unsealed contents present in the root directory of an embedded
# framework".  Remove them and re-sign before notarization.
SPARKLE_FW="$EXPORT_DIR/$APP_NAME/Contents/Frameworks/Sparkle.framework"
ENTITLEMENTS="$PROJECT_DIR/anubis/anubis.entitlements"

if [[ -d "$SPARKLE_FW" ]]; then
    echo "→ Cleaning Sparkle.framework for Gatekeeper compliance..."
    rm -f "$SPARKLE_FW/Autoupdate" "$SPARKLE_FW/Updater.app" "$SPARKLE_FW/XPCServices"

    echo "  Re-signing Sparkle internals..."
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$SPARKLE_FW/Versions/B/Autoupdate"
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$SPARKLE_FW/Versions/B/Updater.app"
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime "$SPARKLE_FW"

    echo "  Re-signing app..."
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" "$EXPORT_DIR/$APP_NAME"
    echo "  Done"
fi

# ─── Step 6: Verify code signature ──────────────────────────────
echo "→ Verifying code signature..."
codesign --verify --deep --strict "$EXPORT_DIR/$APP_NAME"
echo "  Signature valid"

codesign -dv "$EXPORT_DIR/$APP_NAME" 2>&1 | grep -E "Authority|TeamIdentifier"

# ─── Step 7: Create zip for notarization ─────────────────────────
echo "→ Creating zip..."
cd "$EXPORT_DIR"
# Strip AppleDouble ._ resource fork files — they become "unsealed contents"
# inside frameworks when the zip is extracted, causing Gatekeeper rejection.
find "$APP_NAME" -name '._*' -delete 2>/dev/null || true
dot_clean "$APP_NAME" 2>/dev/null || true
/usr/bin/ditto -c -k --norsrc --keepParent "$APP_NAME" "$ZIP_NAME"
ZIP_PATH="$EXPORT_DIR/$ZIP_NAME"
echo "  Created $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"

# ─── Step 8: Notarize ───────────────────────────────────────────
if [[ "$SKIP_NOTARIZE" == true ]]; then
    echo "→ Skipping notarization (--skip-notarize)"
else
    echo "→ Submitting for notarization..."
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$KEYCHAIN_PROFILE" \
        --wait

    echo "→ Stapling notarization ticket..."
    xcrun stapler staple "$EXPORT_DIR/$APP_NAME"

    echo "→ Re-creating zip with stapled ticket..."
    rm "$ZIP_PATH"
    find "$APP_NAME" -name '._*' -delete 2>/dev/null || true
    dot_clean "$APP_NAME" 2>/dev/null || true
    /usr/bin/ditto -c -k --norsrc --keepParent "$APP_NAME" "$ZIP_NAME"
    echo "  Final zip: $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"
fi

# ─── Step 9: Final verification ─────────────────────────────────
echo "→ Final Gatekeeper check..."
spctl --assess --type execute --verbose "$EXPORT_DIR/$APP_NAME" 2>&1
echo "→ Verifying zip round-trip..."
VERIFY_DIR=$(mktemp -d)
/usr/bin/ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
spctl --assess --type execute --verbose "$VERIFY_DIR/$APP_NAME" 2>&1
rm -rf "$VERIFY_DIR"
echo "  Zip round-trip passed"

# ─── Step 10: Sparkle EdDSA signing & appcast ───────────────────
echo ""
echo "→ Sparkle: signing zip and generating appcast..."

# Locate Sparkle command-line tools (prebuilt binaries in SPM artifacts)
SPARKLE_BIN="${SPARKLE_BIN:-}"
if [[ -z "$SPARKLE_BIN" ]]; then
    SPARKLE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
        -path '*/artifacts/sparkle/Sparkle/bin/sign_update' -type f 2>/dev/null | head -1 | xargs dirname 2>/dev/null || true)"
fi

if [[ -z "$SPARKLE_BIN" || ! -x "$SPARKLE_BIN/sign_update" ]]; then
    echo "  ⚠ Sparkle bin tools not found."
    echo "    Set SPARKLE_BIN=/path/to/sparkle/bin or build the project first so DerivedData is populated."
    echo "    Skipping Sparkle signing — you can run this manually later:"
    echo "      sign_update \"$ZIP_PATH\""
    echo "      generate_appcast /tmp/anubis-release/export --download-url-prefix https://github.com/uncSoft/anubis-oss/releases/download/$VERSION/"
else
    echo "  Using Sparkle tools at: $SPARKLE_BIN"

    # Sign the zip — prints the EdDSA signature attributes for the appcast
    EDDSA_SIG=$("$SPARKLE_BIN/sign_update" "$ZIP_PATH")
    echo "  EdDSA signature: $EDDSA_SIG"

    # Generate appcast.xml from the export directory
    "$SPARKLE_BIN/generate_appcast" \
        --download-url-prefix "https://github.com/uncSoft/anubis-oss/releases/download/$VERSION/" \
        "$EXPORT_DIR"

    APPCAST_PATH="$EXPORT_DIR/appcast.xml"
    if [[ -f "$APPCAST_PATH" ]]; then
        echo "  Appcast generated: $APPCAST_PATH"
        echo ""
        echo "  ╔══════════════════════════════════════════════════════════╗"
        echo "  ║  REMINDER: Upload appcast.xml to devpadapp.com/anubis/  ║"
        echo "  ║  scp $APPCAST_PATH server:anubis/appcast.xml            ║"
        echo "  ╚══════════════════════════════════════════════════════════╝"
    else
        echo "  ⚠ generate_appcast did not produce appcast.xml"
    fi
fi

# ─── Step 11: GitHub Release ─────────────────────────────────────
if [[ "$SKIP_GITHUB" == true ]]; then
    echo ""
    echo "→ Skipping GitHub release (--skip-github)"
    echo "  Ready to upload: $ZIP_PATH"
else
    echo ""
    echo "→ Creating GitHub release $VERSION..."

    cd "$REPO_ROOT"

    NOTES=$(cat <<'EOF'
## Anubis OSS $TAG

### What's New in 2.1
- **Community Leaderboard** — Upload benchmark results and compare your Mac against other Apple Silicon machines at [devpadapp.com/leaderboard.html](https://devpadapp.com/leaderboard.html)
- One-click upload from the benchmark toolbar after a completed run
- Filter leaderboard by chip or model, with expandable detail rows for full run data
- Privacy-first: no accounts, no response text — just metrics and a display name

### Download
Download `anubis-oss.zip`, unzip, and drag to Applications. The app is signed and notarized.

### Requirements
- macOS 15.0+ (Sequoia)
- Apple Silicon (M1/M2/M3/M4/M5+)
- At least one inference backend (Ollama recommended)
EOF
)
    # Substitute the tag into the notes
    NOTES="${NOTES//\$TAG/$VERSION}"

    gh release create "$VERSION" \
        "$ZIP_PATH" \
        --title "Anubis OSS $VERSION" \
        --notes "$NOTES"

    echo ""
    echo "  Release created: https://github.com/uncSoft/anubis-oss/releases/tag/$VERSION"
fi

echo ""
echo "══════════════════════════════════════════════════════════"
echo "  Done!"
echo "══════════════════════════════════════════════════════════"
