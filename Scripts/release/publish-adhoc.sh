#!/usr/bin/env bash
#
# Publish an ad-hoc signed (not notarized) preview release.
#
#   Scripts/release/publish-adhoc.sh <version> [--skip-tests] [--force] [--reuse-dmg]
#
# What it does:
#   1. Checks the version matches project.yml and ReleaseNotes/<version>.md.
#   2. Runs the release gates (verify-project, headless tests, package tests,
#      Xcode tests) unless --skip-tests is given.
#   3. Builds the universal DMG via build-local-dmg.sh, which itself refuses
#      to ship a build that fails its launch or crash-recovery checks. Pass
#      --reuse-dmg to publish an already-built build/Browsemium-<version>.dmg
#      after re-verifying its integrity.
#   4. Rewrites Site/checksum.txt, Site/release.json (signing: adhoc), and the
#      landing page's version/checksum spans.
#   5. Uploads the DMG to a normal GitHub release (published, marked latest)
#      and re-downloads it to confirm the published bytes match.
#
# What it deliberately does not do: Sparkle signatures, appcast entries,
# Homebrew cask updates — those resume with the notarized pipeline. Site
# deployment is attempted only when VERCEL_TOKEN/VERCEL_ORG_ID/
# VERCEL_PROJECT_ID are set; otherwise the Site/ changes are left uncommitted
# for review, push, and deploy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO="Cubinghackerz/browsemium"
VERSION=""
SKIP_TESTS=0
FORCE=0
REUSE_DMG=0
for argument in "$@"; do
  case "$argument" in
    --skip-tests) SKIP_TESTS=1 ;;
    --force) FORCE=1 ;;
    --reuse-dmg) REUSE_DMG=1 ;;
    *) VERSION="$argument" ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Usage: Scripts/release/publish-adhoc.sh <version> [--skip-tests] [--force] [--reuse-dmg]" >&2
  exit 1
fi

fail() { echo "✗ $1" >&2; exit 1; }

PROJECT_VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' "$ROOT/project.yml")"
[[ "$VERSION" == "$PROJECT_VERSION" ]] \
  || fail "Version $VERSION does not match project.yml MARKETING_VERSION $PROJECT_VERSION"
[[ -f "$ROOT/ReleaseNotes/$VERSION.md" ]] \
  || fail "ReleaseNotes/$VERSION.md is missing"

gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 && [[ "$FORCE" != "1" ]]; then
  fail "Release v$VERSION already exists — delete it or pass --force"
fi

cd "$ROOT"

if [[ "$SKIP_TESTS" != "1" ]]; then
  echo "→ Release gates…"
  Scripts/verify-project.sh
  BROWSEMIUM_HEADLESS=1 swift run --package-path Packages/BrowsemiumKit BrowsemiumHeadlessTests
  swift test --package-path Packages/BrowsemiumKit
  xcodebuild -project Browsemium.xcodeproj -scheme Browsemium \
    -configuration Debug -destination 'platform=macOS' test
else
  echo "→ Skipping release gates (--skip-tests)"
fi

BUILD_ROOT="${BROWSEMIUM_BUILD_DIR:-${ROOT}/build}"
DMG="${BUILD_ROOT}/Browsemium-${VERSION}.dmg"

if [[ "$REUSE_DMG" == "1" ]]; then
  echo "→ Reusing $DMG"
  [[ -f "$DMG" ]] || fail "Expected DMG missing: $DMG"
else
  echo "→ Building universal DMG…"
  Scripts/release/build-local-dmg.sh "$VERSION" --universal
  [[ -f "$DMG" ]] || fail "Expected DMG missing: $DMG"
fi
hdiutil verify "$DMG" >/dev/null || fail "$DMG failed hdiutil verify"

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
FILE="Browsemium-${VERSION}.dmg"

echo "→ Updating site metadata…"
printf '%s  %s\n' "$SHA" "$FILE" > Site/checksum.txt
cat > Site/release.json <<EOF
{
  "version": "${VERSION}",
  "tag": "v${VERSION}",
  "file": "${FILE}",
  "sha256": "${SHA}",
  "signing": "adhoc",
  "bundleId": "com.browsemium.browser",
  "teamId": "",
  "minimumMacOS": "14.0"
}
EOF
python3 Scripts/release/update-landing-page.py --version "$VERSION" --sha256 "$SHA"

echo "→ Publishing GitHub release v${VERSION}…"
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "v$VERSION" "$DMG" --repo "$REPO" --clobber
  gh release edit "v$VERSION" --repo "$REPO" --title "Browsemium $VERSION" \
    --notes-file "ReleaseNotes/$VERSION.md" --latest
else
  gh release create "v$VERSION" "$DMG" --repo "$REPO" \
    --title "Browsemium $VERSION" --notes-file "ReleaseNotes/$VERSION.md" --latest
fi

echo "→ Verifying the published asset…"
VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
curl -fsSL --retry 5 --retry-delay 5 \
  "https://github.com/${REPO}/releases/download/v${VERSION}/${FILE}" \
  -o "$VERIFY_DIR/$FILE"
PUBLISHED_SHA="$(shasum -a 256 "$VERIFY_DIR/$FILE" | awk '{print $1}')"
[[ "$PUBLISHED_SHA" == "$SHA" ]] || fail "Published asset checksum does not match the local DMG"

echo
echo "✓ Browsemium $VERSION published (ad-hoc signed, not notarized)."
echo "  SHA-256: $SHA"
echo
if [[ -n "${VERCEL_TOKEN:-}" && -n "${VERCEL_ORG_ID:-}" && -n "${VERCEL_PROJECT_ID:-}" ]]; then
  echo "→ Deploying the site…"
  npx --yes vercel@60.0.1 deploy --prod --yes --token "$VERCEL_TOKEN" --cwd Site
else
  cat <<'EOF'
Site changes are uncommitted. To finish the release:
  1. git add Site/ ReleaseNotes/ README.md PRODUCT.md MEGAPLAN.md && git commit
  2. git push  (deploys automatically if the Vercel project tracks main)
     or deploy manually: npx vercel deploy --prod --cwd Site
  3. Confirm https://browsemium.vercel.app/release.json shows the new SHA-256,
     then test: curl -fsSL https://browsemium.vercel.app/install.sh | bash
EOF
fi
