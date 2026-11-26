# Parity with PhotoLab 1

Every PhotoLab 1 feature, and where it stands in PhotoLab 2.
Status: **done** · **part** (exists, something missing) · **todo** (phase in brackets) · **drop** (on purpose, with reason).
"Audited" = the PhotoLab 1 module was read line by line for this list.

## Browser (audited: folder_tree2.py, main.py)

| PhotoLab 1 | Status | Notes |
|---|---|---|
| Several folder windows ("trees"), Cmd-N | done | |
| Lazy tree, expand folders, Loading row | done | |
| cd in (double-click, Cmd-Down), up (Cmd-Up) selects the folder you came from | done | |
| Breadcrumb path bar, click to navigate | done | path bar on top/bottom setting |
| Path bar menu: Copy Path / Copy Full Path | done | new in PL2 |
| Path bar menu: Paste Into, Open in New Tree | todo (1c) | Paste Into needs the copy engine |
| Sorting: name / ext / modified, folders on top | done | PL2 adds size and kind |
| One row per set (raw+jpg+xmp as one row) while Settings > Files sets are on; an Ext column right after Name shows "CR3+JPG+XMP" | done (0.4.0) | decided 2026-11-25 |
| Display modes: folders only / current folder's files / expanded folders' files / all | todo (1c) | "folders only" is the useful one |
| Quick mode (name only), icon style Pretty/Generic/None, show ext / modified columns | todo (1c) | columns show/hide via header menu |
| Finder colour tag dots on rows | todo (1c) | |
| Context menu tag swatches: add/remove Finder tags (multi-select, partial state) | todo (1c) | |
| Filter bar (Cmd-F), filters the visible tree incl. expanded folders, Esc clears | todo (1c) | |
| Type-to-select, same letter cycles | part | AppKit type-select; same-letter cycling missing |
| Return renames; multi-select Return -> batch rename | part | single rename done (also M); batch renamer was a TODO in PL1 too -> todo (4) |
| New Folder (Cmd-Shift-N) | done | PL1 asked for a name in a dialog; PL2 renames in place |
| Delete / Backspace | done | Trash + undo; shares: confirmed delete |
| Cmd-C copies files (set-expanded) to the clipboard; Cmd-V pastes (copies) into the folder | done (0.3.0) | + Cmd-Option-V moves, Cmd-D duplicates |
| Drag out (set-expanded file URLs); drop into folders: move on same volume, copy across, Option = copy; drop highlight, autoscroll | done (0.3.0) | set rows drag all their files (0.4.0) |
| Drop from the FTP browser | todo (6) | with FTP |
| Cmd-/ force refresh (expanded folders too) | done | Cmd-R; add Cmd-/ alias (1c) |
| Refresh Selected (re-read; nuke derived caches for files) | todo (3) | caches arrive with the brain |
| Open, Open With submenu | part | Open done; Open With todo (1c) |
| Reveal in Finder, Reveal in New Folder Tree | todo (1c) | |
| Cmd-I Finder Get Info | todo (1c) | |
| Opt-I metadata editor | todo (2) | |
| Space: file -> preview, folder -> contact sheet; Opt-Space new tab; Shift-Space current tab | todo (2) | |
| Open in Contact Sheet (+ New Tab, + Recursive) | todo (2) | |
| Apply Metadata Template (stationery) | todo (4) | |
| Status line: files / folders / selected, counting expanded folders | part | counts the folder on screen only |
| Tooltip: folder's asset count, file path | todo (1c) | |
| Eject from /Volumes (PL1 TODO: Cmd-E ejects there) | todo (1c) | Cmd-E is Open now; eject via menu/context menu |
| Dock-icon drops / Finder "Open With PhotoLab": open folders, select dropped files | todo (2) | in contact sheet tabs, as PL1 |
| Window geometry remembered | done | |
| Watching only active (visible/expanded) folders | done | |

## Contact sheet (audited: contactsheet.py)

| PhotoLab 1 | Status | Notes |
|---|---|---|
| Grid of tiles: thumbnail, name + extensions, up to 5 metadata rows | todo (2) | |
| Stars (0-5) and colour labels (0-8) on tiles, click to set | todo (2) | |
| Tile buttons: preview, reveal, edit, info | todo (2) | |
| Size slider 80-400 | todo (2) | |
| Filter bar: stars and colour labels, Alt-click solo | todo (2) | |
| Selection: click, Cmd-click, Shift-click, arrows, Shift/Cmd-arrows, Cmd-A | todo (2) | |
| Rating / label shortcuts with configurable modifiers | todo (2) | |
| M rename, Space preview, I metadata editor, Return open, Cmd-E open batch | todo (2) | |
| Tabs, "+" tab, several windows, drag tabs between windows | todo (2) | |
| Search-results and recursive tabs (protected, not replaced by navigation) | todo (2/4) | |
| Live updates from the watcher (add/remove/changed sig -> new thumb) | todo (2) | |
| Drag out / drop in (move/copy) | todo (2) | with the copy engine |
| Context menu: open, open with, ratings, labels, template, rename, refresh, copy path, copy, reveal (Finder/tree), delete | todo (2) | |
| Metadata loading progress bar, item count | todo (2) | |

## Preview (audited: image_service.py; preview_3.py not yet)

| PhotoLab 1 | Status | Notes |
|---|---|---|
| Fast preview window following the focused item (tree or sheet), arrow navigation | todo (2) | Find-style FastPreview |
| Tiers: thumb -> embedded JPEG -> viewport -> largest embedded -> full decode | todo (2) | ImageIO; no subprocess pools |
| Zoom (Z), 1:1 | todo (2) | |
| Decode Raw button / full raw decode setting | todo (2) | CoreImage RAW; brain rawpy only if needed |
| Prefetch neighbours | todo (2) | |

## Backend (audited: service_registry.py, asset_sync.py, volumes.py, server_mode.py, ingest_service.py)

| PhotoLab 1 | Status | Notes |
|---|---|---|
| Stable volume ids (marker / disk UUID / mount source) | todo (3) | brain + Swift twin |
| P2P sync (mDNS, sequenced log, store deltas, snapshots) | todo (3) | re-scoped to the shared cache |
| Shared cache: exiftool results, embeddings | todo (3) | + thumbnails, listings (search only) |
| Server mode (local disks only, recursive watch, embedding backfill) | todo (5) | headless launchd job |
| Ingest engine (sets, templates, staging for remote, journal, erase/eject) | todo (4) | brain + Swift UI |
| Metadata service, ExifTool daemon, TemplateSubstitutor | todo (2-4) | |
| AI: models, embeddings, semantic search | todo (5) | |
| Search (metadata) | todo (4) | |
| FTP client | todo (6) | |
| Asset DB / topology as source of truth for the tree | drop | PL2 reads the disk (bulk listing); DB is a cache only |
| Subprocess preview pools, shared memory, deficiency engine, memo DB | drop | ImageIO in-process |
| pipeline_telemetry | drop | logs + Short Report |

## File operations (audited: fs_ops_manager.py, fs_ops_panel.py)

| PhotoLab 1 | Status | Notes |
|---|---|---|
| Copy / move / rename / delete on background threads, progress per job | done (0.3.0) | one serial queue per destination volume |
| Group expander: a set travels whole | done (0.3.0) | also skipped / numbered as one |
| Safe mode: temp file + atomic rename, size verify | done (0.3.0) | temp is hidden + journaled; whole folder under one temp name; source must be unchanged |
| Containment guard (no copy into itself), listing before mkdir, depth guard | done (0.3.0) | scan first, then write |
| Skip AppleDouble `._` and own temps when copying | done (0.3.0) | |
| Cross-device move: per source, originals deleted only if every file copied | done (0.3.0) | stricter: only unchanged originals, files one by one |
| Failures recorded and continue; summary at the end | done (0.3.0) | E-OPS-6 per item, sheet at the end |
| Mac metadata: copystat, xattrs, SetFile birthtime | done (0.3.0) | copyfile XATTR+STAT, setattrlist crtime (no SetFile binary) |
| Conflicts: pause, "skip all" or cancel | done (0.3.0) | Keep Both / Skip / Stop; never Replace |
| Undo (journal rollback) | done (0.3.0) | copy: to Trash; same-volume move: rename back; cross-volume move: none |
| Panel: auto-show, row per job, cancel, auto-hide after 4 s | done (0.3.0) | shown only after 0.6 s |
| Per-job settings (workers, chunk size) | drop | one tuned path: clone, else 8 MB chunks |
| SQLite history of the last 100 operations | todo (later) | the log has every job line for now |
| Folder merge on clash | todo (BACKLOG) | PhotoLab 1 merged silently (exist_ok); PL2 asks Keep Both / Skip |

## Not audited yet

crumb_bar, sidebar_left, toolbar, dock_manager, combo_win,
mainwindow, preview_3, metadata_editor, metadata_panel, metadata_fields, metadata_stationery,
search_dialog, star_widget, color_widget, tag_menu, open_with, ftp_tree, ftp_client,
ingest_dialog, server_config_dialog, app_prefs + settings_config.json, style, splash.
Each is audited at the start of the phase that ports it.

## Decisions

1. 2026-11-25 — One row per set while sets are on, with the set's extensions in an Ext column
   right after Name (PhotoLab 1 style). Sets off: every file is its own row.
2. 2026-11-25 — Order: copy/move engine first (Cmd-C/V, drag and drop, progress, verification),
   then the remaining browser items, then the contact sheet.
