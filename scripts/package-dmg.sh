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

# Odeslání a čekání snesou krátké výpadky sítě; rozhoduje až konečný stav u Applu.
notarize() {
  local result id state attempt deadline
  for attempt in 1 2 3; do
    result=$(xcrun notarytool submit "$1" "${auth[@]}" --output-format json) && id=$(print -r -- "$result" | plutil -extract id raw - 2>/dev/null) && break
    print -u2 "Submit attempt $attempt failed: $result"
    sleep 30
  done
  [[ -n "${id:-}" ]] || { print -u2 "Notarization submit failed: ${1:t}"; return 1 }
  print "Submitted ${1:t}: $id"
  deadline=$(( SECONDS + ${NOTARY_TIMEOUT_MINUTES:-150} * 60 ))
  while (( SECONDS < deadline )); do
    state=$(xcrun notarytool info "$id" "${auth[@]}" --output-format json 2>/dev/null | plutil -extract status raw - 2>/dev/null) || state=""
    case "$state" in
      Accepted) print "Accepted ${1:t}: $id"; return ;;
      Invalid|Rejected) xcrun notarytool log "$id" "${auth[@]}" || true; print -u2 "Notarization $state: ${1:t}"; return 1 ;;
    esac
    sleep 30
  done
  print -u2 "Notarization timed out: ${1:t} ($id)"
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
