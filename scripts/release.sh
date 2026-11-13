#!/bin/bash
# Builds the DMG and publishes it as a GitHub release, which is what the website's
# Download buttons point at (releases/latest/download/SpaceSaver.dmg).
#
#   scripts/release.sh                 # release v<AppVersion.current from Version.swift>
#   scripts/release.sh --notes "…"     # custom release notes
#   REPO=owner/name scripts/release.sh # another repository (default: the origin remote)
#
# Needs the GitHub CLI (gh) signed in to an account that can write to the repository.
# Set GH_TOKEN to use a specific account without switching the active one.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTES=""
if [[ "${1:-}" == "--notes" ]]; then NOTES="${2:-}"; fi

VERSION="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/SpaceSaverCore/Support/Version.swift)"
TAG="v$VERSION"
REPO="${REPO:-$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"
[ -n "$VERSION" ] && [ -n "$REPO" ] || { echo "Couldn't work out the version or repository." >&2; exit 1; }

[ -s scripts/update-public-key.txt ] || { echo "No update key. Run: swift scripts/update-signing.swift generate" >&2; exit 1; }

echo "▸ Building SpaceSaver $VERSION"
scripts/build-app.sh --dmg

DMG="build/SpaceSaver.dmg"
hdiutil verify "$DMG" >/dev/null
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "  SHA-256 $SHA"

echo "▸ Signing the DMG for in-app updates"
swift scripts/update-signing.swift sign "$DMG" > "$DMG.sig"
swift scripts/update-signing.swift verify "$DMG" "$DMG.sig" >/dev/null
echo "  $DMG.sig"

if [ -z "$NOTES" ]; then
  NOTES="SpaceSaver $VERSION for Apple silicon Macs running macOS 14 or later."
fi
# The first paragraph of the notes is what the in-app update banner shows.
NOTES="$NOTES

**Install:** open the DMG and drag SpaceSaver to Applications. The app isn't notarized yet, so open it once, then choose **Open Anyway** in System Settings › Privacy & Security.

SHA-256: \`$SHA\`"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "▸ Replacing the DMG on existing release $TAG"
  gh release upload "$TAG" "$DMG" "$DMG.sig" --repo "$REPO" --clobber
else
  echo "▸ Creating release $TAG on $REPO"
  gh release create "$TAG" "$DMG" "$DMG.sig" --repo "$REPO" --title "SpaceSaver $VERSION" --notes "$NOTES" --latest
fi

echo "✓ https://github.com/$REPO/releases/tag/$TAG"
