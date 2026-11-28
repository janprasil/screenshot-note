#!/bin/zsh
# Notarizuje podepsanou appku, zabalí ji do DMG a notarizuje i DMG.
#   package-dmg.sh APP DMG VOLNAME
# Přihlášení: NOTARY_PROFILE, nebo NOTARY_APPLE_ID + NOTARY_PASSWORD + NOTARY_TEAM_ID.
set -eu
app="$1" dmg="$2" volume="$3"
identity="${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity}"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  auth=(--keychain-profile "$NOTARY_PROFILE")
else
  auth=(--apple-id "${NOTARY_APPLE_ID:?}" --password "${NOTARY_PASSWORD:?}" --team-id "${NOTARY_TEAM_ID:?}")
fi
work=$(mktemp -d "${TMPDIR%/}/screenshot-note-dmg.XXXXXX")
trap 'rm -rf "$work"' EXIT

# notarytool může skončit úspěšně i při zamítnutí, rozhoduje stav.
notarize() {
  local result id
  result=$(xcrun notarytool submit "$1" "${auth[@]}" --wait --timeout 150m --output-format json) || true
  print -r -- "$result"
  [[ "$(print -r -- "$result" | plutil -extract status raw - 2>/dev/null)" == Accepted ]] && return
  id=$(print -r -- "$result" | plutil -extract id raw - 2>/dev/null) && xcrun notarytool log "$id" "${auth[@]}" || true
  print -u2 "Notarization failed: ${1:t}"
  return 1
}

ditto -c -k --keepParent "$app" "$work/app.zip"
notarize "$work/app.zip"
xcrun stapler staple "$app"
mkdir "$work/root"
ditto "$app" "$work/root/${app:t}"
# Odkaz na Applications umožní instalaci přetažením.
ln -s /Applications "$work/root/Applications"
hdiutil create -volname "$volume" -srcfolder "$work/root" -ov -format UDZO "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"
spctl --assess --type execute -vv "$app"
spctl --assess --type open --context context:primary-signature -vv "$dmg"
