# Frisket

*The syntax is masked. The writing shows through.*

In letterpress printing, a **frisket** is a mask cut away only where the ink
should fall. Frisket does the same for Markdown: the markers stay in your plain
`.md` files, but they disappear from view as soon as the cursor leaves them, so
what you see is the page rather than the markup.

Frisket is a desktop Markdown notes app. Your notes are ordinary files in an
ordinary folder: no account, no database, no lock-in.

## Features

- **Live preview editing.** Headings, emphasis, links, lists, tables, math
  (KaTeX), Mermaid diagrams and images render as you type; the syntax comes back
  while the caret is inside it. Source mode is one keystroke away.
- **A library of notes.** Tags and nested tags (`#work/projects`), Untagged and
  Todo views, pinned notes, Trash, and live search with `#tag`, `@todo` and
  `@images`.
- **Linked notes.** `[[Wiki links]]` resolve by title, file name or alias, with
  autocomplete, backlinks and unlinked mentions. Rename a note's title and
  Frisket offers to update the links that pointed to it.
- **Tabs and split view.** Open notes in tabs, side by side or stacked. A note
  open in both panes stays in sync, and your tabs come back next time.
- **Version history.** Snapshots as you work, with a line-by-line comparison
  and one-click restore.
- **Sync through your own cloud.** Keep the library in OneDrive, Dropbox,
  iCloud Drive, Google Drive or Syncthing. Frisket shows how the library syncs,
  and when two devices change the same note it keeps both versions for you to
  compare.
- **Daily notes, templates and quick capture.**
- **Import** from Evernote (`.enex`) and Notion exports.
- **Export** to PDF with bookmarks, self-contained HTML, Markdown with its
  attachments, JPEG and plain text, plus Word, OpenDocument, RTF, EPUB, LaTeX
  and more when [Pandoc](https://pandoc.org/installing.html) is installed.
- **Writing modes.** Focus, typewriter and distraction-free modes; ten themes,
  plus your own CSS.

## Download

Windows builds are on the [Releases](https://github.com/cfdrstudio/frisket/releases)
page:

- `Frisket-Setup-<version>.exe` installs for your user account, with no
  administrator prompt, and registers `.md` files.
- `Frisket-<version>-portable.exe` runs without installing.

The builds are not code-signed yet, so Windows SmartScreen asks before the first
run: choose **More info → Run anyway**.

## Build from source

You need Node.js 20 or newer.

```bash
npm ci
npm run build
npm run dev
```

- `npm run watch` rebuilds the interface whenever you save.
- `npm test` runs the unit tests with Node's built-in test runner.
- `npm run dist` builds the Windows installer and portable app into `release/`.
  The source also builds for macOS with `npm run dist:mac` on a Mac.
- After `npm run build`, `node tools/smoke-library.cjs`,
  `node tools/smoke-essentials.cjs` and `node tools/smoke-workspace.cjs` drive
  the real app end to end against throwaway libraries and a throwaway profile.

Pandoc is GPL-licensed, so it is detected rather than bundled: Frisket looks for
an installed copy and offers to find one if it is missing.

## How it is put together

```
src/main/            Electron main process
  main.js              windows, files, settings and the IPC surface
  libraryIndex.js      the library index (runs in a worker thread)
  workspace.js         note parsing, tags, links and search
  history.js           version history snapshots
  syncProviders.js     which sync app a library lives in
  importers/           Evernote, Notion and Apple Notes importers
src/renderer/        the interface
  editor/              CodeMirror setup, live preview, autocomplete
  ui/                  tabs and panes, library panes, sidebar, dialogs
themes/              built-in themes (CSS custom properties only)
tests/, fixtures/    unit tests and shared parser cases
```

## Licence

Frisket is released under the [MIT Licence](LICENSE). Third-party components and
their licences are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

The Frisket name and logo identify releases from CFDR Studio. You are welcome to
fork, change and redistribute the code under the MIT Licence; if you ship a
modified version, please give it a different name and icon.

## Contributing

Bug reports and ideas are welcome as
[issues](https://github.com/cfdrstudio/frisket/issues). Pull requests are welcome
too: accepted changes are included in the next release, which is published here
as a single commit.

---

Made by [CFDR Studio](https://cfdr.au).
