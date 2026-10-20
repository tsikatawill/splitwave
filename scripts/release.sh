#!/bin/zsh
# Builds a universal Splitwave.dmg and publishes it as a GitHub release.
#   scripts/release.sh 0.2.0                  bump, build, tag v0.2.0, push, publish
#   scripts/release.sh 0.2.0 --dry-run        build dist/Splitwave.dmg only
#   scripts/release.sh 0.2.0 --notes FILE     use FILE as the release notes (default: generated)
#
# Releases are signed ad hoc (no Apple Developer ID), so first launch needs System Settings ›
# Privacy & Security › Open Anyway; the website and README explain that.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: scripts/release.sh X.Y.Z [--dry-run] [--notes FILE]"; exit 1; }
shift
DRY_RUN=0
NOTES=""
while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --notes) NOTES="$2"; shift ;;
    *) echo "unknown option $1"; exit 1 ;;
  esac
  shift
done
TAG="v$VERSION"

if (( ! DRY_RUN )); then
  [[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first."; exit 1; }
  git rev-parse "$TAG" >/dev/null 2>&1 && { echo "$TAG already exists."; exit 1; }
  gh auth status >/dev/null
fi

swift test

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
BUILD=$(( $(git rev-list --count HEAD 2>/dev/null || echo 0) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Resources/Info.plist

SPLITWAVE_SIGN_IDENTITY=- UNIVERSAL=1 SPLITWAVE_VERSION="$VERSION" SPLITWAVE_BUILD="$BUILD" scripts/build-app.sh

rm -rf dist
mkdir -p dist/stage
cp -R build/Splitwave.app dist/stage/
ln -s /Applications dist/stage/Applications
hdiutil create -quiet -volname "Splitwave $VERSION" -srcfolder dist/stage -ov -format UDZO dist/Splitwave.dmg
rm -rf dist/stage
(cd dist && shasum -a 256 Splitwave.dmg > Splitwave.dmg.sha256)
echo "Built dist/Splitwave.dmg ($(du -h dist/Splitwave.dmg | cut -f1)), sha256 $(cut -d' ' -f1 dist/Splitwave.dmg.sha256)"

if (( DRY_RUN )); then
  git checkout -- Resources/Info.plist 2>/dev/null || true
  exit 0
fi

git add Resources/Info.plist
git diff --cached --quiet || git commit -m "Release $TAG"
git tag -a "$TAG" -m "Splitwave $VERSION"
git push origin HEAD --follow-tags

NOTE_ARGS=(--generate-notes)
[[ -n "$NOTES" ]] && NOTE_ARGS=(--notes-file "$NOTES")
gh release create "$TAG" dist/Splitwave.dmg dist/Splitwave.dmg.sha256 --title "Splitwave $VERSION" "${NOTE_ARGS[@]}"
echo "Published $TAG"
