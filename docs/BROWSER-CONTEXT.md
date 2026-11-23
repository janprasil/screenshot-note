# Browser context in the Mac app

How the app stores, syncs and shows the browser context from the Screenshot Note Context Chrome extension. The wire protocol and bundle format are in the extension repository: `docs/PROTOCOL.md` in `screenshot-note-chrome-extension`.

## Storage

```text
assets/
  Bug_1.png
  Bug_1.context.json   ← bundle without HAR
  Bug_1.har
```

- In the draft's working folder the context sits next to the image as `<image>.png.context.json` and `<image>.png.har` (0600). `Draft.contexts` maps image → context file (optional field).
- The name in `assets/` must be free for `.png`, `.context.json` and `.har` (collisions as for PNG: `Name-1 2`). The session index carries hashes of all three files. Reopening finds the context by the image name.
- Context is exported only into a folder whose current settings have it switched on.
- "Remove context" in the composer deletes the files in the draft. For a reopened session the draft remembers the original name (`Draft.removedContexts`), and `assets/<name>.context.json` and `.har` are deleted only after the Markdown is written.
- Markdown gets the placeholder `{context}` (summary: one `- Screenshot N: …` line per screenshot with context). The default template does not use it. An image in `{screenshots}` gets a collapsible callout under its note (page texts only in inline code, without backticks or line breaks; labels are localized):

```markdown
> [!bug]- Context: `https://app.example.com/orders` (2 errors, 1 failed request)
> - `POST /api/orders` → 500
> - `TypeError: Cannot read properties of undefined (reading 'id')`
> - [HAR](<assets/Bug_1.har>) · [console](<assets/Bug_1.context.json>)
```

  A reduced bundle adds a line such as `Reduced for size: no bodies, N requests…`. Counts in the title come from `summary` (full data). When a saved session is read, the callout is removed from the image caption and generated again from the files in `assets/`.

## Cloud

- A cloud folder's context policy applies only on this Mac (`CloudContextPolicies` in UserDefaults). It is off by default and switching it on shows a warning.
- A queued job carries `attachments: [{index, kind: "context"|"har", bytes, sha256}]` only for new screenshots. The files `<index>.context.json` and `<index>.har` sit next to the PNG in the job. The attachment cap is 16 MiB.
- Context captured for another folder is trimmed to the target folder's policy. If the bundle's `policy` lacks the folder's own `redactHeaders` and `redactQueryParams`, neither the context nor the HAR is uploaded.
- Upload: after the session commit, `PUT /api/v1/sessions/{id}/attachments/{index}/{kind}` (`x-bytes`, `x-sha256`). A retried job sends the attachments again; the server only confirms an identical hash.
- Session detail lists `attachments: [{kind, bytes, sha256, path}]` per image. The Mac stores an empty list as nil, so fingerprints of older sessions do not change.
- Folder sync writes attachments to `assets/<name>.context.json` and `.har` (0600) and their hashes into the session index. A removed attachment is deleted only when it came from the cloud.
- "Remove context" on a reopened cloud session queues a `DELETE` of the attachments (`.attachment-removals` queue), sent after the session is complete.
- Element lines in the cloud carry the selector and element text only for screenshots with context.
- Web: the callout under the screenshot and the HAR and console downloads are visible only to members of the session's library. Share links do not show attachments. MCP: `browser_context.summary` in `get_session` and the `get_browser_context` tool.
- Attachments are not encrypted yet.

## Element map on the screenshot

The mapping formula from extension geometry to screen points is in the extension's `docs/PROTOCOL.md`. App specifics:

- The app stores the capture rectangle in `<image>.context.json` under the key `capture` (any `capture` key from the extension is dropped): `{rect, backingScale, imageScale, browserScale?, window?, webAreas?}`. `rect`, `window` and `webAreas` are global points with the origin top left; `imageScale` is image pixels per point. This reveals the display layout and window position, and goes into exports with context.
- Only full-screen captures (`-m`, `-D n`) with the element map switched on have it. Area selection (`-i`) does not know the rectangle, so its context has no `capture` and the map is not used. With `-D`, `capture` is not saved when another display has the same size (the `-D` order is undocumented).
- `webAreas`: `AXWebArea` candidates with an `http(s)`, `file` or `about` address (not DevTools, side panels or internal pages), searched in the background for at most 0.3 s. The one whose size matches `innerWidth/innerHeight * zoom` wins. The query can switch on Accessibility support in Chrome until it quits.
- When the app knows the browser window from WindowServer (`capture.window`), it uses `contentLeft = window.x`, `contentTop = window.maxY - innerHeight * zoom` instead of `screenX` and `outerHeight`. When `innerWidth * zoom` differs from the window width (DevTools or a side panel), there is no map without an exact `webAreas` match.
- Debugging: `defaults write cz.janprasil.screenshotnote BrowserContextDebugElements -bool true` saves a copy of the screenshot with element rectangles to `$TMPDIR/ScreenshotNote-elements/` (0700, cleaned after a day) and logs the path (`Browser bridge element map`). Test page: `docs/test-pages/element-map.html` in the extension repository.
- Hit test in the editor: a click selects the smallest element containing the point (deeper on an equal rectangle). Clicking the selection again or holding `⌥` moves to the parent (contains it and has a smaller depth or larger area). Hover highlights the outline, Esc cancels. The tool is available only for an image whose size matches `capture` (`rect * imageScale`).
- An `element` annotation in `<image>.annotations.json`: a `Mark` with `tool: 7`, the rectangle in `points` and `element: {number, selector, tag, name, text}`; the description is in `text`. Older documents without `element` load unchanged.
- Export under the image (after the caption, before the callout), sorted by number: `` - **[1] Element** `button[data-testid="save"]` "Save": description ``. `text` is used when `name` is missing; both are cut to 80 characters and escaped. A selector that would look like an image link is replaced with the tag. The lines are stored in the session caption and become part of the image caption after reopening. Elements fully outside the crop are skipped. New numbers after reopening continue from the highest `[n] Element` in the caption. Without context (removed or switched off by policy) and in the cloud only the number and description are exported, without page data.
- Crop in the editor: the map is clipped to the kept area, and on export `capture.rect` in `assets/<image>.context.json` moves to the cropped part, so the map still fits after reopening.
