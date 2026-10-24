# Swift Sioyek

A macOS 27 research PDF reader written in Swift 6 for Apple Silicon. AppKit supplies the interface, PDFKit/Quartz renders PDF content, and Core Animation composites reusable page tiles. There are no third-party dependencies or network services.

The design follows Sioyek's research workflows, with a quiet native window, standard Mac shortcuts, and a configurable keyboard command system. It is an independent implementation; no upstream Sioyek source or rendering libraries are included.

Commands and document search open in a compact, Spotlight-style native palette. There is no sidebar. Type to filter, use ↑/↓ to choose a result, Return to open it, and Escape to return to reading. Contents, pages, bookmarks, and highlights use the same interface.

## Build and run

Requires Xcode 27 or newer and an Apple Silicon Mac running macOS 27.

```sh
./scripts/build-app.sh
open build/SwiftSioyek.app
```

The script selects `/Applications/Xcode.app/Contents/Developer` for that command only. Set `DEVELOPER_DIR` when using another Xcode installation. The app is signed locally with an ad hoc identity; no Apple developer account is needed for a local build. The Release app is sandboxed and opens documents through Finder, drag and drop, or the native Open panel.

Alternatively, open `SwiftSioyek.xcodeproj` and run the shared **SwiftSioyek** scheme. `scripts/generate-project.py` regenerates the small Xcode wrapper after adding app source files; the reusable modules and developer tools are defined in `Package.swift`.

## Reading

| Action | Keys |
|---|---|
| Open / recent documents | `⌘O` / `O` |
| Search / chapter search | `/` or `⌘F` / `c/` |
| Search selection in Scholar / Library Genesis / Google | `ss` / `sl` / `sg` |
| Next / previous match | `n` / `N` |
| First / last / numbered page | `gg` / `G` / `150gg` |
| Scroll a screen | Space / Shift-Space |
| Contents / commands | `t` or `⌘T` / `⌘K`, `:`, or `⌘⇧P` |
| Zoom / fit width / fit content | `+` and `-` / `=` / F10 |
| Rotate | `r` / `R` |
| Set / visit a mark | `m` then a letter / backtick then a letter |
| Add / browse bookmarks | `b` / `gb` |
| Highlight selection / browse highlights | `h` then `a`–`z` / `gh` |
| Global bookmarks / highlights | `gB` / `gH` |
| Reading ruler | Right-click prose, then `j` / `k` |
| Keyboard selection | `v`, then arrows; `⌘C` copies |
| Keyboard link hints | `f`, then the displayed two-letter label |
| Preview / jump to selected reference | `l` / `]` |
| Create portal | `p` at the source, then `p` at the destination |
| Visit / show portal | `gp` or Tab / F12 |
| Back / forward | Backspace / Shift-Backspace |
| Cancel | Escape |

Lowercase marks belong to their document; uppercase marks are global. `j` and `k` move the reading ruler, following Sioyek's semantics. Arrow keys and two-finger trackpad movement scroll. Pinch two fingers to zoom in or out around the pointer, including over page content and margins. Pinch zoom works in the main reader, reference previews, and portal windows.

Native menus expose all supported commands. Settings edits and validates the JSON key map and external search settings, applying changes to all reader windows. Older key maps gain the `s` command unless it conflicts with a custom binding.

Search accepts a one-based physical page range: `<20,30>Figure`. Smart jumps use embedded links first, then locally indexed English numbered figure/table captions, equation labels, and bibliography entries. Ambiguous matches present a destination list. Unresolved references fall back to text search. Reference indexing proceeds in the background.

## External search

Select text, then press `s` followed by an engine letter to open a search in your default browser. The defaults follow [Sioyek's external search](https://sioyek-documentation.readthedocs.io/en/latest/usage.html#external-search): `ss` searches Google Scholar, `sl` Library Genesis, and `sg` Google. **Research → External Search** and the command palette also accept the engine letter. Escape cancels the pending command.

Middle-click a paper or book title to search in Scholar without selecting text. Shift-middle-click uses Library Genesis. The title guess joins nearby wrapped lines within the same column and reference entry, preferring a quoted title when available. For an exact query, select the title and use the keyboard command. Control-middle-click jumps to a local reference or follows an embedded link.

In **Settings → External Search**, `searchURLs` maps any letter `a`–`z` to an HTTP(S) URL prefix, equivalent to Sioyek's `search_url_*` settings. The reader normalizes whitespace, URL-encodes the query, and appends it to the prefix. `middleClickSearchEngine` and `shiftMiddleClickSearchEngine` choose the mouse engines. For example, add `"d": "https://duckduckgo.com/?q="` to `searchURLs` to enable `sd`. Changes save to `ExternalSearch.json` beside `KeyBindings.json`; Apply and Restore Defaults act on the selected Settings section. Search sites and their URL prefixes can change, so replace a prefix here when needed. PDFs that disallow text copying also disallow external text searches.

## Saved data

The sandboxed app stores `Library.sqlite`, `KeyBindings.json`, and `ExternalSearch.json` inside its Application Support directory in `~/Library/Containers/app.swiftsioyek/Data/Library/Application Support/SwiftSioyek/`. Xcode's unsandboxed Debug build uses `~/Library/Application Support/SwiftSioyek/`.

Documents remain in their original locations. Security-scoped bookmarks reconnect moved files. Reading positions, marks, bookmarks, highlights, and portals save automatically. SQLite uses transactional writes, WAL, full synchronization, and versioned migrations. Annotation edits support native undo and redo.

**File → Export Annotated Copy** writes highlights into a separate PDF. The source is never overwritten. Anchors from older file revisions are flagged and excluded from export until recreated for the current revision. Existing PDF annotations remain visible.

## Validation and profiling

```sh
./scripts/validate.sh  # tests plus a normal sandboxed Release app

# Individual checks:
./scripts/test.sh
./scripts/test-ui.sh

# Developer-only fixture generation and PDF service benchmarks:
swift run --disable-sandbox ReaderDiagnostics fixtures build/fixtures
swift run --disable-sandbox -c release ReaderDiagnostics benchmark build/fixtures
```

The generated corpus includes a 30-page two-column paper, a 1,000-page textbook, a 300-page scanned book, rotated/cropped pages, mixed sizes, Unicode, embedded links/highlights, ambiguous references, encrypted PDFs, and malformed input. Fixtures are generated locally with Apple frameworks.

`ReaderDiagnostics` reports PDF opening, preview rendering, tile rendering, and peak process memory. These service timings do **not** establish a display frame rate. The UI performance test records actual display-link cadence, main-thread scroll work, active page views, and the raster-cache high-water mark in `build/validation/UI-performance.json`. Its `configuration` field distinguishes Debug from Release.

For an optimized UI measurement without the Release sandbox's restriction on test-fixture paths:

```sh
SWIFTSIOYEK_TEST_CONFIGURATION=Release ./scripts/test-ui.sh \
  CODE_SIGN_ENTITLEMENTS=Resources/Debug.entitlements ENABLE_APP_SANDBOX=NO \
  -only-testing:ReaderUITests/ReaderUITests/testPerformanceAndIdleWindow
```

Rebuild with `scripts/build-app.sh` afterward to produce the normal sandboxed app. Instruments signposts use subsystem `app.swiftsioyek`, with `Rendering` and `Interaction` categories. Test runs use isolated temporary libraries. Normal use records no diagnostic telemetry.

## Current boundaries

OCR, SyncTeX, extensions, external command control, Sioyek database import, cloud sync, and public distribution are outside this release. Scanned PDFs display normally but need an existing text layer for selection and search. PDFKit's extraction order and font encodings determine text-selection fidelity; unusual layouts can require manual selection. Smart jumps are deterministic heuristics, rather than a guarantee for every publication's reference style.

Rendering has two workers, a shared 256 MiB raster cache, and a shared 64 MiB text/geometry cache. PDFKit's internal allocations and the visible layer contents contribute additional process memory. A complex page can take time to rasterize, while the main interface remains available. See `VALIDATION.md` for measured results and remaining manual checks.
