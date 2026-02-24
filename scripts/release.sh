#!/bin/bash
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────
SCHEME="anubis-oss"
PROJECT_DIR="$(cd "$(dirname "$0")/../anubis" && pwd)"
ARCHIVE_PATH="/tmp/anubis-release/anubis-oss.xcarchive"
EXPORT_DIR="/tmp/anubis-release/export"
APP_NAME="anubis.app"
ZIP_NAME="anubis-oss.zip"
SIGNING_IDENTITY="Developer ID Application: John Taverna (J7NK5LQP48)"
TEAM_ID="J7NK5LQP48"
KEYCHAIN_PROFILE="notarytool"

# ─── Parse args ──────────────────────────────────────────────────
VERSION=""
SKIP_NOTARIZE=false
SKIP_GITHUB=false

usage() {
    echo "Usage: $0 --version <tag> [--skip-notarize] [--skip-github]"
    echo ""
    echo "  --version      Release tag (e.g. v2.1.0)"
    echo "  --skip-notarize  Skip notarization (for testing)"
    echo "  --skip-github    Build and sign only, don't create GitHub release"
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

# ─── Step 1: Clean build directory ───────────────────────────────
echo "→ Cleaning build directory..."
rm -rf /tmp/anubis-release
mkdir -p /tmp/anubis-release

# ─── Step 2: Archive ─────────────────────────────────────────────
echo "→ Archiving $SCHEME (Release)..."
xcodebuild archive \
    -project "$PROJECT_DIR/anubis.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -quiet \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual

echo "  Archive created at $ARCHIVE_PATH"

# ─── Step 3: Export ──────────────────────────────────────────────
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
    -quiet

echo "  Exported to $EXPORT_DIR"

# Verify the app exists
if [[ ! -d "$EXPORT_DIR/$APP_NAME" ]]; then
    echo "ERROR: $APP_NAME not found in export directory"
    ls -la "$EXPORT_DIR"
    exit 1
fi

# ─── Step 4: Verify code signature ──────────────────────────────
echo "→ Verifying code signature..."
codesign --verify --deep --strict "$EXPORT_DIR/$APP_NAME"
echo "  Signature valid"

codesign -dv "$EXPORT_DIR/$APP_NAME" 2>&1 | grep -E "Authority|TeamIdentifier"

# ─── Step 5: Create zip for notarization ─────────────────────────
echo "→ Creating zip..."
cd "$EXPORT_DIR"
/usr/bin/ditto -c -k --keepParent "$APP_NAME" "$ZIP_NAME"
ZIP_PATH="$EXPORT_DIR/$ZIP_NAME"
echo "  Created $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"

# ─── Step 6: Notarize ───────────────────────────────────────────
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
    /usr/bin/ditto -c -k --keepParent "$APP_NAME" "$ZIP_NAME"
    echo "  Final zip: $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"
fi

# ─── Step 7: Final verification ─────────────────────────────────
echo "→ Final Gatekeeper check..."
spctl --assess --type execute --verbose "$EXPORT_DIR/$APP_NAME" 2>&1 || true

# ─── Step 8: Sparkle EdDSA signing & appcast ────────────────────
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

# ─── Step 9: GitHub Release ──────────────────────────────────────
if [[ "$SKIP_GITHUB" == true ]]; then
    echo ""
    echo "→ Skipping GitHub release (--skip-github)"
    echo "  Ready to upload: $ZIP_PATH"
else
    echo ""
    echo "→ Creating GitHub release $VERSION..."

    cd "$(cd "$(dirname "$0")" && git rev-parse --show-toplevel)"

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
