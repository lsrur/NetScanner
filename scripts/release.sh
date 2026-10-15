#!/bin/sh
# Builds a universal Release of NetScanner and packages it as dist/NetScanner-<version>.dmg.
# The version comes from MARKETING_VERSION in project.yml; bump it there first.
#
#   scripts/release.sh                      build and verify the DMG only
#   scripts/release.sh --publish            also tag v<version> and create the GitHub release
#   scripts/release.sh --publish --notes FILE   prepend FILE (Markdown) to the release notes
#   scripts/release.sh --skip-tests         skip the test suite (not allowed with --publish)
set -eu
cd "$(dirname "$0")/.."

publish=0
skip_tests=0
notes_file=""
while [ $# -gt 0 ]; do
    case "$1" in
        --publish) publish=1 ;;
        --skip-tests) skip_tests=1 ;;
        --notes) shift; notes_file="${1:?--notes needs a file}" ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

fail() { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

version=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)
[ -n "$version" ] || fail "MARKETING_VERSION not found in project.yml"
tag="v$version"
dmg="dist/NetScanner-$version.dmg"
app="build/Build/Products/Release/NetScanner.app"
echo "NetScanner $version"

if [ "$publish" -eq 1 ]; then
    [ "$skip_tests" -eq 0 ] || fail "--skip-tests can't be combined with --publish"
    [ -z "$notes_file" ] || [ -f "$notes_file" ] || fail "notes file not found: $notes_file"
    command -v gh >/dev/null || fail "GitHub CLI (gh) is required to publish"
    step "Checking the repository"
    [ "$(git symbolic-ref --short HEAD)" = "main" ] || fail "not on main"
    [ -z "$(git status --porcelain)" ] || fail "working tree has uncommitted changes"
    git fetch -q origin main
    [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "main is not in sync with origin/main (push or pull first)"
    ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "tag $tag already exists locally; bump MARKETING_VERSION"
    ! gh release view "$tag" >/dev/null 2>&1 || fail "release $tag already exists on GitHub; bump MARKETING_VERSION"
fi

step "Generating the Xcode project"
xcodegen generate -q

if [ "$skip_tests" -eq 0 ]; then
    step "Running tests"
    xcodebuild -scheme NetScanner -destination 'platform=macOS' -derivedDataPath build test -quiet \
        || fail "tests failed"
fi

step "Building universal Release"
rm -rf "$app"
xcodebuild -scheme NetScanner -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath build build -quiet

built_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[ "$built_version" = "$version" ] || fail "app reports version $built_version, expected $version"
archs=$(lipo -archs "$app/Contents/MacOS/NetScanner")
case "$archs" in *arm64*) ;; *) fail "missing arm64 slice ($archs)" ;; esac
case "$archs" in *x86_64*) ;; *) fail "missing x86_64 slice ($archs)" ;; esac
codesign --verify --deep --strict "$app" || fail "code signature does not verify"
! strings "$app/Contents/MacOS/NetScanner" | grep -q NETSCANNER_ || fail "debug hooks found in the Release binary"
echo "version $built_version, archs: $archs, signature ok"

step "Packaging $dmg"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/NetScanner.app"
ln -s /Applications "$stage/Applications"
mkdir -p dist
rm -f "$dmg"
hdiutil create -quiet -volname "NetScanner $version" -srcfolder "$stage" -fs HFS+ -format UDZO -o "$dmg"
hdiutil verify -quiet "$dmg"
sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
echo "$dmg ($(du -h "$dmg" | cut -f1 | tr -d ' ')), SHA-256 $sha"

if [ "$publish" -eq 0 ]; then
    printf '\nDMG ready. Run with --publish to create the %s release on GitHub.\n' "$tag"
    exit 0
fi

step "Publishing $tag on GitHub"
notes=$(mktemp)
trap 'rm -rf "$stage" "$notes"' EXIT
{
    if [ -n "$notes_file" ]; then
        cat "$notes_file"
        printf '\n'
    fi
    cat <<EOF
## Install
1. Download **NetScanner-$version.dmg**, open it and drag **NetScanner** to **Applications**.
2. This build is **not signed with an Apple Developer ID**, so the first time you open it macOS says it can't verify the developer. To open it anyway, either:
   - try to open the app once, then go to **System Settings → Privacy & Security** and click **Open Anyway**, or
   - run \`xattr -dr com.apple.quarantine /Applications/NetScanner.app\` in Terminal.
3. On the first scan, allow **Local Network** access when macOS asks.

## Requirements
macOS 15 or later. Universal app (Apple silicon and Intel).

SHA-256 of the DMG: \`$sha\`
EOF
} > "$notes"
gh release create "$tag" "$dmg" --target main --title "NetScanner $version" --notes-file "$notes"
gh release view "$tag" --json url -q .url
