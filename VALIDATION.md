# Validation record

Local measurements on 24 October 2026, Apple M1 Pro, 32 GB RAM, macOS 27 SDK, Xcode 27.1, Swift 6.4. No third-party runtime dependencies.

## Automated checks

`./scripts/validate.sh` runs the core/integration tests, native UI tests against an optimized app, then builds the normal sandboxed Release app. The UI harness temporarily uses Debug entitlements so its isolated fixture paths are accessible. This does not change the delivered app's entitlements. Each UI test uses a separate temporary library.

There are 21 core tests and 12 integration tests. They cover all inherent/user rotation combinations and crop origins, PDF/display coordinate round trips, 1,000-page layout virtualization, cache eviction, counted and multikey commands, argument commands under custom bindings, Escape cancellation, Unicode search offsets, history, reference recognition, portal selection, metadata serialization, SQLite initialization and reopening, annotation replacement/undo search consistency, native text/link/outline extraction, cross-page selection geometry, rendered fiducials, tile/full-page agreement, annotated-copy export without source modification, scans, malformed input, encrypted PDFs, stale revision rejection, and persistent bookmark relocation. External search coverage checks engine arguments and cancellation, old key-map migration without custom-binding conflicts, Unicode/reserved-character query encoding, custom URL prefixes, invalid settings, and wrapped title guessing without crossing columns or bibliography entries. Search geometry regression coverage compares word bounds with native PDF selections across both columns, late-page text, diacritic-insensitive matches, and rotated/cropped pages; the test reproduced the character-bound offset bug before the fix. Search navigation anchors are also checked across every inherent/user rotation combination at multiple zoom levels to keep the selected word visible.

The ten UI tests cover marks/highlights/bookmarks/portals, Spotlight palette filtering and keyboard focus restoration, mouse result activation, `/` and Mac search shortcuts, multiple windows, session restoration, reader/palette layout screenshots, and display-linked motion with bounded raster-cache/page-view assertions. External search UI checks cover keyboard/menu dispatch, selection requirements, unknown engines, settings persistence, validation without overwriting saved settings, and restoring defaults. Wheel checks scroll over page text and cross a continuous-layout page boundary while preserving zoom. The search highlight workflow also captures actual reader-window screenshots for “fluid,” late-page “typography,” and a rotated/cropped match after next/previous navigation. Screenshot checks capture the transient palette before its parent, since requesting a parent screenshot can make it key and dismiss the palette. Artifacts are copied into `build/validation`; full XCTest results live in `build/xcode/Logs/Test`.

Nine native AppKit input tests compile the viewport, renderer, and diagnostics sources into a separate test bundle. Magnification events verify that a pinch over page content or a canvas margin zooms the reader, keeps the PDF point under the pointer stable after scrolling and all inherent/user rotation combinations, preserves the page in single-page mode, honors zoom limits, publishes the displayed zoom, interrupts pending keyboard motion, and ignores cancelled or invalid updates. Tests also verify that ordinary vertical/horizontal scrolling preserves zoom and that middle-click/Shift-middle-click/Control-middle-click route correctly. Two additional tests dispatch complete gesture sequences through a visible NSWindow, including a sustained 30-update pinch while page views change; the sustained test asserts the dedicated recognizer reaches its changed state. Native `NSScrollView` handles scrolling independently of the reader's pinch zoom. These checks exercise documented AppKit event fields and window dispatch; physical trackpad hardware and third-party search-site availability are not asserted by the tests. Browser URLs are tested locally without launching external sites during automation.

The earlier full validation passed all 50 tests: 21 core, 12 integration, seven native input, and ten UI tests. Native input and UI checks used Release optimization with the fixture-access entitlements described above. The delivered app was rebuilt with its normal sandbox entitlements and passed strict code-signature verification.

The subsequent pinch-delivery fix passed all nine native input tests in Debug and Release. A physical trackpad check reproduced the original failure: raw responder callbacks stopped partway through each pinch even though magnification events continued reaching the app. With a dedicated canvas recognizer, all 217 traced magnification updates reached its handler, and the user confirmed that zoom followed the full gesture in both directions. Temporary tracing was removed from the delivered source.

The link-navigation regression was reproduced before the fix: clicking an embedded link to page 6 and pressing the Back toolbar button stayed on page 6. History now updates the displayed position within the current visit, preserving forward history rather than adding a step for viewport constraints, coordinate rounding, or scrolling. Three core regressions cover constrained destinations, reading after a jump, forward restoration, and branching. The native link test passes in Debug and Release for toolbar buttons, Backspace/Shift-Backspace, and Control-arrow shortcuts. The Release test additionally checks keyboard link hints and verifies that returning restores the source link's screen position within one point after scrolling. The marks/highlights/bookmarks/portals and session-restoration UI tests pass in Debug; all 21 core and 12 integration tests pass.

On 27 October 2026, a native overlay regression reproduced the incorrect highlight colors (`hg` yellow and `hr` purple). Reader overlays and PDF export now share explicit color-letter mappings. All 21 core and 14 integration tests pass, including saved/reopened styles, exported RGB colors for all a–z types, uppercase normalization, and invalid-style fallback. The seven-color native overlay regression and the marks/highlights/bookmarks/portals UI workflow pass. The broader native run passes nine of ten tests; its existing scrolling test fails in the combined run and passes when run alone. The normal sandboxed Release app builds, passes strict signature verification, and is installed at `/Applications/SwiftSioyek.app` with an executable matching the verified build.

The 27 October 2026 figure-preview correction was reproduced with a deterministic PDF containing a right-column diagram and a 17-line caption. Disabling the new placement fails the native visibility regression at source zooms of 75%, 170%, and 400%; enabling it reveals the entire diagram and the caption's first line. All 22 core and 15 integration tests pass, including crop/rotation transforms, destination-caption detection before background indexing, and unchanged table-preview handling. The new native and Release UI regressions pass for embedded links, resolved text references, keyboard previews, Escape dismissal, and preservation of the source page. Screenshots are saved as `build/validation/long-caption-preview-{link,reference,keyboard}.png`.

The complete Release run passed 10 of 11 native input tests and 9 of 11 UI tests. Both palette-related UI failures passed on a separate run. The previously documented `testScrollingThroughPageAndCanvasPreservesZoom` failure persists in the separate Release run, so the aggregate validation command is not green. The normal sandboxed Release app builds and passes strict code-signature verification.

## PDF service benchmark

Reproduce with `./scripts/benchmark.sh`. Data: `build/fixtures/benchmark.json`.

| Deterministic fixture | Open | First preview, including open | Cold tile p95 | Warm tile p95 |
|---|---:|---:|---:|---:|
| Two-column paper, 30 pages | 66.82 ms | 73.53 ms | 1.94 ms | 0.96 ms |
| Textbook, 1,000 pages | 0.74 ms | 5.37 ms | 0.93 ms | 0.77 ms |
| Image scans, 300 pages | 1.48 ms | 5.09 ms | 2.83 ms | 2.77 ms |

“Cold” starts a fresh PDF worker; it does not flush the operating system's filesystem cache. “Warm” repeats tile requests within that worker. These are PDF service measurements, not end-to-end window-opening times or compositor frame intervals. The process high-water RSS reached 82.02, 351.59, and 418.72 MiB cumulatively while benchmarking these documents in order; these figures are not independent per-document memory costs.

## Native Release reading measurement

The UI performance test samples display-link timestamps during 24 alternating screen-scroll requests. The most recent report is `build/validation/UI-performance.json`. A Release run recorded:

| Metric | Result |
|---|---:|
| Open to first rendered content, paper | 33.66 ms |
| Display-link frame interval p95 | 27.78 ms |
| Main-thread scroll work p95 | 0.25 ms |
| Peak app-owned raster cache during this traversal | 36.51 MiB |
| Maximum instantiated page views | 2 |
| Process high-water RSS | 213.23 MiB |

The 120 Hz / 8.3 ms p95 acceptance target is **not met** by this UI measurement. Fast PDF rasterization and short scroll callbacks do not establish smooth compositor presentation. The display link requests the active screen's maximum rate only during keyboard motion and is invalidated afterward. Native trackpad scrolling uses NSScrollView. A separate idle process sample (`build/qa-sample.txt`) showed the main thread waiting in its event loop; this is a spot check, not an energy certification.

## Remaining acceptance work and limits

- Capture dedicated Instruments Animation Hitches, Time Profiler, Allocations, and Points of Interest traces. The app emits `Rendering` and `Interaction` signposts under `app.swiftsioyek`; no Instruments trace is claimed by the numbers above.
- Measure input-to-visible-feedback latency, repeated long-document traversal for sustained RSS growth, and cold/warm full-window opening separately for all three fixtures. Existing UI cache checks are shorter bounded traversal checks.
- Complete hands-on VoiceOver navigation, input-method composition, Reduce Motion, appearance switching, and Retina/non-Retina display movement checks. Native text, selected ranges, links, and palette controls are exposed through accessibility APIs, but that is not a claim of completed VoiceOver acceptance.
- Extend UI coverage for rapid document replacement, preview interaction, cross-document portal helpers, external-file replacement, annotation undo/redo, and the Save-panel export workflow. Export content/source preservation already has integration coverage.
- Version 1 database creation/reopening is covered. Future migration paths need fixtures as schema versions are introduced; unknown newer schemas are rejected before writing.

PDFKit controls text extraction order, malformed-font handling, and embedded annotation rendering. Scanned pages without an existing text layer have no selection/search until OCR is added. Smart jumps target common English numbered references and can offer multiple candidates. Pathological PDFs can take longer to decode or draw; work remains isolated from the main actor and obsolete results are discarded. Raster-cache limits exclude PDFKit's own internal allocations and images still retained by visible layers. Each raster operation rejects oversized bitmap allocations.
