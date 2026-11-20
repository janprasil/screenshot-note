# Native cloud transport

The client uses only the configured Screenshot Note web origin and `/api/v1`.
The production origin is fixed at build time to `https://screenshotnote.com`; this is a configured domain,
not evidence that production pairing/uploads are enabled. There is no Supabase
project URL/key, password login, Auth refresh token or direct Storage request.
The server remains responsible for Auth, ownership, billing and Storage access.

## Pairing and credentials

Cloud Library starts a pairing with the Mac's device name. The returned native
credential is saved in the non-synchronizing Keychain item
`cz.janprasil.screenshotnote.device.v1` / `current` before the browser can open.
The browser URL must equal the build origin's `/pair-device/{id}` and never
contains the token. The dialog displays the comparison code and asks the user
to check both code and account. Pending status is polled no faster than five
seconds, with Retry-After/backoff on errors. Closing the window stops polling;
reopening resumes the saved pending credential. Active credentials have no
client refresh or hidden renewal. An active Mac re-checks its pairing state at
most every 15 minutes; a 401, `revoked`/`expired` state or a past `expires_at`
switches the UI to Reconnect (queue and cloud folders are kept). Folder refresh
backs off exponentially and honours Retry-After.

Once active, `/me` supplies the owner UUID and display email; an existing owner
binding cannot silently change. Every upload drain checks `/me` again. A
credential, display email and pairing metadata live in Keychain, never in
UserDefaults, outbox JSON, browser URLs or logs. The signed bundle stores the build origin. The UI has no server address field;
old `cloudWebURL` preferences and runtime environment variables are ignored.
Local/test builds use origin-specific Keychain services; production retains the
existing service. A stored credential for another origin is never loaded.
See the README for build-time local/test configuration. Cookies, caches and redirects are disabled in the native transport.
JSON responses are bounded (16 MiB for session list/detail/PATCH, 32 MiB for the
folder list, 512 KiB elsewhere); PNG request bodies stream from local files.
Image uploads/downloads use a separate URLSession with a 4 h resource timeout
and a 70 s idle timeout; JSON calls keep the 75 s resource limit.

Cancel pairing calls the pending DELETE endpoint. Forget connection removes
only this Mac's Keychain item and leaves all queued data; it does **not** claim
to revoke an active server device. Use web Settings to revoke that device.
The UI explains the distinction. A failed Keychain write leaves the in-memory
connection unchanged. A lost initial pairing response leaves an expiring server
pending request; no secret is recovered from the web.

## Outbox and PNG

New `schemaVersion=1` jobs bind the exact origin, owner UUID, stable session UUID,
frozen manifest and per-image bytes/SHA256. No credential is stored in jobs.
Files are staged privately and the complete directory is moved into the queue
before a draft may be cleared. Metadata limits match the current server contract:
1–30 images, 50 MiB/image, 100,000,000 bytes/job and bounded title/text/captions.
Local-only sessions retain their existing unlimited image workflow.

The cloud copy is explicitly rendered to non-interlaced sRGB RGB/RGBA8 PNG and
stripped to IHDR/IDAT/IEND. This satisfies the narrow server PNG profile rather
than claiming general HDR/ICC/16-bit preservation. Existing local exports are
not rewritten. Cloud-only output uses the converted copy; color/HDR fidelity
still needs representative Mac/display acceptance before release.

PUT the same manifest/UUID on every retry. The first successful manifest reply
pins the server's canonical `manifest_digest` durably before sending images.
This digest is server-generated; the native client independently hashes image
bytes, not the server's canonical JSON format. Confirmed indices are skipped on
resume. PNG and commit failures retain the same job and ID. Only `committed`
with the matching UUID, pinned digest and complete index set permits removal.
A lost commit reply is resolved by the repeated immutable manifest request.
No timeout invents another session ID. HTTP429 honors Retry-After; temporary
errors use bounded cooldown/jitter and manual retry. `upload_incomplete` waits
at least 90 seconds. A failing job never blocks later jobs: each job keeps its
own failure count and backoff (`.failures.json`). 401/402/403/429, account
quota (402 and 413 `billing_storage_limit`, 15 min backoff, then automatic
retry) and loss of connectivity
stop the whole drain. 413 `resource_limit` (request too large) parks
the job or edit at once. After three permanent failures (400, 415, invalid
response) or five timeouts the job is parked in `.conflicts/` with a
`reason.txt`. Extensions send the downloaded session `revision`; on
`session_changed` the client re-fetches the session, 3-way merges title,
comment and captions (base = downloaded text) and retries with the new
revision, parking only on a same-field conflict. Text edits without a stored
revision fetch it before PATCH; 400 and 413 `resource_limit` park the edit, a full account waits like uploads.

Parked items and queue entries of another account (or after Disconnect) are
listed under Cloud Library → Set Aside… and in the menu bar. Each offers Try
Again (own account only), Save Locally (writes Markdown + PNGs into a chosen
folder) and Discard (macOS Trash).
The drain rereads the queue after each completion, including notes added while
an earlier request is in flight.

Jobs are validated again when read (bounded JSON, count/index/hash/size/text
limits). Invalid or unknown items remain on disk and are not uploaded. Older
Supabase `job.json` items remain untouched in Cloud Outbox and are identified
in the dialog; there is no implicit conversion or replay under another account.
Their previous public project settings are ignored. Recovery/migration of an
old queue requires a separate explicit owner/project mapping and user decision.
Switching to a different account/origin never drains the previous account's jobs.

## Teams and share links (approved contract, 20 Nov 2026)

Team folders are implemented in phase 6 (copy link in phase 2). The server side is
described in the web repo (`docs/TEAMS.md`, `docs/SHARING.md`, `docs/API-V1.md`). All
new fields are additive and behind server flags `TEAMS_ENABLED` / `SHARING_ENABLED`
(default false); with them off the client behaves as before (personal only).

- `/me` adds `libraries: [{id, kind, name, role}]`. The personal library has
  `id` = user UUID. `CloudOwner` decodes it; a missing field means personal only.
  The folder refresh reads `/me` on every pass (team loss is detected there).
- The account binding stays the **user**: Keychain credential, `requireAccount`,
  outbox `schemaVersion=1` jobs and commit receipts keep the user owner UUID. A team
  is never an account; the device credential reaches team data through membership.
- `/folders` returns personal and team folders, each with `owner_id`, `owner_kind`,
  `owner_name` and the caller's `role`; all optional (missing = personal). Team folder
  session lists send `library_id`. Local folder handling is in
  [LOCAL-CLOUD-FOLDERS.md](LOCAL-CLOUD-FOLDERS.md#team-folders).
- Uploads keep the same manifest. The server derives the session owner from
  `folder_id`, so a team folder upload is billed to the team and authored by the
  user. Plan/capacity errors (402/413) of a team folder are prefixed with the folder's
  `<Team> · <Folder>` name.
- Losing membership makes the folder return `404 not_found` on manifest, image or
  commit. The job is retained with a visible error naming the folder; it is never
  dropped, retried in a loop or sent to another folder silently. The user can retry
  after rejoining or discard the job explicitly. `403 role_forbidden` (for example
  appending to another member's note) is shown and not retried.
  Implementation (unified with the parked items from #12): in a team folder a `404`
  (lost membership, also for additions) or any `403 role_forbidden` parks the job in
  `.conflicts/` with a `reason.txt` naming the folder (`<Team> · <Folder>`). It is
  checked before the generic classification, so this `403` never stops the whole
  drain. The job shows up under Set Aside… (Try Again after rejoining, Save Locally,
  Discard to the macOS Trash) and is never retried automatically. There is no
  separate blocked state. A 404 in a personal folder keeps the #12 behaviour (new
  upload: per-job backoff; addition: parked).
- Text edits (`PATCH`) of another member's note are not sent for a member: the edit
  stays in the local file with one notice, and adding screenshots to such a note is
  refused before queueing (author from `author.id`, unknown author = foreign). A
  server `403 role_forbidden` on `PATCH` parks the edit once and keeps the local text.
- `403 role_forbidden` maps to its own transport message instead of the device
  access message; sharing shows „In a team folder you can only share your own
  sessions“.
- Sessions carry `author: {id, name}` in the summary and detail. The template
  variable `{author}` (single braces, like `{title}`) renders the name, empty when
  unknown. Built-in templates do not include it, so older app versions never print
  it literally; the template editor hint lists it.

### Copy link

A committed cloud session (`cloudSessionID`, `isCommitted`) gets a button next to the
session link, localization key „Kopírovat odkaz“ (en “Copy link”). It calls
`POST /api/v1/sessions/{id}/share` (default audience `public`; `team` for team folders
only after the server's team-audience phase) and puts `url` on `NSPasteboard`.
Repeated calls return the same URL. Requires a `library:write` device; `403`, `404`
and `409 session_trashed` show an error, `429` honors `Retry-After`. Revocation lives
on the web and in a later Mac menu (`DELETE …/share/{link_id}`). Shared links and
other people's shared content are never listed or downloaded by the Mac app.
The button is shown only for a session in a cloud folder of the current account that the
server already holds (downloaded index record or local commit receipt) and that the session
index does not mark as trashed or locally deleted. The returned `url` must be
`/s/sn_share_v1_<43 base64url>` on the API origin (scheme, case-insensitive host, effective
port); anything else is rejected. Share errors have their own messages (403, 404, 409
`session_trashed`, 413 link limit, 429, 5xx/temporary, other HTTP). Without `Retry-After`,
a `429` waits 30 s; during the wait no request is sent, and the wait is tied to the
account/origin. Network errors only show a message.
Strings are localized cs+en (`tests/localization-keys.py`). `tests/cloud-rest.py`
covers the share endpoint (phase 2) and, since phase 6, `/me` libraries, a team
folder with owner fields, `library_id`, `author`, team loss (hidden folder, upload
parked after one 404) and rejoin.

## Validation and remaining acceptance

`./build.sh` compiles for macOS13+, verifies its local signature and runs default
noninteractive regressions, including endpoint/token checks, image conversion,
owner isolation, malformed/legacy queue preservation and vault failure atomicity.
No production Keychain entry or cloud account is used by these tests.

```sh
python3 tests/cloud-rest.py '/path/to/Screenshot Note.app/Contents/MacOS/ScreenshotNote'
```

This starts an owned loopback HTTP fixture and the actual compiled native client.
It verifies pairing/vault/restart wiring, identity, streaming RGB8 PNG CRC/hash,
lost manifest/image/commit responses, stable IDs/digests, drain concurrency,
cancellation, cooldown and account switching. The fixture simulates web approval;
it does not prove an external provider/browser or production server acceptance.
All fixture data and processes are owned and removed; no existing stack restarts.
The vault in tests is in memory. Actual macOS Keychain authorization/access,
installed-app upgrades, native→Next integration, representative large/HDR/color
images and production network failures remain release acceptance work.

Design export includes native Cloud Library pending screens in Czech/English and
light/dark using synthetic data, without a live credential or network calls.
This change builds source only: no installer publication, application install,
production deploy, target migrations or backend feature activation.
