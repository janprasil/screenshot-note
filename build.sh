#!/bin/zsh
set -eu
cd -- "${0:A:h}"
# Build outside synced Documents folders to avoid Finder/resource-fork metadata.
build_root=$(mktemp -d "${TMPDIR%/}/screenshot-note-build.XXXXXX")
app="$build_root/Screenshot Note.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -X Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp -R -X Localizations/en.lproj Localizations/cs.lproj "$app/Contents/Resources/"
cp -X Info.plist "$app/Contents/Info.plist"
python3 scripts/configure-build.py "$app/Contents/Info.plist"
task_arch="$(uname -m)"
xcrun swiftc -target "${task_arch}-apple-macosx13.0" Localization.swift CenteredFields.swift About.swift Design.swift DesignPreview.swift CaptureNote.swift CloudLibrary.swift CloudSettings.swift CloudTests.swift AnnotationGeometry.swift Annotations.swift Interface.swift SessionPicker.swift ImageNoteEditor.swift MarkdownEditor.swift Topics.swift PreviousSessions.swift main.swift -o "$app/Contents/MacOS/ScreenshotNote"
xattr -cr "$app"
# Set SIGNING_IDENTITY to your own personal certificate fingerprint if available.
codesign --force --sign "${SIGNING_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
"$app/Contents/MacOS/ScreenshotNote" --self-test
print "Vytvořeno: $app"
