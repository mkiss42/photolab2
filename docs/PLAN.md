# PhotoLab 2 — Plan

Living document. Every session reads this first. Decisions change only by editing the
Decision Log at the bottom (date, what, why).

## 1. What we are building

A native macOS photo-lab browser for a post-production lab working on busy SMB shares:
a very fast file browser + contact sheet + preview, with lab tools (ingest, metadata
stationery, search, AI culling/embeddings, shared cache between machines).

It replaces PhotoLab 1 (Python + PyQt5). PhotoLab 1 keeps running in production until
PhotoLab 2 covers each workflow; the two can run side by side.

Inspiration: the "Find" app (Swift/AppKit). We reuse its *ideas*, not its code.

## 2. Hard requirements

| # | Requirement | Consequence |
|---|---|---|
| R1 | Runs on macOS 10.13 → current, Intel and Apple Silicon | AppKit only (no SwiftUI, no Combine, no async/await/actors — they need 10.15+). GCD + OperationQueue. Universal binary: x86_64 slice min 10.13, arm64 slice min 11.0. |
| R2 | Upgrade path = "run this .sh instead of that one" | One source tree, two build profiles: `build-legacy.sh` (Xcode 26, targets 10.13) and `build-modern.sh` (Xcode 27+, targets 12.0). CI builds both on every push so neither rots. Newer-OS APIs only behind `if #available`. |
| R3 | Swift wherever Swift is fine; Python only where it is clearly better | See §4. |
| R4 | No Qt | Python side is headless. |
| R5 | Frugal with network IO; never freeze on a slow share | Main thread never touches a network path. Bulk listing (getattrlistbulk). Embedded-JPEG previews. Shared cache across machines. |
| R6 | Never lose or damage user files | Find-style file-safety contract (§7). |

Toolchain facts (checked Nov 2026): Xcode 26 still builds a 10.13 deployment target (with a
warning). Xcode 27 refuses anything below macOS 12. So the legacy profile is pinned to
Xcode 26 on whatever Mac/CI image still runs it. When the lab drops 10.13–11, switch the
default to `build-modern.sh`; no code changes expected.

## 3. Architecture

```
┌──────────────────────── PhotoLab.app ────────────────────────┐
│  Swift / AppKit (the app)                                     │
│   • volumes, sidebar, folder tree, file list                  │
│   • bulk listing, folder watching, listing cache              │
│   • contact sheet (hand-drawn grid), fast preview, Quick Look │
│   • thumbnails & previews (ImageIO, embedded RAW JPEGs)       │
│   • local thumbnail cache (files on disk, read directly)      │
│   • ratings / labels / color classes write (bundled exiftool) │
│   • file ops: copy/move/trash/rename/undo, journal, recovery  │
│   • window layouts / workspaces, FTP browser                  │
│   • UI for everything the brain does                          │
│                    ▲  JSON lines over a Unix socket  │        │
│                    │  (requests + pushed events)     ▼        │
│  Resources/python-<arch> + brain/  (Python 3.11, headless)    │
│   • shared cache + peer sync (exif results, embeddings,       │
│     thumbnails, folder listings)                              │
│   • metadata cache DB, metadata search                        │
│   • ingest engine, stationery / template engine               │
│   • AI: models, embeddings, semantic search, faces, culling   │
│   • server mode (same binary, run headless as a launchd job)  │
└───────────────────────────────────────────────────────────────┘
```

Rules of the boundary:
- **The app never waits on the brain.** Every brain call has a timeout and a fallback.
  Brain down = a fast browser without lab extras, plus a status badge. The app restarts
  the brain with backoff.
- **A separate process, not embedded Python.** Swift *can* embed Python (PythonKit / the C
  API), but in-process Python means a crash in numpy/onnxruntime kills the app and the GIL
  competes with the UI. A helper process is crash-isolated, restartable, can use all
  cores, and is the same binary that runs headless in server mode.
- Protocol: newline-delimited JSON over `~/Library/Application Support/PhotoLab2/brain.sock`.
  `{"id":1,"method":"exif.get","params":{...}}` → `{"id":1,"result":{...}}` or
  `{"id":1,"error":{"code":"E-…","message":"…"}}`; brain-initiated events have no id:
  `{"event":"cache.updated","params":{...}}`. Spec lives in `docs/PROTOCOL.md`; both sides
  have a protocol self-test.
- Python packaging: the brain is frozen into a standalone helper (one per architecture or
  universal). Exact tool decided in Phase 0 (start from how PhotoLab 1 freezes today).

## 4. PhotoLab 1 feature evaluation

Verdicts: **Swift** (rewrite natively, Find-style) · **Python** (keep/port into the brain)
· **Drop**.

| PhotoLab 1 piece | Verdict | Why |
|---|---|---|
| image_service, preview_tiers, preview_memo, image_open_6 (multi-process pools, shared memory, priority queue, deficiency engine, dwell timer, attempt ledger, memo DB) | **Drop → Swift** | All of this exists to work around the GIL and Qt. ImageIO `CGImageSourceCreateThumbnailAtIndex` + embedded-JPEG extraction + NSCache on a few threads does the job in-process. It is the source of most PhotoLab 1 preview bugs. |
| qlmanage subprocess renders | **Drop → Swift** | QLPreviewPanel and QLThumbnailImageCreate in-process. |
| rawpy sensor decode | **Swift (ImageIO/CoreImage RAW)**, optional brain fallback | macOS decodes most RAWs natively. Caveat: cameras newer than the installed macOS only show their embedded JPEG; that is acceptable. |
| contactsheet.py (QGraphicsScene, one item per asset) | **Swift** | One hand-drawn view, draws and loads only visible cells. Keep its UX: stars, color classes, filter bar, size slider, M-rename, Cmd+/ refresh, results tabs. |
| folder_tree2, crumb_bar, sidebar_left, toolbar, dock_manager, combo_win | **Swift** | UI. Custom workflow layouts become saved Workspaces (window set + positions + roles). |
| fs_watcher (watchdog/FSEvents + polling tiers) | **Swift** | kqueue per visible folder + "event is only a hint, verify on disk" (Find), FSEvents for local volumes. Polling only for visible folders on shares. |
| parallel_walk, asset_service_5 browse scans | **Swift** for browsing | getattrlistbulk = one round trip per few hundred entries. |
| fs_ops_manager, fs_ops_panel | **Swift** | Find's contract is stronger: temp names, verify, journal, recovery on next start, undo. Keep PhotoLab's raw+jpg+sidecar group operations. |
| metadata_panel, metadata_editor, star_widget, color_widget, tag_menu | **Swift** UI | Field definitions shared as JSON (`shared/fields.json`) so Swift UI and Python templates agree. |
| Ratings/labels write path | **Swift** | Core browsing must work without the brain. Copy → write → verify pixels unchanged → swap (Find). RAW: sidecar XMP only. |
| metadata_service (ExifTool daemon, TemplateSubstitutor) | **Python** for templates + bulk reads; Swift has its own exiftool for writes | Template logic is mature and shared with ingest/stationery. |
| metadata_stationery, metadata_fields | **Python** engine + **Swift** UI | Untangle: ingest_service currently imports `gui.metadata_fields`; the field logic moves into the brain. |
| ingest_service | **Python** engine + **Swift** UI | Solid design (staging for remote destinations, group-aligned renames, journal, never overwrite). Keep. |
| search_service, search_dialog | **Python** engine + **Swift** UI | Searches the shared metadata cache + listings index, verifies hits on disk. |
| ai_models, ort_runtime, embed_service, embedding_store, semantic_search, search_semantic, embed_cli | **Python** | The ML ecosystem is Python. Note: onnxruntime wheels may not support 10.13 — old Macs consume embeddings from the shared cache instead of computing them (verify in Phase 5). |
| asset_sync (P2P, mDNS, sequenced log, store deltas, snapshots) | **Python, keep** | Hard-won, v3 protocol works. Re-scoped to the shared cache (§5). |
| tool_store, asset_service_db | **Python** | Becomes the shared-cache DB. Not the source of truth for browsing. |
| volumes.py (stable volume ids: marker / disk UUID / mount source) | **Python + small Swift twin** | Both sides need the same `(volume_id, rel_path)` keys; ported logic + shared test vectors. The `.photolab.volume` marker is the only file we ever write at a share root (whitelisted in the guard). |
| server_mode | **Python** | Headless brain as a launchd job on the machine that owns the disks. No GUI needed at all there. |
| ftp_client, ftp_tree, server_config_dialog | **Swift** | Find proves a native FTP pane works; it is UI-heavy. Phase 6. |
| open_with, Reveal, dock drops, copy path | **Swift** | Native APIs. |
| pipeline_telemetry | **Drop** | Replaced by plain logs + main-thread freeze logger. |
| splash, style/PaletteEditor | **Drop/Swift** | Native appearance; light theme options only. |
| diskcache thumbnail cache (SQLite) | **Drop → plain files** | Local thumbnail cache = files keyed by hash; Swift reads them with zero IPC. |

## 5. Shared cache (keep and simplify)

Goal: a picture, its metadata or its embedding is pulled off the NAS once for the whole lab,
not once per Mac.

Identity of everything: `key = (volume_id, rel_path, size, mtime_ns)`. A changed file is a
different key, so stale data can never be served; no invalidation logic.

| Data | Producer | Shared how | Consumer |
|---|---|---|---|
| Thumbnails (≈ 512 px JPEG) and screen previews (≈ 2048 px) | Swift (ImageIO) writes `~/Library/Caches/PhotoLab2/thumbs/ab/<hash>.jpg` | Brain advertises per-folder manifests and fetches missing blobs from peers for folders the user is viewing (the app tells it "viewing X") | Swift reads the file directly; on miss it reads the NAS |
| ExifTool results (incl. embedded-preview offsets) | Brain | existing store-delta sync | Swift via `exif.get` (timeout → read itself) |
| Embeddings, faces | Brain (fast Mac / server mode) | existing store-delta sync | Brain search |
| Folder listings | Swift tells brain what it read | existing sequenced log | **Search and lab-wide index only.** Browsing always reads the disk (one getattrlistbulk round trip); a peer's listing is never shown as current. |

Bounded size, LRU pruning, all in `~/Library/Caches/PhotoLab2`. Nothing is written to shares
(except the volume marker).

## 6. Performance rules (from Find)

- Main thread: no file system calls on network volumes, ever. A watchdog logs every freeze
  > 0.25 s as `FREEZE <seconds> while: <what>`.
- Listing: getattrlistbulk; fall back to readdir+lstat if a record fails validation; the
  self-test compares both on real folders.
- Thumbnails: only visible cells; RAW → embedded JPEG located by parsing TIFF/CR3/RAF
  structure (a few small reads); others → ImageIO at reduced size; else Quick Look thumbnail.
- Preview: screen-size decode, prefetch next 2 + previous 1, memory-only cache of a few
  screens; full Quick Look on Cmd‑Y.
- Listing cache: memory, 2 minutes; revisit costs one folder stat.

## 7. File-safety contract

Only three Swift files may call APIs that change files (enforced by `tools/check_mutations.sh`
at every build): `FileOperations.swift`, `AppFiles.swift`, `Platform.swift`. The brain has
the same rule (`tools/check_mutations_py.sh`) with its own short whitelist (ingest copy,
cache dir, volume marker).

Nothing is deleted permanently (Trash only) - with one exception (lab decision 2026-11-25): on
shares without a Trash (all of the lab's SMB shares), Move to Trash asks first, Finder-style
("deleted immediately, can't be undone"; Return does not confirm), and only then deletes. Nothing is overwritten (exclusive renames).
Copies (0.3.0) land under a hidden, journaled name (`.photolab-partial-<job>-<n>`, a whole
folder tree under one hidden name), every file is size-checked against the source and the
source must be unchanged (size + date), then the item is renamed to its real name - never onto
an existing one (Keep Both numbers it, Skip leaves it out; there is no Replace). A launch after
an interruption removes the hidden partial copies. Sets travel whole. Moves on one volume are
renames (journaled, all-or-nothing, undoable). Cross-volume moves (Cmd-drag, Cmd-Option-V) are
the second exception to "Trash only": after the whole set's copy is in place and verified, the
originals that were copied are removed, one by one, only if unchanged since the scan; anything
added or changed meanwhile stays (W-OPS-4). Metadata writes go to a
copy, are verified (requested values present, image data identical), then swapped.

RAW files (lab decision 2026-11-25): metadata is written into RAWs as well as into sidecars
and JPEGs, so raw+jpg+xmp never disagree; a setting switches RAWs to sidecar-only.
- Default write = ExifTool `-overwrite_original` (what the lab's "xmp embed" tool has done for
  years without corruption). ExifTool still writes a temp file and renames it, so a failed write
  leaves the original. Cheap checks only: ExifTool exit status and "1 image files updated", the
  file size is plausible afterwards, and only formats ExifTool declares writable (others fall back
  to the sidecar, logged).
- Setting "Verified RAW writes" (off by default): copy -> write -> image-data hash identical ->
  swap. It reads the whole RAW twice more over the network, hence opt-in.
- RAW writes run in a background queue with progress; the UI updates at once.
- Group members that disagree (written by another app): the most recently changed one wins -
  XMP MetadataDate when present, else file modification time; on a tie the sidecar wins. The
  winner's metadata is taken as a whole, emptied fields included (an empty field was probably
  cleared on purpose, so the emptiness propagates). Then all members are rewritten to match. Every multi-step operation is journaled; the next start finishes or rolls
it back and says so.

## 8. How we work (vibe coding, with guard rails)

- Claude writes the code. The user tests builds on real Macs and reports.
- Code lives in the GitHub repo. Every push runs CI on GitHub's Mac machines: legacy and
  modern builds, guard scripts, Swift self-tests, Python tests. Claude does not call
  anything done until CI is green.
- Releases are small: version bump, 5-minute test checklist in `docs/CHANGES.md`, a
  `PhotoLab2.dmg` artifact from CI.
- Testing on real hardware every release: one 10.13 Intel Mac, one Intel Mac on 11+, one
  Apple Silicon Mac. **The lab Macs are air-gapped**: results come back retyped by hand, so
  Help → Short Report gives ~8 lines with no paths or names, and every diagnostic that matters
  must fit in it or in a single self-test line. Full logs only when really needed.
- Logs: plain ASCII, one fact per line, stable error codes (`E-AREA-n`).
- Self-tests built into the app (`--self-test`, also Help menu): safety, listing,
  thumbnails/embedded previews, metadata round trip, protocol.
- Any new architecture choice gets a Decision Log entry.

## 9. Phases

Each phase ends in something the lab can use. Exit criteria are tested on all three Mac kinds.

0. **Toolchain proof** — DONE 2026-11-25 (0.0.1). Universal app built by Xcode 26 in CI,
   Swift runtime embedded for 10.13, bundled python-build-standalone 3.11 per architecture,
   brain connected on the user's 10.13 Mac; CI self-tests pass on Apple Silicon, under
   Rosetta, on a native Intel runner, and with the modern profile.
1. **Browser core** — 1a (0.1.0): volumes + sidebar, list view, navigation, bulk listing,
   watching, listing cache, logs, freeze watchdog — read-only. 1b (0.2.0): Trash, rename, new
   folder, undo, recovery journal (done 0.2.x). 1c: copy/move engine (0.3.x: clipboard, drag and
   drop, queue with progress, verified copies), then set rows + Ext column and the remaining
   browser parity items in docs/PARITY.md. Before 1b: 0.1.4 makes the list expandable (Finder list view
   with disclosure triangles, as PhotoLab 1's tree): "Loading..." placeholder row with a small
   spinner under an expanding folder, after 0.15 s.
2. **Contact sheet & preview** — thumbnail grid, embedded RAW previews, fast preview, Quick
   Look, ratings/labels/color classes with safe writes, filter bar, raw+jpg grouping.
3. **Brain & shared cache** — brain process, protocol, exif cache, thumbnail sharing,
   sync port, status badge. Groundwork for tools: `tools.list` / `tools.run` / job progress
   events; a tool is a Python module in a tools folder that reads assets through the brain
   (thumbnails, previews, exif, embeddings) and returns *proposed changes* (labels, ratings,
   keywords, collections) which the app applies through its one safe metadata writer.
4. **Lab tools** — copy/move with verification and queue, ingest, stationery, metadata
   editor, search.
5. **AI** — embeddings, semantic search, faces, culling, server mode as launchd job. First
   tools: "Goodbye Drill" (bad facial expressions -> colour label from settings), then the
   user's existing Python tools.
6. **Workflow** — saved workspaces/layouts, FTP, virtual collections.

## 10. Open questions

- ~~Q1~~ Resolved: python-build-standalone 3.11, one runtime per architecture in
  `Contents/Resources/python-<arch>`, fetched by `tools/fetch_python.sh`.
- Q2 (Phase 5): onnxruntime availability on 10.13–10.14.
- Q3: code signing / notarization — ad-hoc signing for internal use (as Find does) unless
  IT requires more.
- Q4: name and bundle id (working: "PhotoLab", `com.smp.photolab2`).

## Decision Log

- 2026-11-25 — Swift/AppKit app + Python helper process ("brain"); no Qt; no embedded Python. Why: speed of native APIs, crash isolation, keep Python where its ecosystem wins.
- 2026-11-25 — Fresh code inspired by Find, not a fork.
- 2026-11-25 — Universal build; x86_64 ≥ 10.13, arm64 ≥ 11.0; legacy/modern build profiles.
- 2026-11-25 — Shared cache keyed by (volume_id, rel_path, size, mtime) covers thumbnails/previews, exif results, embeddings, listings; listings used for search only, never shown as current.
- 2026-11-25 — GitHub repo + GitHub Actions macOS CI is the build loop.
- 2026-11-25 — Phase 0 done. Brain runtime = python-build-standalone 3.11 per architecture (x86_64 runs on 10.13, verified on the lab's 10.13 Mac). Nested binaries are signed one by one (codesign --deep rejects non-bundle folders).
- 2026-11-25 — Lab Macs are air-gapped; feedback is retyped. Short Report (no paths) is the primary channel; captured real-world data becomes self-test vectors.
- 2026-11-25 — getattrlistbulk: fixed part is 108 bytes; the file-size field is present only for files (smbfs/HFS+ omit it for folders). Fallback is per item / per folder / per volume, never session-wide.
- 2026-11-25 — Metadata is written into RAWs too (default; setting for sidecar-only), all group members kept identical; safeguards in section 7. Replaces "RAW files are never written".
- 2026-11-25 — Tools/plugins live in the brain and return proposed changes; the app is the only writer.
- 2026-11-25 — RAW writes default to ExifTool -overwrite_original without image-data verification (speed; years of clean use in the lab); "Verified RAW writes" is an opt-in setting. Conflicts: newest MetadataDate/mtime wins, sidecar on ties.
- 2026-11-25 — Conflict rule: the winner is taken as a whole; emptied fields propagate (user: clearing a field is intentional).
- 2026-11-25 — 0.2.0 file operations: sets = PhotoLab 1's GROUPABLE_EXTENSIONS (raws + jpg/jpeg/heic/heif + xmp/acr), a Settings switch, default on. Keys: Return/M rename, Cmd-E/Cmd-Down open, Backspace/Delete/Cmd-Backspace trash at once with undo. Shares without a Trash: items stay, never deleted.
- 2026-11-25 — Shares without a Trash: permanent delete after an explicit Finder-style confirmation (W-OPS-2 logged per item). Local volumes keep Trash + undo.
- 2026-11-25 — List shows one row per set while sets are on (Ext column after Name). Next work: copy/move engine, then browser parity, then contact sheet.
- 2026-11-25 — 0.3.0 copy/move engine in Swift (FileOperations + Platform), not the brain: the user waits on it. Hidden journaled temp name per top-level item, size + unchanged-source check per file, APFS clone on one volume, 8 MB byte copy otherwise (close() checked for SMB errors), xattrs/mode via copyfile, creation date via setattrlist. One serial queue per destination volume. No Replace on name clashes: Keep Both / Skip / Stop. Cross-volume moves remove verified, unchanged originals (exception 2 to "Trash only"); no undo for those. Copy undo = copies to Trash.
- 2026-11-26 — Finder tag display: read per row on screen (background, per-volume queue), cached until the file's ctime moves. Live updates: FSEvents (file events) for the folders on screen catch every change made on this Mac, local or share; other Macs' changes on shares are caught by a 5 s check of rows on screen only (stat, re-read where ctime moved, skipped while busy). No folder-wide polling.
