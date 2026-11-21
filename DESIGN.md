# Screenshot Note — design system

## Direction

A calm, native Mac workspace for collecting visual context. Screenshots provide the visual anchor; typography and spacing supply hierarchy. One violet accent identifies actions and selection. Routine controls use neutral surfaces.

## Structure

- Capture: prominent editable note title in the header, configuration link, optional quiet “Copy link” button (committed cloud sessions only, briefly turns into a green “Link copied” confirmation) and capture action on one row without overlaps, horizontally scrolling screenshot strip, single-line comment and a fixed action row.
- Configurations: a persistent sidebar and a single details form. No repeated card containers.
- Team folders: shown as `<Team> · <Folder>` with the `person.2` SF Symbol (15 pt, same tint as cloud folders) in the sidebar and as a template image in the folder picker. For a member, the folder name, description, mode, file and template controls are disabled and the pencil and delete actions are hidden; only the local directory stays editable, explained by the sync caption.
- Cloud Library: team uploads that lost access or role land in the shared „Set Aside…“ list (Try Again, Save Locally, Discard) like other parked items; there is no separate blocked button.
- Settings: three plain rows for configurations, shortcuts and login behavior.
- Annotation editor: one icon toolbar, neutral image canvas and a common action row.
- Markdown editor: a restrained formatting toolbar and an uncluttered writing surface.

## Tokens

| Token | Light | Dark |
|---|---|---|
| Background | #FAF9FC | #1E1C25 |
| Paper/input | #FFFFFF | #292631 |
| Raised surface | #F0EDF6 | #34303E |
| Separator | #E4DEEC | #433D50 |
| Accent | #6851D8 | #A18CF7 |
| Primary button | #6851D8 | #7758E8 |
| Canvas | #F0EDF5 | #18151F |

Text uses system semantic colors, not frozen RGB values. System SF typography: 27 pt note title, 23–24 pt window headings, 13–14 pt controls and body, 10–12 pt metadata. Monospaced system figures label screenshot order. Spacing uses 4/8 pt increments with 28 pt window gutters; radii are 8 pt for controls and 10 pt for image surfaces.

## Interaction

Panels continue to work above fullscreen apps. The interface uses brief entrance fades, compact/expand transitions and save confirmation fades. Reduce Motion is respected. Hover states, tooltips and semantic selection distinguish controls without adding constant chrome. Existing keyboard shortcuts and single-line/Markdown comment behavior remain intact.

## Verification

The test host's `--self-test` (see README Verification) verifies storage, filenames, old session updates, annotations, dark input/icon rendering and preservation of data when compacting. `--design-export DIRECTORY` generates native AppKit renders covering the main windows, selection dialogs and inline editing states in both appearances and both interface languages, using synthetic screenshots and temporary configuration data. It does not capture the user's screen.

Version 4.1 adds warm violet-tinted headers, semantic icon badges in Settings and a branded About window. All static product text is localized through the native Czech/English catalogs. Header heights and label widths are adapted to each workspace, including the longer English screenshot caption.

Configuration and session links open compact selection dialogs with names, descriptions and session thumbnails. The capture screen omits redundant labels above its title, image strip and comment.

Per-image notes use a compact dialog, separate from annotations. Hovering a screenshot reveals two contextual icon actions with tooltips: annotations and note. The note field expands into the shared Markdown editor.

Selection geometry uses constant-size screen-space handles around rotated object bounds. Corner drags scale proportionally around the opposite corner; a connected circular handle rotates. Dirty editors use a compact three-action confirmation. Build-time verification is noninteractive.
