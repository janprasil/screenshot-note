#!/bin/zsh
set -eu
cd -- "${0:A:h}"
# Build outside synced Documents folders to avoid Finder/resource-fork metadata.
build_root=$(mktemp -d "${TMPDIR%/}/screenshot-note-build.XXXXXX")
app="$build_root/Screenshot Note.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -X Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
python3 tests/localization-keys.py
cp -R -X Localizations/en.lproj Localizations/cs.lproj "$app/Contents/Resources/"
cp -X Info.plist "$app/Contents/Info.plist"
python3 scripts/configure-build.py "$app/Contents/Info.plist"
# SwiftPM kompiluje appku i Native Messaging helper; .app se skládá zde.
swift build -c release --product ScreenshotNote
swift build -c release --product screenshot-note-bridge
bin="$(swift build -c release --show-bin-path)"
cp -X "$bin/ScreenshotNote" "$app/Contents/MacOS/ScreenshotNote"
cp -X "$bin/screenshot-note-bridge" "$app/Contents/MacOS/screenshot-note-bridge"
xattr -cr "$app"
# Stabilní podpis drží přístup do Klíčenky napříč buildy; ad-hoc podpis se mění s každým buildem.
identity="${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --sign "${identity:--}" "$app/Contents/MacOS/screenshot-note-bridge"
codesign --force --sign "${identity:--}" "$app"
codesign --verify --strict "$app"
"$app/Contents/MacOS/ScreenshotNote" --self-test
"$app/Contents/MacOS/ScreenshotNote" --folder-transfer-self-test
"$app/Contents/MacOS/ScreenshotNote" --bridge-self-test
print "Vytvořeno: $app"
# --install nahradí ~/Applications kopii; předchozí verzi zálohuje.
if [[ "${1:-}" == "--install" ]]; then
 installed="$HOME/Applications/Screenshot Note.app"
 backup="$HOME/Library/Application Support/Screenshot Note/App Updates/$(date +%Y%m%d-%H%M%S)"
 osascript -e 'tell application id "'"$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")"'" to quit' 2>/dev/null || true
 for _ in {1..20}; do pgrep -xq ScreenshotNote || break; sleep 0.25; done
 pkill -x ScreenshotNote 2>/dev/null || true
 mkdir -p "$backup" "$HOME/Applications"
 [[ -d "$installed" ]] && ditto "$installed" "$backup/previous-installed.app" && rm -rf "$installed"
 ditto "$app" "$installed"
 open "$installed"
 print "Nainstalováno: $installed (záloha: $backup)"
fi
