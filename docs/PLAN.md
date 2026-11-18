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
