#!/usr/bin/env bash
#
# bump-cask.sh — bump the Homebrew Cask formula for a new Anubis OSS
# release.
#
# Typical use after a new GitHub release is live (the asset must be
# uploaded so we can fetch + hash it):
#
#   scripts/bump-cask.sh 3.7                  # in-place edit local cask file
#   scripts/bump-cask.sh 3.7 --tap ../homebrew-anubis   # edit + commit + push in the tap repo
#   scripts/bump-cask.sh 3.7 --tap ../homebrew-anubis --pr   # …and open a PR
#
# What it does:
#   1. Verifies the release asset is reachable.
#   2. Computes the SHA256 of the downloaded zip.
#   3. Rewrites `version` and `sha256` in the cask file.
#   4. Optionally commits + pushes + opens a PR via gh.
#
# Designed to be idempotent — re-running with the same version is
# safe (it'll just write the same values).
#
# Requires: bash, curl, shasum, sed; optionally git + gh for the
# --tap / --pr flags.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "usage: bump-cask.sh <version> [--tap <path>] [--pr] [--cask <path>]" >&2
    echo "  <version>      Marketing version, e.g. 3.7 (no leading 'v')" >&2
    echo "  --tap <path>   Path to a checked-out homebrew-anubis tap repo." >&2
    echo "                 When set, edits Casks/anubis-oss.rb in that repo," >&2
    echo "                 commits, and pushes." >&2
    echo "  --pr           After committing, open a pull request via gh." >&2
    echo "                 Implies --tap; needs a non-default branch." >&2
    echo "  --cask <path>  Explicit path to the cask file. Defaults to" >&2
    echo "                 homebrew/anubis-oss.rb (when no --tap) or" >&2
    echo "                 <tap>/Casks/anubis-oss.rb (with --tap)." >&2
    exit 1
fi

VERSION="$1"
shift || true
TAP_PATH=""
CASK_PATH=""
OPEN_PR=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tap)
            TAP_PATH="$2"
            shift 2
            ;;
        --pr)
            OPEN_PR=1
            shift
            ;;
        --cask)
            CASK_PATH="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# Resolve the cask file path
if [[ -z "$CASK_PATH" ]]; then
    if [[ -n "$TAP_PATH" ]]; then
        CASK_PATH="$TAP_PATH/Casks/anubis-oss.rb"
    else
        # Default to the in-repo draft
        CASK_PATH="$(cd "$(dirname "$0")/.." && pwd)/homebrew/anubis-oss.rb"
    fi
fi

if [[ ! -f "$CASK_PATH" ]]; then
    echo "Cask file not found: $CASK_PATH" >&2
    exit 1
fi

# --- Fetch + hash the release asset --------------------------------

ASSET_URL="https://github.com/uncSoft/anubis-oss/releases/download/v${VERSION}.0/Anubis-OSS-${VERSION}.zip"
echo "==> Fetching ${ASSET_URL}"

# HEAD-check first so we fail fast with a clean error if the asset
# isn't uploaded yet (common race: tag exists but the zip is still
# being attached).
if ! curl -sIfL "$ASSET_URL" > /dev/null; then
    echo "Release asset not reachable. Has the v${VERSION}.0 release been published" >&2
    echo "with Anubis-OSS-${VERSION}.zip attached?" >&2
    exit 1
fi

SHA256=$(curl -sL "$ASSET_URL" | shasum -a 256 | awk '{print $1}')
if [[ -z "$SHA256" ]]; then
    echo "Failed to compute SHA256." >&2
    exit 1
fi
echo "==> SHA256: $SHA256"

# --- Rewrite the cask file -----------------------------------------

# Backup so a mistake doesn't lose the previous values
cp "$CASK_PATH" "$CASK_PATH.bak"

# Use a sed pattern that's strict about the line shape so we never
# accidentally overwrite something elsewhere in the cask file.
sed -i.tmp \
    -e "s|^  version \"[^\"]*\"|  version \"${VERSION}\"|" \
    -e "s|^  sha256 \"[a-f0-9]*\"|  sha256 \"${SHA256}\"|" \
    "$CASK_PATH"
rm -f "$CASK_PATH.tmp"

# Sanity-check the edit landed
if ! grep -q "version \"${VERSION}\"" "$CASK_PATH"; then
    echo "Version line did not update. Restoring backup." >&2
    mv "$CASK_PATH.bak" "$CASK_PATH"
    exit 1
fi
if ! grep -q "sha256 \"${SHA256}\"" "$CASK_PATH"; then
    echo "Sha256 line did not update. Restoring backup." >&2
    mv "$CASK_PATH.bak" "$CASK_PATH"
    exit 1
fi
rm -f "$CASK_PATH.bak"

echo "==> Updated $CASK_PATH"

# --- Local-mode (no tap): just stop here ---------------------------

if [[ -z "$TAP_PATH" ]]; then
    echo ""
    echo "Done (local edit). To ship, copy this file into your homebrew-anubis"
    echo "tap repo at Casks/anubis-oss.rb, commit, and push."
    exit 0
fi

# --- Tap-mode: commit and push -------------------------------------

cd "$TAP_PATH"

if ! git diff --quiet -- Casks/anubis-oss.rb; then
    BRANCH="bump-anubis-oss-${VERSION}"
    if [[ "$OPEN_PR" -eq 1 ]]; then
        git checkout -b "$BRANCH"
    fi

    git add Casks/anubis-oss.rb
    git commit -m "anubis-oss ${VERSION}

Bump cask to v${VERSION}.0 release.
- new sha256 ${SHA256}
- asset: ${ASSET_URL}"

    if [[ "$OPEN_PR" -eq 1 ]]; then
        git push -u origin "$BRANCH"
        gh pr create \
            --title "anubis-oss ${VERSION}" \
            --body "Cask bump for the v${VERSION}.0 release of Anubis OSS.

Source release: https://github.com/uncSoft/anubis-oss/releases/tag/v${VERSION}.0
Asset SHA256: \`${SHA256}\`"
    else
        git push
        echo "==> Pushed cask bump to $(git remote get-url origin)"
    fi
else
    echo "==> No change to commit (cask was already at ${VERSION})."
fi
