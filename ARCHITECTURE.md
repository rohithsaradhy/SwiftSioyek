# Architecture

## Ownership and concurrency

`ReaderCore` holds Sendable value types, PDF coordinate transforms, viewport layout, command definitions, the key-sequence state machine, navigation history, bounded caches, and reference/search algorithms.

`PDFServices` owns every PDFKit object behind an actor. Two `RasterWorker` instances render serially using independent `PDFDocument` instances. Each reading window has a separate semantic service for text, links, outlines, and incremental reference indexing. Immutable text snapshots share an app-wide, locked 64 MiB LRU. `RenderedTile` wraps an immutable, once-published `CGImage`; mutable PDF objects never cross isolation boundaries. Large cross-page selection yields between pages and observes cancellation.

`ReaderPersistence` serializes one SQLite connection through `LibraryStore`. Durable records are JSON payloads with indexed relational fields; FTS5 searches bookmark/highlight metadata. Record replacement and its search index update in one transaction. The page text cache is disposable. Newer unknown schema versions fail before a migration writes anything.

`SwiftSioyek` owns AppKit objects on the main actor. `RenderCoordinator` deduplicates requests, prioritizes visible content over helper views and prefetching, bounds raster cache cost, and drops cancelled observers. An in-progress native drawing call is allowed to finish. Zoom changes cancel queued obsolete work and reuse old imagery until new tiles are available. Hidden/offscreen page views are removed, and only nearby previews are prefetched. No whole-document rasterization occurs.

## Geometry and layout

Persistent anchors and selection rectangles use unrotated PDF user coordinates. `PageGeometry` converts between those coordinates and the top-left displayed coordinate system, applying crop origins and the combination of inherent and user rotation. Raster tiles are described in displayed page points; their cache keys include document revision, page, rotation, resolution, and tile index. Native PDF rendering handles embedded annotation appearance.

Search offsets use NSString's UTF-16 ranges. Highlight and selection rectangles come from PDFKit's range-based selections, split by line, on the text-service actor. Cached character geometry uses that same range API: PDFPage.characterBounds(at:) can diverge from the extracted string's offsets. Selecting a search result resolves only its range and does not require building a full-page glyph snapshot. Async navigation checks the current hit before publishing its highlight.

The initial open needs only the first page geometry. Other pages receive provisional dimensions until bounded metadata batches or an interactive page request resolve them. Provisional pages are not rasterized with incorrect dimensions. Updating metadata preserves the reader's current anchor. Continuous layout uses binary search to find visible pages, and native `NSScrollView` handles trackpad momentum.

An `NSMagnificationGestureRecognizer` on the stable document canvas owns each complete pinch, including when zoom replaces visible page views. It delays raw magnification events to avoid applying an update twice; responder forwarding remains a fallback for unrecognized gestures. Each recognized update consumes and resets the recognizer's magnification delta, stops pending keyboard animation, and updates the reader's tile zoom. The pointer anchor is converted through the flipped clip view and measured from its visible bounds origin, keeping the PDF point under the pointer stable after scrolling and rotation. Zoom is limited to 10–800%, with invalid or cancelled gesture updates ignored. Native `NSScrollView` retains its scrolling behavior.

External search URL construction and bounded title guessing live in `ReaderCore`. Selection text is normalized and encoded as a single query value before appending it to a configured HTTP(S) prefix. The AppKit controller opens the resulting URL with `NSWorkspace` and honors PDF copying permissions. Settings stores search engines separately in `ExternalSearch.json`, while version 1 key maps migrate the new `s` binding only when it does not conflict with an existing sequence.

## State and lifetime

Opening a document changes a generation token and cancels old search, metadata, indexing, and selection tasks. Async completions check that token before publishing. File changes create a new revision, invalidate render keys, and stop old annotations from being silently drawn over changed content. Bookmarks resolve moved files, with a native locate-file flow when resolution fails.

Metadata mutations form a serialized task chain. Undo registers its inverse synchronously with AppKit, while the durable transaction runs on the library actor. Session termination waits for pending metadata and position writes. Export opens an isolated document, verifies its revision and permissions, writes a temporary sibling, and atomically replaces the chosen destination.

AppKit's accessibility callbacks bridge into explicitly isolated UI closures. Pages expose text lines, selection ranges, and link actions as native accessibility elements; raster images are not the only accessibility representation. Reader key handling stays on the reader's responder, allowing native text controls to manage ordinary editing and input methods.
