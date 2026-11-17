# Frisket for macOS

A native macOS build of Frisket, written in Swift on AppKit. It keeps the
Windows app's behaviour and file format: your notes stay ordinary `.md` files in
an ordinary folder, and a library made on Windows opens here unchanged (and the
other way round).

Nothing here uses Electron or a web view for editing. The editor is an
`NSTextView` on TextKit, so text input, spelling, dictation, the Services menu,
Find, accessibility and native window tabs all work the way they do in other
Mac apps.

## Requirements

- macOS 14 Sonoma or later (Apple silicon or Intel).
- To build: Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
  (`brew install xcodegen`).
- Optional: [Pandoc](https://pandoc.org/installing.html) for Word, OpenDocument,
  RTF, EPUB and LaTeX export. Frisket finds an installed copy; it is not bundled.

## Build and run

```bash
cd macos
xcodegen generate
open Frisket.xcodeproj
```

Then press ⌘R in Xcode. From the command line:

```bash
cd macos
xcodebuild -project Frisket.xcodeproj -scheme Frisket -configuration Release build
```

`Frisket.xcodeproj` is generated from [`project.yml`](project.yml). It is checked
in so the project opens without XcodeGen, but run `xcodegen generate` again after
adding or removing source files, and edit `project.yml` rather than the project.

To make a drag-to-install disk image, run:

```bash
macos/scripts/make-dmg.sh
```

It builds a universal (Apple silicon and Intel) Release copy and writes
`release/Frisket-<version>.dmg` at the repository root.

Builds are signed ad hoc (`CODE_SIGN_IDENTITY = "-"`) with the hardened runtime.
To distribute a build, set your Developer ID team in Xcode and notarise it; an
unsigned copy downloaded from the internet is blocked by Gatekeeper until it is
opened with Control-click › Open.

## Tests

The app's logic lives in Swift packages, each with its own tests:

```bash
for p in FrisketBase FrisketMarkdown FrisketLibrary FrisketServices FrisketExport; do
  (cd Packages/$p && swift test) || break
done
```

The app target has its own tests for editor typing behaviour (list continuation,
auto-pairing, formatting commands) and for export safety (scripts in a note never
run during export, and PDF output paginates):

```bash
xcodebuild -project Frisket.xcodeproj -scheme Frisket -destination 'platform=macOS' test
```

The library tests reuse the parser cases in the repository's top-level
`fixtures/`, so the Mac and Windows apps are checked against the same
expectations.

## How it is put together

```
macos/
  project.yml            XcodeGen spec (targets, packages, Info.plist, entitlements)
  Frisket/               the app
    App/                   launch, menus, settings (UserDefaults)
    Editor/                live-preview editor on TextKit 1
      MarkdownTextStorage    text storage that restyles changed paragraphs
      MarkdownStyler         Markdown spans → attributes, hidden markers
      LivePreviewLayoutManager  hides syntax, draws boxes, checkboxes, widgets
      WidgetRenderer         tables, math (SwiftMath), images
      MarkdownTextView       typing behaviour, completion, links, paste/drop
      EditorCommands         Format and Paragraph menu commands
    Library/               the open library: index, file watching, attachments
    Window/                window, sidebar, note list, inspector, quick open
    Panels/                version history, sync, templates, import, settings…
    Export/                PDF, HTML, Markdown, image, text and Pandoc export
    Theme/                 reads the shared theme CSS into native colours
  Packages/
    FrisketBase/           file operations and shared helpers
    FrisketMarkdown/       Markdown scanning: headings, links, tags, tasks, front matter
    FrisketLibrary/        library index, search, backlinks, history, trash
    FrisketServices/       sync providers, conflicts, importers, Pandoc
    FrisketExport/         HTML rendering and export pipeline
```

The themes in the top-level `themes/` folder are shared with the Windows app;
the Mac app reads their CSS custom properties and maps them to native colours.
Your own themes go in `~/Library/Application Support/Frisket/themes`
(View › Theme › Open Theme Folder).

## Differences from the Windows app

The Mac app follows Mac conventions where the two differ:

- **Tabs are native window tabs** (⌥⌘T, or Window › Merge All Windows). There is
  no side-by-side split inside one window; open a second window instead.
- **Settings** are in Frisket › Settings… (⌘,) and stored in the app's
  `UserDefaults`, not in a JSON file.

Not yet ported:

- Syntax highlighting inside fenced code blocks (code shows in a monospaced box).
- Mermaid diagrams show as their source, in the editor and in exports.
- Footnotes show as written (`[^1]`) in the editor.
