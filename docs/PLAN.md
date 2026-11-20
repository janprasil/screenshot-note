# Kopírovat odkaz — fáze 2 kolaborace (20. 11. 2026)

- Stav: hotovo ve větvi `feat/collab-p2-copy-link` (nepushnuto). Tlačítko „Kopírovat odkaz“
  vedle konfigurace v okně poznámky, jen u relace v cloudové složce aktuálního účtu, kterou
  server má (stažená relace z indexu, nebo účtenka `isCommitted`). `POST /api/v1/sessions/{id}/share`
  s `{audience:"public"}` a device bearerem, URL `<origin>/s/<token>` do schránky, 2 s
  potvrzení „Odkaz zkopírován“. Vlastní hlášky pro 403/404/409 `session_trashed`/413/5xx/ostatní;
  429 blokuje další pokus do `Retry-After` (bez hlavičky 30 s), zámek je vázaný na účet a origin.
  Relace vedená indexem v koši/smazaná se nesdílí ani s účtenkou. Schránka se zapíše i po zavření okna.
  URL jen `/s/sn_share_v1_<43>` na stejném originu (normalizované schéma/host/port).
  Review opravy (2. commit): rozložení řádku bez překryvu ověřené v self-testu.
- Ověřeno: `./build.sh` (self-testy + lokalizace), `tests/cloud-rest.py` (share 201/200,
  stejná URL, bearer, pojmenovaná schránka, chyby, cizí origin URL odmítnut).
  Opraven i dříve padající `cloud-rest.py` (upload bez cloudové složky po zavedení `folder_required`).
- Neověřeno: proti skutečnému web serveru (paralelní větev `feat/collab-p2-sharing`),
  vizuální render tlačítka v `--design-export` (vyžaduje připojený účet), VoiceOver.
- Otevřené: URL přijímáme jen na stejném originu jako API; pokud web bude mít jiný veřejný
  origin pro `/s/`, je třeba upravit `CloudLibrary.shareURL`. Odvolání odkazu z Macu je další fáze.

# Týmové složky a sdílení — kontrakt (20. 11. 2026)

- Fáze 1 kolaborace, větev `feat/collab-docs`, jen dokumentace: týmové složky
  s předponou názvu týmu („<Tým> · <Složka>“) v [LOCAL-CLOUD-FOLDERS.md](LOCAL-CLOUD-FOLDERS.md#team-folders),
  `/me` libraries, upload do týmové složky a „Kopírovat odkaz“ v [CLOUD-REST.md](CLOUD-REST.md).
  Serverový model ve web repu (`docs/TEAMS.md`, `docs/SHARING.md`, `docs/PLAN.md`).
- Mac implementace: „Kopírovat odkaz“ ve fázi 2, týmové složky a stav `unavailable`
  ve fázi 6. Lokální soubory se při ztrátě členství nikdy nemažou.

# Lokální a cloudové složky + Spaces (19. 11. 2026)

- PR5 standardně merged; main/origin/main před lokální výměnou
  `cb8646bf0fa83c914466b563712a08fd84c49422`. Jan potvrdil ukončení aplikace;
  absence procesu znovu ověřená i bezprostředně před výměnou. Instalovaný local
  build 4yenGS v `~/Applications/Screenshot Note.app`: podpis, bundle ID,
  localhost5173 origin a shoda SHA256 binárky s ověřeným buildem passed.
  Původní bundle i ZIP jsou v `~/Library/Application Support/Screenshot Note/App Updates/20261119-123045`;
  podpis a původní hash zachované kopie ověřené.
  Nový běžící proces z instalované cesty a localhost web HTTP200 potvrzené.
  Keychain, drafty ani nastavení se instalační operací neměnily. Skutečný
  Spaces/full-screen smoke zůstává uživatelská akceptace; cílová cloudová
  migrace a aktivace složek/uploadu touto výměnou neproběhly.

- Výchozí čistý main/origin/main `9fe8fcb5bf1969e5a7c60cb11fd4c31a995d9920`, PR4
  standardně merged. Větev `feat/local-cloud-folders` realizuje Janovo rozdělení:
  lokální export a cloudový katalog s místním přiřazením na každém Macu.
  Potvrzené je i stahování existujících poznámek a nových poznámek jiných Maců.
- [Implementace, exportní struktura a hranice](LOCAL-CLOUD-FOLDERS.md). Owner/origin
  cache, optional místní cíl, kontrola kolizí včetně symlinků/missing suffix/case,
  atomic publish, receipt dedupe a ochrana lokálních úprav. Katalog nepřenáší cesty.
  Nové lokální volby nepoužívají staré cloud přepínače; původní uložené fronty
  a frozen drafty se nepřepisují ani neposílají pod jiným účtem.
- Spaces: floating panely nově canJoinAllSpaces + fullScreenAuxiliary +
  canJoinAllApplications dle instalovaných AppKit SDK headers. Offscreen aserce
  passed; skutečné přepínání Mission Control/full-screen čeká na installed smoke.
- Finální build 4yenGS, podpis a celá defaultní neinteraktivní regrese passed. Nativní
  původní REST wire test s cEMoxQ také passed. Izolovaný actual Next/Auth/DB/Storage1.95
  průchod s CVPZRA a následně samostatným web worktree/cEMoxQ passed, vlastní
  fixture/role/stack/volumes uklizené, původní containerIDs zachované.
  Async cancellation používá injektovaný transport; actual native→Next download
  je skutečný. Původní cloud1.96.4 acceptance tím není nahrazený.
- cs/dark lokální a en/light cloudové nastavení vizuálně ověřené v
  `/tmp/sn-folders-nov19`. Dvě časné review P2 opravené: stale mapping po await
  a dvojí lokální kopie. Finální nezávislé review bez dalších P1/P2.
- Cloudové schéma/API jsou ve vlastním web worktree `feat/cloud-folder-sync`,
  protože původní web souběžně upravuje jiné vlákno. Nezahrnovat/nemazat jeho WIP.
  Nový cloud flag zůstává false, cílová migrace/aktivace neproběhly.
  Zdrojové PR5 a web PR41 standardně merged; následná lokální výměna je doložená
  výše. Pokračovací prompt až po uzavření tématu.

# Aktuálně — snímání a cloudové členění (19. 11. 2026)

- Výchozí main/origin/main `9c9e402d4d6532bbdfd7bc12d70a0ed9e72c2793`.
  Rozpracovaná oprava odstraňuje viditelný výběr relace a tlačítko Pokračovat
  v relaci z composeru. Samostatné menu pro otevření uložené relace zůstává.
- Zkratky při otevřeném composeru používají stejné sbalení/skrytí před capture
  jako Přidat výřez/snímek. Přibyl lokální panelový key monitor s přesným matchingem,
  ochranou recorderu a společným debounce s Carbon cestou.
- Local build EhsBh4, podpis a celá defaultní neinteraktivní regrese passed.
  Nové kontroly ověřují skutečně sestavený offscreen composer bez obou ovládacích
  prvků, shortcut matching a debounce. Preview cs/dark a en/light vizuálně ověřené
  v `/tmp/sn-capture-nov19`. Nejde o skutečné snímání uživatelovy plochy ani
  novou Mac→cloud upload akceptaci. Instalovaná aplikace se zatím nemění.
- Jan upřesnil: kategorie lokálně, buckety na webu, společný účet na více Macích.
  Lokální přejmenování na buckety ani změna výchozího uploadu nejsou implementované.
  Pracovní návrh je ve web repo `docs/CLOUD-BUCKETS.md`; rozsah stahování obsahu
  a vztah cloudových změn k lokálním Markdown exportům čeká na rozhodnutí.
- Nezávislé i finální review nových testů a dokumentace bez P1/P2; syntaxe webového
  testu a diffcheck obou repozitářů passed. Následuje commit/PR/checks/standard merge.

# Aktuálně — pevný server podle buildu (18. 11. 2026)

- PR #2 standardně merged, main/origin/main `0a36a3e8d123b0568b38623fb9b0047ede7670db`.
  Navazující build validace odmítá percent-encoded hostname aliasy; Python regrese
  a diffcheck prošly. Změna nemění aktuální localhost build ani jeho instalaci.
- Výchozí čistý main/origin/main `de6ff2d55b54344c68b96397f90c720e493e74c0`,
  PR #1 standardně merged. Jan následně autorizoval lokální výměnu aplikace:
  nový proces ověřený v ~/Applications, původní bundle i ZIP zachované v
  ~/Library/Application Support/Screenshot Note/App Updates/20261118-194413.
- Větev `feat/build-cloud-origin`: odstraněné editovatelné pole adresy i čtení/zápis
  cloudWebURL. Build-time SCREENSHOT_NOTE_ENV local/test/production a volitelný
  SCREENSHOT_NOTE_WEB_ORIGIN zapisují origin před podpisem do Info.plist.
  Production pevně screenshotnote.com, local pouze HTTP loopback (default5173),
  test vyžaduje explicitní neprodukční HTTPS. Neznámé prostředí a vadné URL odmítnuté.
- Credential se načte jen pro shodný build origin; nové local/test Keychain služby
  oddělené podle originu, původní produkční služba zachovaná. Outbox owner/origin
  vazby se nemění, staré fronty ani Keychain se nemažou. UI uživatel server nevolí.
- Web spuštěný pouze na loopback localhost5173, s dosavadním cloudovým vývojovým
  Auth/DB a explicitně vypnutými billing/pairing/writes/legal flags. Bez cílových
  migrací/aktivace a zásahu do stávajících Docker stacků. Nejde o plnou lokální
  Mac→Next pairing/upload akceptaci ani produkční rollout.
- Ověření: Python buildconfig2testy passed; local build/signature a celá defaultní
  neinteraktivní regrese passed. Finální qATa1B build prošel reálným native REST
  loopback testem, offscreen cs-dark preview bez pole vizuálně ověřené.
  Nezávislé review nalezlo IPv6 mismatch a produkční trailing-dot alias; opravené
  validací + regresí, finální re-review bez dalšíchP1/P2, diffcheckpassed.
- Po Janově bezpečném ukončení instalován local build do ~/Applications,
  podpis/hash a nový běžící proces ověřené. Backup bundle/ZIP v App Updates/
  20261118-200057. Není to distribuční release. PR/merge se doplní níže.
- Web authenticated Library/Storage odhalil nesoulad nového kódu se starým
  clouddev schématem (transport/inventory). Spouští se samostatný nový lokální
  backend a cílené E2E; cloud migrace se neaplikují. Jan nově autorizoval testovací
  platby jen na tomto lokálu přes BO Test, nikoli produkční rollout.

# Screenshot Note Mac — stav implementace

Aktualizováno 18. 11. 2026. Výchozí čistý main/origin/main
`863261f3a7b52ca7d09d1441ee7183545473f5e7`. Jan výslovně autorizoval úpravy Macu
po webových souhlasech. Web PR32 je standardně merged, čistý main
`41d8ab5abf4ab9389798fdab0b984d7b76b0cb54`; žádný deploy/aktivace/migrace.

## REST/device klient — větev feat/rest-device-cloud

- Přímý Supabase login/Storage/PostgREST nahrazen vlastním `/api/v1` klientem.
  Web pairing, comparison code, Keychain před browserem, obnova pending/active,
  `/me` identity, cancel pending a vysvětlené local forget vs server revoke.
- Verzovaný immutable outbox: owner+origin binding, stabilní UUID, bytes/SHA256,
  serverový canonical digest pin před uploadem, stream PNG, potvrzené indexy,
  commit/retry bez duplikování a mazání lokální kopie pouze po shodném commitu.
  Retry-After/cooldown/90s incomplete; stará a nečitelná fronta zůstává lokálně.
- Cloud kopie sRGB RGB/RGBA8 non-interlaced, critical PNG chunks; lokální export
  se nepřepisuje. Cloud-only používá převedenou kopii. Nejde o obecnou HDR/ICC
  akceptaci. Nativní čeština/angličtina a stávající vzhled zachované.
- Nezávislé review našlo poškozený valid-JSON manifest a enqueue během přenosu.
  Doplněná validace načteného jobu a čerstvé čtení fronty po každém dokončení;
  cílené testy ověřují zachování poškozeného jobu a enqueue do běžícího drainu.
- Build/signature a defaultní neinteraktivní regrese prošly. Reálný native→loopback
  REST wire test prošel pro pairing/restart, owner a streamed PNG, CRC/hash,
  ztrátu odpovědí manifest/image/commit a account switch; rozšíření o souběžný enqueue do aktivního drainu, cancel pending a Retry-After60
  bez předčasného requestu také exit0. Finální build: screenshot-note-build.zq6j8E v systémovém TMPDIR. Test vault je paměťový, nikoli reálný
  Keychain. Preview `/tmp/sn-mac-rest-previews/`, en/light+cs/dark vizuálně ověřené.
- [Transport, kontrakty, migrace fronty a omezení](CLOUD-REST.md). Skutečný Keychain
  prompt/install upgrade, nový Mac proti skutečnému Next/Auth/pairingu, velké a
  HDR/color screenshoty zbývají k akceptaci. Neměnit tím stav cloudových flagů.
- Finální nezávislé re-review bez dalšíchP1/P2; diffcheck prošel. Před dokončením: secret check,
  commit --no-gpg-sign, push/PR/checks/standard merge. Nevydávat installer ani
  nenasazovat web. BO a ostatní sousední repozitáře pouze číst.

## Další krok

Společná akceptace Mac+web+nové API na odděleném lokálním prostředí, následně
uzavření právního obsahu a provozního rollout plánu. Produkční flags zůstávají
vypnuté. Cílová DB/Storage/PNG/cleanup/ingress/billing kompatibilita, právní
publikace, nasazení a vydání vyžadují samostatné zadání. Pokračovací prompt až po
kompletním uzavření právě řešeného tématu, ne po jednotlivé odpovědi.
