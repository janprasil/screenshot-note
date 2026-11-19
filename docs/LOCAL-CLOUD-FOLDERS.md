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
it downloads into `<session UUID>/Note.md` and `assets/1.png…` inside the chosen
directory. Offline saves stay in the durable outbox until the server confirms
them. The periodic refresh retries pending uploads using the existing backoff. Existing cloud notes and notes from other Macs use the same download path.

Downloads use only our REST API and device credential. JSON is bounded, image
responses are limited to 50 MiB and a note to 100 MB / 30 images. The account and
current mapping are rechecked after awaited image reads and before publication.
A prepared hidden directory is moved into place only when complete. Receipts
prevent repeated downloads; the server ID and content fingerprint prevent
unintended overwrites after crashes or manual edits.

Local Markdown edits are retained and do not propagate upstream. When a fresh
copy is needed and files conflict, a separate fingerprinted directory is used.
If that directory also contains different files, the app reports a conflict.
Cloud deletion does not delete already exported local files. Cloud-folder
deletion and bidirectional content editing are outside this first contract.

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
