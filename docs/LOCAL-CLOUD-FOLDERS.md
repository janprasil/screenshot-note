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
