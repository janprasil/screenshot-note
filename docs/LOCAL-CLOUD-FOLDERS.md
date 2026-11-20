# Local and cloud folders

Local folders keep this Mac’s Markdown template, directory and export settings.
Cloud folders are owned by the web account and identified by UUID. The app loads
the catalog after connecting and approximately every minute. Each Mac can assign
its own optional download directory; filesystem paths are never sent upstream.

The catalog and mappings persist in `Cloud Folders.json` next to the draft root,
bound to owner and origin. Forgetting a connection hides that account’s catalog
without deleting files or mappings. Inactive mappings still reserve their local
directories. Existing configuration storage and old outbox jobs are preserved;
configuration choices are projected as local folders, while frozen legacy drafts
and jobs retain their previous transport semantics until explicitly handled.

Directory validation runs before configuration persistence, local export and
cloud publication. It compares canonical paths and existing filesystem identity,
resolves symlinks component by component including missing descendants, and
handles case according to the volume. Two local/cloud entries cannot share a
directory. Different nested directories are allowed. Invalid or unreadable
mapping state is preserved and cannot be silently replaced.

A cloud save queues the owner-bound immutable manifest, including folder UUID.
There is one local materialization path: the downloader. After upload confirmation
it downloads into `YYYY-MM-DD Title/YYYY-MM-DD Title.md` and `assets/1.png…`
(local date of `created_at`, sanitised, deduplicated with ` 2`). Combined mode
writes the combined file with images `assets/YYYY-MM-DD Title-N.png`. Renaming a
session on the web does not rename existing folders. Markdown has no hidden markers.

Identity lives in `Session Index.json` in Application Support (0600, bounded):
path → session ID, `updated_at`, file fingerprints and, for combined files, block
ranges and headings. The xattr `cz.janprasil.screenshotnote.session` on folders and
Markdown is a secondary hint; edited blocks are found by heading and image links.
Unknown files are never modified or deleted. The same index serves local folders.
Older `<uuid>/Note.md`, `<uuid>-<fingerprint>` and `assets/<uuid>/N.png` downloads
are renamed once when unmodified; edited ones stay where they are.

Trash: a session trashed on the web moves to `<dir>/.trash/` (in combined mode its
block leaves the combined file and becomes `.trash/YYYY-MM-DD Title.md` with images
in `.trash/assets/`), but only when unmodified; otherwise it stays with one notice.
Moving it back out of `.trash/` calls `POST /restore`; a web restore moves it back;
a purged session (detail 404) is removed from `.trash/` only when unmodified. Only
entries known to the index are touched, so Obsidian's own `.trash` coexists.
Without the server trash API the downloader falls back to the previous behaviour.

Local deletion propagates to the web Trash (`POST /trash`): moving a session into
`.trash/` is sent after one scan; deleting it (Finder, rm) after two scans at least
10 s apart in which it is missing from the whole mapped tree (xattr, volume+inode,
fingerprint). Renames and moves inside the folder only update the index. In combined
mode a removed block is trashed; a deleted combined file is just regenerated.
Nothing propagates when the root is missing, unreadable or replaced, or while the
session has unsent uploads. More than 5 sessions or over half of the folder at once
are held until confirmed under Cloud Library → Missing sessions. Nothing local is
deleted by this.

Downloads use only our REST API and device credential. JSON is bounded, image
responses are limited to 50 MiB and a note to 100 MB / 30 images. The account and
current mapping are rechecked after awaited image reads and before publication.
A prepared hidden directory is moved into place only when complete.
Local Markdown edits are retained and do not propagate upstream. When a newer
server version arrives for an edited copy, it goes into a new readable folder.

## Team folders

Approved contract (20 Nov 2026), not implemented yet. Server model in the web repo
`docs/TEAMS.md`. There is no workspace switch: team folders appear next to
personal ones.

- **Name.** A team folder is always shown with the team prefix first, `<Team> · <Folder>`
  (e.g. „Tým · Bugy“), plus a team icon, in the picker, Settings and notices. The
  order is fixed in both languages; the format is one localization key `%@ · %@`
  (team, folder) in cs and en. The local directory name is chosen by the user and
  is not prefixed.
- **Records.** `CloudFolderRecord.owner` becomes the library UUID (user UUID for
  personal, team UUID for team) and gains `account` = the signed-in user UUID.
  Old records decode with `account = owner`. Records are matched by
  `(origin, account, owner, folder id)`; `topics` returns personal and team
  records of the active account. Topic IDs stay `cloud:<origin>:<owner>:<folder>`.
  `accept()` allows owner ∈ {user id, team ids from `/me` libraries}. The topic ID
  omits the account because only the active account's records are ever loaded;
  the account field only separates mappings of two users on one Mac.
- **First appearance.** A new team folder goes through the same flow as a new
  personal cloud folder: choose a local directory or keep it cloud only.
- **Per-device mapping.** Each member's Mac maps the folder to its own directory;
  paths are never sent upstream and the existing collision rules apply across
  personal and team entries. Two members download the same notes from all authors.
- **Permissions.** Rename, template and trash of a team folder are offered only for
  owner/admin roles from the catalog. Local deletion propagates `POST /trash` only
  for notes the user authored (or any note for admins); otherwise the local
  deletion stays local and one notice explains it (server handling of
  `role_forbidden` is in [CLOUD-REST.md](CLOUD-REST.md#teams-and-share-links-approved-contract-20-nov-2026)).
- **Unavailable.** When a team disappears from `/me` (left, removed, team deleted)
  its records get `unavailable = true` and are hidden from topics, the picker,
  `deletedRemotely` and sync. This is distinct from `remoteDeleted`. Download,
  trash propagation and missing-session detection stop for those folders, so no
  local change is inferred. Local directories and files are **never** deleted or
  moved; mappings are kept and still reserve their directories. Draft topics
  pointing to a hidden folder fall back to the default topic with a notice.
- **Return.** When the same team reappears, `unavailable` is cleared and the old
  mapping and session index are reused; downloading resumes without duplicates.
- **Author.** See `{author}` in CLOUD-REST.md; combined mode works unchanged.

## Validation

`./build.sh` checks filesystem aliases, missing descendants, local/cloud and
cross-account collisions, catalog rename persistence and account switching,
alongside the existing capture/annotation/export regressions.
`--folder-sync-self-test` checks asynchronous disconnect/mapping cancellation
using an injected transport. With loopback test URL/token/owner variables it
also exercises the real Next catalog and PNG/Markdown download. The web’s
`npm run test:folders` owns that isolated integration environment and native
process; it creates no cloud Auth user or email.

Panels use AppKit `canJoinAllSpaces`, `fullScreenAuxiliary` and
`canJoinAllApplications`, with floating level and hidesOnDeactivate=false.
SDK headers and offscreen property regressions cover the configuration; actual
Mission Control and third-party full-screen switching still need an installed
app smoke test. No user desktop capture is performed by default regressions.

Server `CLOUD_FOLDERS_ENABLED` defaults false. The migration and cloud upload
acceptance must be completed before enabling it on the original cloud project.
This source change does not deploy or activate the backend.
