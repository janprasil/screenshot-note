# Restrukturalizace Mac appky — plán (2026-11-21)

Cíl: přehledná struktura zdrojů podle oblastí, build přes Swift Package Manager, testy mimo
produkční binárku, menší soubory s jednou odpovědností. Chování appky se nemění.

Výchozí stav: `origin/main` 07001a5 (PR #15, Chrome bridge F1). Čísla řádků níže platí pro tento commit.

## 1. Současný stav

### 1.1 Soubory v kořeni (8 389 řádků, 712 kB; řádky jsou husté, proto i velikost)

| Soubor | Řádky / kB | Odpovědnost, hlavní typy | Vrstva |
|---|---|---|---|
| `main.swift` | 845 / 78 | `AppDelegate` (`main.swift:5`–`325`): menu, snímání, cloudový timer (`:10`, `:27`), ukončení a záloha konceptu (`:100`–`134`), `previewTest()` (`:318`). Top-level kód: přepínače `--language-check` (`:327`), dočasný index pro testy (`:330`–`333`), testovací vstupy `--folder-sync-self-test` (`:334`), `--folder-transfer-self-test` (`:343`), `--bridge-self-test` (`:349`), `--cloud-self-test` (`:355`), `--self-test` s 163 asserty a 22 PASS řádky (`:364`–`834`), `--design-export` (`:835`), jedna instance + start (`:840`–`845`) | AppKit + testy |
| `CloudTests.swift` | 1 706 / 177 | Jen testy: `CloudMemoryVault` (`:4`), fixtury, 18 testovacích funkcí, URLProtocol stuby (`:724`, `:856`, `:1083`, `:1392`) | testy |
| `CloudFolders.swift` | 1 247 / 102 | Modely složek a relací (`:6`–`115`), třída `CloudFolders` (`:117`–`1238`, 64 `private` členů): katalog, mapování, stahování, koš, šablony, týmové složky | logika + síť + FS |
| `CloudLibrary.swift` | 876 / 68 | `CloudEndpoint` (`:6`), `CloudBuild` (`:17`), `CloudConnection` (`:25`), `CloudCredentialStore`/`CloudKeychain` (`:41`/`:45`), `CloudTransport` (`:89`), DTO (`:142`–`193`), `cloudImage` (`:195`), třída `CloudLibrary` (`:227`–`821`): párování, outbox, upload; sdílení (`:823`) | logika + síť + Keychain |
| `Interface.swift` | 563 / 45 | `ScreenshotPanel` (`:6`), pomocné funkce UI (`:16`–`47`), `Shortcut`/`Hotkeys` (`:48`/`:69`, Carbon), `ShortcutButton`/`ShortcutSettings` (`:98`/`:115`), `SettingsController` (`:144`), tlačítka náhledů (`:185`/`:204`), `SessionCommentField` (`:243`), `Composer` (`:258`–`541`), `installEditingMenu` (`:542`) | AppKit |
| `BrowserBridge.swift` | 366 / 21 | `BrowserBridge` socket server (`:12`), `NativeHostRegistration` (`:191`), testy `FrameStream` + `browserBridgeTests` (`:248`–`366`), testovací `broadcast` (`:183`) | Foundation + testy |
| `FolderTransfers.swift` | 357 / 26 | `FolderTransfers` (`:11`), `FolderDialogs` (`:94`), `TrashNotifier` (`:337`) | logika + AppKit |
| `Topics.swift` | 365 / 33 | `Topic` (`:3`), `Topics` (`:22`), `StarButton`, `TopicSettings` (`:111`) | model + AppKit |
| `PreviousSessions.swift` | 335 / 25 | Hledání a aktualizace uložených relací, odkazy na obrázky, `DraftTarget` | čistá logika |
| `Annotations.swift` | 303 / 30 | `Tool`, `Mark`, `AnnotationDocument`, `DrawingView`, `AnnotationEditor`, dialogy | AppKit |
| `SessionIndex.swift` | 222 / 15 | `SessionRecord`, `SessionIndex` (`:37`), xattr značky, migrace značek (`:181`) | logika + FS |
| `CloudSettings.swift` | 212 / 14 | Okno cloudové knihovny | AppKit |
| `CaptureNote.swift` | 167 / 13 | `Draft`, cesty (`draftRoot` `:31`, `recoveryRoot` `:15`), export Markdownu, šablony | čistá logika + FS |
| `AnnotationGeometry.swift` | 147 / 8 | Úchyty, škálování, rotace anotací | AppKit geometrie |
| `Templates.swift` | 104 / 8 | `TemplateDefaults` (`:4`) | logika |
| `MarkdownEditor.swift` | 104 / 11 | `LiveMarkdownView`, `MarkdownEditor` | AppKit |
| `Design.swift` | 101 / 9 | Paleta, `AppButton`, povrchy | AppKit |
| `DesignPreview.swift` | 84 / 11 | `--design-export` náhledy | AppKit nástroj |
| `BridgeHost.swift` | 72 / 3 | Samostatná binárka `screenshot-note-bridge` (`@main`, jen Foundation) | bridge |
| `BridgeWire.swift` | 72 / 3 | Framing Native Messaging, sdílený app + bridge | bridge |
| `SessionPicker.swift` | 42 / 3 | Dialog výběru relace | AppKit |
| `About.swift`, `CenteredFields.swift`, `ImageNoteEditor.swift`, `Localization.swift` | 28 / 26 / 25 / 20 | Okno O aplikaci, centrovaná pole, poznámka k obrázku, `AppLanguage` + `L`/`LF`/`LP` | AppKit / logika |

Závislosti a sdílený stav (vše v jednom modulu, bez `import` mezi soubory):
- Singletony: `CloudLibrary.shared`, `CloudFolders.shared` (`CloudFolders.swift:118`), `FolderTransfers.shared`,
  `SessionIndex.shared` (testy ho přepisují, `main.swift:331`), `TemplateDefaults.shared` (`main.swift:332`),
  `BrowserBridge.shared`, `TrashNotifier.shared`, `AboutController.shared`, `WindowChromeActions.shared`
  (`CenteredFields.swift:20`), `CloudTransport.shared` (`CloudLibrary.swift:90`).
- Globály: `fm`, `draftRoot`, `recoveryRoot`, `destination` (`CaptureNote.swift:15`–`32`),
  `isExportingDesign` (`Design.swift:3`), `capturePresentationScreen` (`Interface.swift:16`), `AppLanguage.override`.
- `Bundle.main` čtou: `CloudBuild.endpoint` (`CloudLibrary.swift:19`, při chybějícím klíči `preconditionFailure`),
  `AppLanguage.bundle` (`Localization.swift:11`), `NativeHostRegistration.bundledHelper` (`BrowserBridge.swift:197`),
  test bridge (`BrowserBridge.swift:284`, helper vedle spustitelného souboru), About/Settings (ikona, verze).
  Testy tedy potřebují běžet uvnitř bundlu se stejným `Info.plist`, `lproj` a helperem.
- Testy volají interní API napříč appkou (`Composer`, `DrawingView`, `AppDelegate.restoreRecoveredDraft`, `CloudFolders`).

### 1.2 build.sh
- Kopíruje ikonu, `Localizations/*.lproj`, `Info.plist`; `scripts/configure-build.py` zapeče origin a verzi (`build.sh:8`–`12`).
- `xcrun swiftc -target <arch>-apple-macosx13.0` s ručním seznamem 24 souborů, bez `-O` (tj. `-Onone`) (`build.sh:14`).
- Druhá binárka `screenshot-note-bridge`: `-parse-as-library BridgeWire.swift BridgeHost.swift` (`build.sh:16`).
- Podpis: identita `SIGNING_IDENTITY` nebo první Apple Development/Developer ID, jinak ad-hoc; nejdřív helper, pak app,
  `codesign --verify --strict` (`build.sh:18`–`22`). Bez hardened runtime a bez entitlements (žádný soubor v repu).
- Self-testy v produkční binárce: `--self-test`, `--folder-transfer-self-test`, `--bridge-self-test` (`build.sh:23`–`25`).
- `--install`: ukončí appku, zálohuje do `~/Library/Application Support/Screenshot Note/App Updates/<čas>`, `ditto` (`build.sh:28`–`39`).
- Poslední řádek `Vytvořeno: <cesta>` čte release workflow (`release.yml:83`–`85`).

### 1.3 Testy dnes
- V produkční binárce: 18 funkcí v `CloudTests.swift` (≈372 assertů), `browserBridgeTests` (28 kontrol,
  `BrowserBridge.swift:264`), blok `--self-test` v `main.swift:364`–`834` (163 assertů, 22 PASS řádků),
  opt-in `--interactive-ui-tests` (`main.swift:366`, README).
- Spouští je jen přepínače binárky; `--cloud-self-test` volá `tests/cloud-rest.py:289` (loopback fixtura),
  `--folder-sync-self-test` volá webový test `screenshot-note-web/web/tests/cloud-folders.flow.mjs:58`
  přes `SCREENSHOT_NOTE_NATIVE_TEST_BINARY`.
- Python: `tests/localization-keys.py` (klíče L/LF v katalozích; glob `*.swift` jen v kořeni — po přesunu by tiše nic
  nekontroloval), `tests/build-config.py`, `tests/release.py`, `tests/cloud-rest.py` (v CI zatím ne, `ci.yml:28`).
- Testy používají `assert`, fungují jen díky `-Onone`.

### 1.4 CI
- `ci.yml`: `macos-15`, `defaults write -g AppleLanguages (cs en)`, `./build.sh`, `tests/build-config.py`, `tests/release.py`.
- `codeql.yml`: Swift `build-mode: manual` přes `./build.sh` (~20 min), Actions bez buildu.
- `release.yml`: `./build.sh | tee build.log`, cesta z `Vytvořeno:`, DMG + sha256, RC / promote. Ruleset main vyžaduje zelené CI.
- `pr-title.yml`: conventional title. Dependabot: jen GitHub Actions.
- Rozbije se při změně: cesta `Vytvořeno:` (release), `./build.sh` jako jediný vstup (CI, CodeQL), glob v `localization-keys.py`.

## 2. Cílová struktura

```
Package.swift
Sources/
  BridgeWire/BridgeWire.swift                    knihovna, framing (public API)
  ScreenshotNoteBridge/BridgeHost.swift          executable screenshot-note-bridge
  ScreenshotNote/main.swift                      tenký executable: volá ScreenshotNoteApp.main()
  ScreenshotNoteKit/                             knihovna se vší logikou a UI
    App/        AppDelegate.swift, Launch.swift, About.swift
    Capture/    Composer.swift, ScreenshotPanel.swift, Hotkeys.swift, SessionPicker.swift, ImageNoteEditor.swift
    Settings/   SettingsController.swift, ShortcutSettings.swift, CloudSettings.swift
    Annotations/ Annotations.swift, AnnotationGeometry.swift
    Notes/      CaptureNote.swift, PreviousSessions.swift, Templates.swift, Topics.swift, MarkdownEditor.swift
    Storage/    SessionIndex.swift
    Cloud/      CloudLibrary*.swift, CloudFolders*.swift, FolderTransfers.swift
    BrowserBridge/ BrowserBridge.swift, NativeHostRegistration.swift
    UI/         Design.swift, DesignPreview.swift, CenteredFields.swift, InterfaceSupport.swift
    Localization/ Localization.swift
  ScreenshotNoteTestHost/                        testovací executable, nikdy v .app
    main.swift, AppSelfTests.swift, CloudTests*.swift, BrowserBridgeTests.swift
Assets/, Localizations/, Info.plist             beze změny umístění
```

Přiřazení: každý dnešní soubor má cíl výše; `Interface.swift` se v kroku 5 rozdělí na `ScreenshotPanel`, `Hotkeys`
(+`Shortcut`), `ShortcutSettings` (+`ShortcutButton`), `SettingsController`, `Composer` (+ tlačítka náhledů,
`SessionCommentField`) a `InterfaceSupport` (`showError`, `label`, `drawAdaptiveSymbol`, `installEditingMenu`).
`main.swift` se v kroku 4 rozdělí na `AppDelegate.swift`, `Launch.swift` a `AppSelfTests.swift`.

## 3. Build systém — varianty

| | (a) SwiftPM + ruční .app | (b) Xcode projekt | (c) swiftc s globem |
|---|---|---|---|
| Testy mimo binárku | ano (samostatný target) | ano | jen druhou ruční binárkou |
| CI / CLT | `swift build`, žádné nové nástroje | `xcodebuild`, projekt v gitu (konflikty pbxproj) | beze změny |
| Podpis, Klíčenka | podpis dál v build.sh, stejná identita a bundle id | Xcode signing, riziko změny požadavku podpisu | beze změny |
| CodeQL swift manual | podporuje `swift build` | podporuje | beze změny |
| Rychlost | inkrementální build | inkrementální | vždy vše |
| Budoucí závislosti | SwiftPM nativně | SPM v Xcode | ručně |

Doporučení: **(a) SwiftPM**. `.app` dál skládá `build.sh` (Info.plist, lproj, ikona, helper, podpis), takže identita,
bundle id i Keychain service zůstávají. Bez nových externích závislostí.

Detaily: `swift-tools-version:5.9`, `platforms: [.macOS(.v13)]`, jazykový režim Swift 5 (jako dnes).
Jedno `swift build -c release` pro appku, bridge i testovací host; vše `-Onone`, `ScreenshotNoteKit` a `BridgeWire`
s `-enable-testing`, takže testovací host linkuje tytéž objekty knihovny jako appka (viz Rozhodnuto v noci). Produkty `ScreenshotNote` a `screenshot-note-bridge` mají stejná jména binárek jako dnes.

## 4. Testy mimo produkční binárku

`Bundle.main` (1.1) dělá XCTest v `xctest` procesu nepoužitelný bez zásahů do produkčního kódu (endpoint,
lokalizace, helper). Proto:
- Target `ScreenshotNoteTestHost` (executable, `@testable import ScreenshotNoteKit`) obsahuje veškerý dnešní testovací kód
  beze změny assertů a přebírá přepínače `--self-test`, `--interactive-ui-tests`, `--folder-transfer-self-test`,
  `--bridge-self-test`, `--cloud-self-test`, `--folder-sync-self-test`.
- `build.sh` vedle `Screenshot Note.app` složí `Screenshot Note Tests.app` (stejný Info.plist, lproj, ikona, helper,
  stejný podpis; spustitelný soubor je testovací host) a spustí tytéž tři sady jako dnes. Testy tak běží ve stejném
  prostředí jako dnes, jen v jiné binárce. Release DMG bere jen `Screenshot Note.app`.
- `tests/cloud-rest.py` a webový `cloud-folders.flow.mjs` dostanou cestu k testovacímu hostu (`Testy: <cesta>` v
  build.sh); argumenty a výstup zůstávají.
- XCTest / Swift Testing: odloženo, viz Otevřené otázky. Předpoklad: injekce `Bundle` pro endpoint, lokalizaci a helper.
- Runtime nástroje v appce zůstávají: `--design-export` (dokumentované generování screenshotů), `--preview-test`
  (ruční náhled okna), `--language-check` (LOCALIZATION.md). Nejsou to testovací sady a nemají asserty.

Inventura (cíl: vše v `ScreenshotNoteTestHost`, kontrola počtu assertů/PASS po každém PR):

| Případ | Dnes | Assertů | Cíl | Spouští |
|---|---|---|---|---|
| hlavní self-test (koncepty, export, anotace, UI regrese, šablony, 12 snímků…) | `main.swift:364`–`834` | 163 + 22 PASS | `AppSelfTests.swift` | build.sh `--self-test` |
| `cloudUnitTests` | `CloudTests.swift:26` | 23 | `CloudTests.swift` | `--self-test` |
| `cloudFolderUnitTests` | `:89` | 7 | totéž | `--self-test` |
| `sessionIndexTests` | `:350` | 13 | totéž | `--self-test` |
| `cloudFolderSyncTests` | `:127` | 13 | totéž | web flow `--folder-sync-self-test` |
| `cloudIntegrationTest` | `:183` | 54 | totéž | `tests/cloud-rest.py` `--cloud-self-test` |
| `folderTransferTests` | `:307` | 7 | totéž | build.sh `--folder-transfer-self-test` |
| `cloudMaterializationTests` | `:402` | 36 | totéž | přes `folderTransferTests` |
| `cloudLegacyMigrationTests` | `:545` | 9 | totéž | přes materializaci |
| `localDeletionTests` | `:630` | 31 | totéž | dtto |
| `folderLifecycleTests` | `:737` | 28 | totéž | dtto |
| `adoptedUploadTests` | `:878` | 20 | totéž | dtto |
| `templateTests` | `:983` | 14 | totéž | dtto |
| `flatLayoutTests` | `:1044` | 5 | totéž | dtto |
| `editAndCommentTests` | `:1104` | 12 | totéž | dtto |
| `staleDraftTests` | `:1166` | 4 | totéž | dtto |
| `markdownLinkTests` | `:1209` | 10 | totéž | dtto |
| `teamFolderTests` | `:1250` | 36 | totéž | dtto |
| `reviewFindingTests` | `:1418` | 50 | totéž | přes `folderTransferTests` |
| `browserBridgeTests` | `BrowserBridge.swift:264` | 28 | `BrowserBridgeTests.swift` | build.sh `--bridge-self-test` |
| interaktivní UI | `main.swift:366` | – | `AppSelfTests.swift` | ručně `--self-test --interactive-ui-tests` |
| Python | `tests/*.py` | – | beze změny | CI |

Kontrola: `tests/test-inventory.py` (a) staticky počítá testovací funkce (19), výskyty `assert(`/`check(` (580) a
`print("PASS:` v hlavním self-testu (22) a selže pod touto hodnotou; (b) selže, když najde testovací kód ve zdrojích appky;
(c) s `--log` ověří, že běh testů v build.sh ohlásil všech 79 řádků z `tests/expected-passes.txt` (77 dnešních PASS,
„Browser bridge self-test passed“ a nově offline `--folder-sync-self-test`). Bod (c) chytí i test, který přestal být volaný.

## 5. Rozdělení velkých souborů

- `CloudTests.swift` (177 kB) → podle oblastí: `CloudTests.swift` (fixtury, unit, integrace), `CloudFolderTests.swift`
  (materializace, migrace, mazání, lifecycle), `CloudUploadTests.swift` (adopted upload, edit, stale), `CloudTemplateTests.swift`
  (šablony, layout, odkazy), `TeamFolderTests.swift`, `ReviewFindingTests.swift`, `CloudTestStubs.swift` (URLProtocol stuby).
- `main.swift` → `AppDelegate.swift`, `Launch.swift`, testy pryč (krok 4).
- `Interface.swift` → podle typů (kap. 2).
- `CloudLibrary.swift` → `CloudEndpoint.swift` (endpoint, build), `CloudKeychain.swift` (connection, credential store),
  `CloudTransport.swift` (failure, transport), `CloudModels.swift` (DTO, manifest), `CloudLibrary.swift` (třída),
  `CloudSharing.swift` (extension sdílení).
- `CloudFolders.swift` → `CloudFolderModels.swift` (veřejné modely a funkce z `:4`–`115`, `:1239`–`1247`) a třída; privátní DTO
  (`FolderEnvelope`, `RemoteNoteList`, `DownloadReceipt` …) zůstávají u třídy. Stejně u `CloudLibrary` (`Envelope`, `CloudJob` …)
  a sdílení (používá privátní `shareRetry`/`now`) zůstává v `CloudLibrary.swift`. Rozdělení samotné třídy na
  extension podle odpovědností (katalog, mapování, stahování, koš, týmy) vyžaduje zrušit `private` u 64 členů; dělá se
  až jako krok 6, pokud zbude čas, jinak zůstává doporučením.
- Protokoly/injekce (síť `CloudTransport`/URLProtocol už existuje, Keychain `CloudCredentialStore` už existuje; chybí
  `Bundle`, FS cesty `draftRoot`/`destination`, čas `Date()`): jen doporučení, mění API a nepatří do noci.

## 6. Zachování chování a bezpečnosti

- Podpis: stejný výběr identity a pořadí (helper, pak app), `codesign --verify --strict`. Ověření `codesign -dv` (Identifier,
  TeamIdentifier, Authority) před/po; po `--install` načtení tokenu z Klíčenky (Cloudová knihovna ukazuje připojení).
- Keychain service `cz.janprasil.screenshotnote.device.v1` (`CloudLibrary.swift:49`), access group žádná, `WhenUnlockedThisDeviceOnly`.
- Bundle id `cz.janprasil.screenshotnote`, Info.plist a `configure-build.py` beze změny; žádné entitlements, žádný hardened runtime (beze změny).
- Native Messaging: název hostu, `allowed_origins`, helper `Contents/MacOS/screenshot-note-bridge` (`BrowserBridge.swift:192`–`197`).
- Lokalizace en/cs: `Localizations/` beze změny, `localization-keys.py` rekurzivně přes `Sources/` s kontrolou, že našel soubory.
- Data uživatele: `~/Library/Application Support/Screenshot Note`, UserDefaults domény, index, xattr — kód se nemění.
- Release: `Vytvořeno: <cesta k .app>` zůstává poslední „Vytvořeno“ řádek, DMG jen z produkční appky.
- Optimalizace: dnes `-Onone`; zůstává.

## 7. Série PR

| # | Větev / titulek | Rozsah | Ověření | Rollback | Odhad |
|---|---|---|---|---|---|
| 1 | `docs/restructure-plan` — docs: restructure plan | tento dokument | review | revert | – |
| 2 | `refactor/source-layout` — refactor: move sources into Sources/ by area | jen `git mv` (100% podobnost), `build.sh` cesty, `localization-keys.py` rekurzivně + kontrola | build.sh, py testy, `git diff -M --stat` | revert | 30 min |
| 3 | `build/swiftpm` — build: build with Swift Package Manager | `Package.swift`, `build.sh` přes `swift build`, `BridgeWire` jako modul (`public`), `.gitignore .build`; testy ještě v binárce | build.sh, py testy, `codesign -dv` porovnání, release kroky lokálně bez publikace | revert | 1 h |
| 4 | `test/test-host` — test: move self-tests out of the app binary | `ScreenshotNoteKit` knihovna + tenký `main.swift`, `ScreenshotNoteTestHost`, `Screenshot Note Tests.app`, `tests/test-inventory.py`, CI, README/CONTRIBUTING | build.sh, inventura, `nm`/`strings` na release binárce, cloud-rest.py s hostem | revert | 1,5 h |
| 5 | `refactor/split-files` — refactor: split large source files | přesuny bloků do nových souborů bez změny obsahu (CloudTests, Interface, CloudLibrary, CloudFolders modely) | build.sh, inventura, diff „jen přesuny“ skriptem | revert | 1 h |
| 6 | volitelně `refactor/cloud-folders-extensions` | rozdělení třídy `CloudFolders` na extension | dtto | revert | 1 h |
| 7 | `docs/restructure-done` — docs: … | README, CONTRIBUTING, DESIGN, LOCALIZATION, docs/PLAN.md, průběh | – | revert | 15 min |

Každý PR: z aktuálního main, nezávislé review agentem, zelené CI (build + CodeQL), squash merge.

## 8. Rizika a zmírnění

- Rozbitý podpis / ztráta přístupu do Klíčenky: podpis se nemění; porovnání `codesign -dv` a `codesign -d -r-` před/po;
  při rozdílu stop, revert, zápis.
- SwiftPM jinak kompiluje (moduly, `-parse-as-library`, varování Swift 6): jazykový režim 5, `-Onone`, porovnání velikosti a symbolů.
- `@testable import` z executable targetu: vyžaduje `-enable-testing` u knihovny; dáno do release configu (jen viditelnost symbolů).
- Release: cesta `Vytvořeno:` a DMG ověřit lokálně (hdiutil bez publikace).
- CodeQL swift: `./build.sh` zůstává vstupem; delší build (dva configy) se vejde do 30 min limitu — ověřit na PR.
- Ztracené testy: inventura (4) jako CI kontrola.
- Konflikty s větvemi browser-context F2+: F2 ještě nezačala; prompty v rozšíření (`docs/MAC-PHASES.md`) odkazují na
  `build.sh` a soubory v kořeni — po restrukturalizaci aktualizovat cesty (krok 7).
- Webový flow test používá `SCREENSHOT_NOTE_NATIVE_TEST_BINARY`: argumenty zůstávají, mění se jen cesta.

## 9. Akceptační kritéria

- `nm`/`strings` na `Screenshot Note.app/Contents/MacOS/ScreenshotNote` nenajde `cloudUnitTests`, `browserBridgeTests`,
  `--self-test`, `PASS:` ani `CloudMemoryVault`.
- `./build.sh` jedním příkazem postaví appku, testovací bundle a spustí stejné sady testů jako dnes.
- CI pokrývá stejně nebo víc (navíc inventura).
- Ruční checklist po `--install`: zachycení oblasti/obrazovky, editor a anotace, uložení poznámky, cloud připojení (token z
  Klíčenky bez nového párování) a sync, týmové složky, sdílení odkazem, browser bridge (helper, manifest), cs/en.

## Mimo rozsah (nalezeno při analýze)

- `BrowserBridge.broadcast` (`BrowserBridge.swift:183`) je jen pro test, ale je v produkční třídě se `private` stavem;
  zůstává (přesun by vyžadoval změnu viditelnosti).
- `tests/cloud-rest.py` neběží v CI (`ci.yml:28`).
- Hardened runtime není zapnutý — patří k notarizaci, ne sem.

## Rozhodnuto v noci

- Testy běží v samostatném testovacím hostu uvnitř `Screenshot Note Tests.app`, ne v XCTest: XCTest by vyžadoval
  injekci `Bundle.main` do produkčního kódu (endpoint, lokalizace, helper), což je změna chování mimo noc.
- App se dál kompiluje s `-Onone` (dnešní stav), i když jde přes `-c release`; přechod na `-O` je otázka pro Jana.
- Rozdělení třídy `CloudFolders` na extension jen pokud zbude čas (krok 6); vyžaduje zrušení `private`.
- Umístění `Assets/`, `Localizations/`, `Info.plist` se nemění.

- Jeden release config: `-Onone -enable-testing` pro `ScreenshotNoteKit` a `BridgeWire` (review nález: testy mají běžet
  proti stejným objektům jako appka; `-enable-testing` nepřidává kód, jen exportuje interní symboly).
- Appka na odstraněné testovací přepínače (`*-self-test`, `--interactive-ui-tests`) vypíše hlášku a skončí kódem 64,
  aby starý skript nespustil appku nebo snímání a neskončil falešným úspěchem (review nález).
- `CloudMemoryVault` je v knihovně, protože ho používá `--design-export` (`DesignPreview.swift:53`).
- `.build/` zůstává v repu (gitignored); `build.sh` dál skládá .app v `$TMPDIR`.
- Testovací bundle sdílí bundle id i UserDefaults doménu s appkou — stejně jako dřív testy v appce; vědomě ponecháno.
- Úprava dokumentace ve webu (`README.md:566`, `docs/CLOUD-BUCKETS.md:86`) a v rozšíření (`docs/MAC-PHASES.md`) zvlášť
  v těch repech.

## Otevřené otázky pro Jana

1. Přejít na `-O` pro release (menší a rychlejší binárka; asserty v produkčním kódu nejsou)?
2. Zavést XCTest/Swift Testing s injekcí `Bundle` (endpoint, lokalizace, helper), aby šlo `swift test`?
3. Hardened runtime a entitlements při notarizaci.
4. Mají `--preview-test` a `--design-export` zůstat v produkční binárce?

## Průběh

- Review plánu nezávislým agentem: 19 nálezů (7 major, 12 minor), zapracované výše (Rozhodnuto v noci, inventura,
  privátní DTO, reference). Mezikrok PR 3 (jeden executable target přes `path: "Sources"` s `exclude`) SwiftPM přijal.
- `#file` v `fatalError` (`Design.swift:20` …) obsahuje u SwiftPM absolutní cestu zdroje (dřív relativní). U release z CI
  je to cesta runneru, žádná citlivá data. `-file-prefix-map` mapuje jen debug info, proto neaplikováno.
- Implementace: #17 přesun zdrojů (`git mv`), #18 SwiftPM, #19 testy mimo binárku, poslední PR rozdělení souborů + dokumentace.
- Odchylky od plánu: PR 5 a 7 sloučené do jednoho PR; od #19 se merguje po zeleném `build` s admin bypassem a CodeQL
  běží jednou nad main na konci (Janovo rozhodnutí 2026-11-21 kvůli 20min CodeQL na každém PR).
- Review stacku: smoke test produkční binárky v build.sh, `withExtendedLifetime` pro delegáta, řádkové bufferování
  testového hostu, `-gnone`, `BridgeWire` bez `-enable-testing`, retry dry-run DMG. `BrowserBridge.broadcast` zůstává
  v knihovně (přesun by uvolnil `private` u tří členů produkční třídy). Testovací bundle má dál stejné bundle id.
- Krok 6 (rozdělení třídy `CloudFolders` na extension) neproveden; zůstává doporučením.
