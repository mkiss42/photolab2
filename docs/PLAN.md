# PhotoLab - Plan

Living document. Every session reads this first. Decisions change only through the Decision Log
at the bottom (date, what, why).

## 1. What we are building

A native macOS photo-lab browser for a post-production lab working on busy SMB shares: a very fast
file browser + contact sheet + preview + metadata tools, with lab tools (ingest, stationery,
search, AI culling, shared cache between machines). It replaces PhotoLab 1 (Python + PyQt5).

**Since 2026-11-27 the code base is Find 0.18.16**, a coworker's Swift/AppKit app (file browser
with tabs and split panes, photography mode / contact sheet, IPTC metadata editor and templates,
verified metadata writes through a bundled ExifTool, search and index, FTP, batch rename, copy
queue, themes, safety self-check). It is renamed PhotoLab and becomes the one codebase. What
PhotoLab 1 and PhotoLab 2 (this repo's own app up to 0.9.2, branch `archive/pl2-0.9.2`) do better
or more economically is ported into it, feature by feature (section 4).

## 2. Hard requirements

| # | Requirement | Consequence |
|---|---|---|
| R1 | macOS 10.13 -> current, Intel and Apple Silicon | AppKit only, GCD/OperationQueue; universal binary: x86_64 >= 10.13, arm64 >= 11.0 (Find was Intel-only) |
| R2 | Upgrade path = "run this .sh instead of that one" | `build-legacy.sh` (Xcode 26, 10.13) / `build-modern.sh` (Xcode 27+, 12.0); both in CI |
| R3 | Built and tested by CI only | GitHub Actions (public repo: free): Apple Silicon (native + Rosetta), native Intel, modern profile. Modern Swift (5 mode); Find's Swift 4.1 shims may stay but need not be kept |
| R4 | Frugal with network IO; never freeze on a slow share | Main thread never touches a share; bulk listing; reads per file measured (PL2: ~2.6/file) |
| R5 | Never lose or damage user files | Find's safety design + the rules decided in section 5 |
| R6 | Air-gapped lab Macs | Diagnostics fit a short, path-free report the user can retype |

## 3. Architecture (Find's, extended)

Find: one process, AppKit. `Sources/Core` (logic, much of it Linux-testable), `Sources/Darwin`
(macOS primitives: BulkLister, DarwinPlatform - the only file-changing primitives -, ExifToolServer,
ImageMeta), `Sources/App` (UI). Self-tests: `--selfcheck` (57+ safety checks), `--searchtest`,
`--indextest`, `--phototest`, run by CI on every build.

Planned later (from PhotoLab 2's plan, unchanged in intent): the Python "brain" helper process
for the shared cache between machines, metadata search across the lab, ingest engine, AI
(embeddings, culling, "Goodbye Drill"). Not wired in yet.

## 4. Porting plan (Find + the best of PhotoLab 1 and 2)

Each item: verify Find's version first (keep it if it is as good), else port.

| # | Item | From | State |
|---|---|---|---|
| P1 | Bulk listing: 108-byte SMB folder records; fallback per folder, per volume after 3 | PL2 | done 1.0.0-alpha.2 |
| P2 | Read economy: one shared reader per file (FileReads), 256 KB first read, embedded JPEG in one request; READS/THUMBS figures | PL2 | done 1.0.0-alpha.3 (Find read the full-size preview for every thumbnail; ImageIO, facts, inspector and PDF now read through the shared reader; reads/file in the network I/O log's MINUTE lines) |
| P3 | Thumbnail sources by type: Nikon maker-note preview, camera-JPEG MPF previews, Photoshop thumbnail resource (PSD/TIFF/JPEG), PDF page 1, Quick Look on a slow lane, background track for the whole folder | PL2 | alpha.3: sources + PDF page 1 + thumbnails kept on disk (Caches/PhotoLab/Thumbs, 1 GB). Todo: Quick Look slow lane, background track for the whole folder |
| P4 | Contact sheet tiles as CALayers (GPU scrolling, no redraw) | PL2 | done alpha.7 (Find's ready-drawn cells kept as the caption bitmaps; the picture is its own layer; the view draws nothing while scrolling) |
| P5 | Preview for culling: zoom intent + pan memory between shots and Z in/out, final size probed from the header, Decode Full Image, selection-rest delay, documents in-window | PL2 + PL1 | done alpha.3 + alpha.8 (zoom canvas, pan memory, final size, delay, stars/colour in the caption, D = Decode Full RAW); mixed folders: Find's window already shows PDFs, text, audio/video and Quick Look documents as you arrow |
| P6 | Sets as one row + Ext column; set-aware rename/copy/trash; set rows drag whole sets | PL1 + PL2 | done alpha.8 in the list view (FileSets, Ext column, set-aware commands/rename/drag/metadata, status counts, T-PHOTO-48); thumbnail views keep Find's RAW+JPEG twins |
| P7 | Finder tags: live updates (FSEvents, light on-screen check on shares), dots, inline menu row | PL2 | done alpha.3 (TagCache: ctime per item, FSEvents per list folder, 5 s check of rows on screen on shares, list and contact sheet; removed tags now update too) |
| P8 | Menu bar icon (Favorites, Volumes, Network), app stays open, Dock drops, editable favourites | PL2 | done alpha.3 (menu bar icon with Favorites/Devices/Network/Servers, Option = front window; Dock / Open With drops, list or contact sheet; Find already stays open and has editable favourites) |
| P9 | Freeze watchdog (labelled activities) + Short Report for the air-gapped Macs | PL2 | alpha.3: Find's StallWatch kept (BEACHBALL lines); Help > Short Report (to Retype): version, READS, STALLS, thumbs on disk - no paths |
| P10 | Type-select cycling and nearest name | PL2 | done alpha.3 (same letter cycles, no match = nearest name, Space inside a typed name) |
| P11 | XMP:ColorClass master, xmp:Label kept in step | decision 2026-11-26 | done alpha.3 (both writers: ExifTool and Find's in-place XMP; Label = Red/Orange/Yellow/Green/Blue/Purple/Cyan/Gray for classes 1-8; T-PHOTO-45) |
| P12 | Brain, shared cache, ingest, AI, Goodbye Drill | PL2 plan / PL1 | later phases |
| P13 | Split panes / combo window (tree + sheet + inspector + tools) | user | Find has split panes; combo window to discuss |
| P15 | Activity light + activity window (only if cheap) | user | done alpha.11 (status bar dot: orange = network, blue = local disk; event-driven from the I/O logs, max 4 updates/s, nothing runs when idle; tooltip = what PhotoLab is busy with). Activity window: later, if wanted |
| P16 | FTP: PhotoLab 1's FTP logic (ftp_client.py / ftp_tree.py - PhotoLab 2 had none) (more reliable than Find's), opened in a pane / window like any folder, every FTP pane with PhotoLab 2's read-only console at the bottom | PL2 + user | alpha.15: Find's FTP kept (it already opens in a pane like any folder; the add-server problem was not a bug) + PhotoLab 1's read-only console under every FTP pane (curl -v traffic, password masked, 2000 lines; T-SAFE-66). alpha.16: console in a split view. alpha.17: one kept-open control connection per server (FTPSession, POSIX sockets, EPSV/PASV, PL1's reconnect budget of 3) for listings and commands, curl kept for transfers and as fallback; --ftptest in CI against pyftpdlib |
| P17 | Contact sheet cells like PhotoLab 2's: configurable metadata rows under the thumbnail, clickable stars, clearer colour classes / tags (PL2 ContactSheet.swift for reference) | PL2 + user | alpha.13: PhotoLab 1's tile (contactsheet.py): name, up to 4 chosen rows (camera, lens, dimensions, size, date taken, exposure, modified), badges, clickable stars on the colour-class band. Todo if wanted: PL1's 4 action buttons, hover highlight |
| P18 | Metadata editor: PhotoLab 1's window (metadata_editor.py) with Find's fields; Supplemental Categories shown as three fields SuppCat 1/2/3 (as Photo Mechanic and PhotoLab 1); the smart field at the bottom of the window | PL1 + user | todo |
| P19 | IPTC stationery (templates) after PhotoLab 1's metadata_stationery.py | PL1 + user | todo |

## 5. File-safety rules where Find and PhotoLab 2 differ (decided one by one)

| # | Situation | Find 0.18.16 | PhotoLab 2 0.9.2 | Decision |
|---|---|---|---|---|
| S1 | Name clash on copy/move | Keep Both / Skip / Replace (existing item to the Trash first) / Stop | Keep Both / Skip / Stop, never Replace | **decided 2026-11-27: Find's** (existing item to the Trash). Where there is no Trash (SMB/NFS/WebDAV): the dialog says so and its button reads "Replace (Delete Old)"; the old FILE is deleted only after the new one is in place under a "name 2" and verified; folders are never replaced there. No Undo. Done alpha.3 (T-SAFE-60..62) |
| S2 | Move to another volume | copy, verify, originals to the Trash (undoable) | copy, verify, delete originals that did not change meanwhile (not undoable) | **decided 2026-11-27:** Find's where there is a Trash; from a volume without a Trash, asked once ("Move / Copy Instead / Cancel"), then each original is deleted after its copy is verified and only if it did not change meanwhile (size + date of every file). No Undo. Done alpha.3 (T-SAFE-63..65) |
| S3 | Metadata write default | new version under a hidden name, read back and checked, then swapped; modes in Settings (default "fingerprint") | ExifTool -overwrite_original + cheap checks; verified mode opt-in (lab decision) | **decided 2026-11-28 (user): the fastest, cheapest way is the default** - in place where possible (only the metadata block is written), PhotoLab's byte check, no picture fingerprint, no flush; each can be turned back in Settings > Photography. Done alpha.12 |
| S4 | RAW rewritten with new metadata | previous version to the Trash as "NAME (before metadata edit).NEF" | (not built) | **decided 2026-11-27: no copy kept, ever** (user: "skip it always"). The new version is read back and checked, then the previous one is removed, RAWs like JPEGs. Done alpha.3 (T-PHOTO-28) |
| S5 | Where metadata goes | RAW sidecar (always kept up to date), XMP inside RAWs, IPTC in every picture; on by default | RAW + JPG + sidecar, setting for sidecar-only (lab decision) | **the same** in both (Settings 1-3 in Find = the lab decision); nothing to change |
| S6 | Conflicting values between set members | sidecar wins when newer than the file | newest MetadataDate/mtime wins, sidecar on ties, winner taken whole incl. empty fields (lab decision) | **decided 2026-11-27: the lab rule.** Done alpha.11: xmp:MetadataDate compared when both sides have one, else file dates; winner taken whole (T-PHOTO-50). Used everywhere: stars and colours shown, the inspector, and which set a write starts from (alpha.12) |

## 6. How we work

Claude writes the code; the user tests builds on real Macs (10.13 Intel, Intel 11+, Apple
Silicon) and reports by retyping short reports. Every push runs CI; nothing is called done
until CI is green. Releases are small, each with a <= 5-minute test checklist in docs/CHANGES.md.

## Decision Log

- 2026-11-25 - Swift/AppKit app + optional Python helper ("brain"); no Qt; no embedded Python.
- 2026-11-25 - Universal build; x86_64 >= 10.13, arm64 >= 11.0; legacy/modern profiles; GitHub Actions CI.
- 2026-11-25 - Lab Macs are air-gapped: short path-free reports are the main channel.
- 2026-11-26 - Repo public (free CI); no lab paths, names or retyped data in the repo.
- 2026-11-27 - **Find 0.18.16 becomes the code base** (user + coworker), renamed PhotoLab (bundle id com.smp.photolab, own folders ~/Library/.../PhotoLab, nothing carried over from Find). CI only (modern Swift, universal). One codebase from now on. PhotoLab 2 0.9.2 archived on branch archive/pl2-0.9.2. Where safety rules differ, the user decides each (section 5).
- 2026-11-27 - Safety rules S1-S6 decided (section 5): Find's Trash-based rules where there is a Trash; on shares without one, permanent deletes only after a dialog that says so and only after the new copy is verified; no "(before metadata edit)" copies at all.
- 2026-11-27 - The repo has two collaborators (user + coworker). Claude rebases on origin/main before every push.
- 2026-11-27 - Find's hidden temporary names (.find-partial-, .find-rename-) kept for now: its recovery and self-checks depend on them.
- 2026-11-27 - Opening several files: one request per application (LSOpenFromURLSpec with the app path), so Photoshop gets a range of RAWs as one Camera Raw session (alpha.4).
- 2026-11-27 - A DNG and another RAW with the same base name never share metadata (user's rule): "DSC_1.xmp" belongs to the camera RAW (and its JPEG twin); the DNG reads/writes only inside itself or its own "DSC_1.DNG.xmp". Applies to reading, writing, copy/move companions and the XMP badge (alpha.5, T-PHOTO-47 safety).
- 2026-11-27 - **DNGs never have an XMP sidecar** (user's rule, replaces the alpha.5 entry above): a DNG's metadata is read from and written into the DNG only (XMP always, IPTC as set), whatever the sidecar settings; no fallback sidecar if that fails (the failure is reported). Base-name sidecars belong to the other pictures only (alpha.6, T-PHOTO-47 safety).
- 2026-11-28 - RAW details (ImageIO properties) are read from the file URL, never through the shared reader: ImageIO's RAW support reads the whole file through a data provider (34 MB/file measured). Shared reader for JPEG/TIFF/PSD/PNG/HEIC and all embedded previews.
- 2026-11-28 - Contact sheet cells are CALayers (alpha.7), as PhotoLab 2's: the view draws nothing while scrolling.
- 2026-11-28 - Sets are rows only in the LIST view (FileNode.members); the thumbnail views keep showing files (Find's twins setting there), so grid selection and photo tools are unchanged. selectedEntries() = all members; selectedRowEntries() = representatives (preview, inspector).
- 2026-11-28 - The app's name in every user-visible text is PhotoLab (menus, dialogs, logs, reports); the find FUNCTION keeps its words ("Find...", "Find and Replace", "Find Duplicates"). Internal identifiers (notification names, pasteboard types, "find.*" queue labels) stay as Find had them.
- 2026-11-28 - Space on a single folder in the list view opens a new window on it in Photography mode (PL2 behaviour).
- 2026-11-28 - Contact sheet window (alpha.10): a BrowserWindowController with isContactSheet - one pane, Photography mode only, tabs always shown, no sidebar/path bar/navigation, folders hidden; 80% of the screen centred the first time, its frame remembered (not part of window reopening). Space on a folder = current tab of the front contact sheet window; Shift-Space = new tab; Shift-Space on a file = its folder in a new tab with the file selected. Supersedes the alpha.9 "new ordinary window".
- 2026-11-28 - Cmd-F = filter (PhotoLab 2's: names containing the text, every level, thumbnails too, ends on leaving the folder); Cmd-Shift-F = Find (search).
- 2026-11-28 - Settings: long explanations become tooltips of their control (found automatically from the built views), shown again with the "?" toggle; a search field marks sections and outlines the first hit.
- 2026-11-28 - PhotoLab 1 styling dropped from the plan (user). A "Native (macOS)" theme uses the system colours and appearance.
- 2026-11-28 - Metadata writes in the background mark their pictures (MetaPending): a turning ring on the thumbnail and "writing..." in the list until the write is done; details are read in chunks of 4 and a 3 px bar shows the progress (PhotoLab 1).
- 2026-11-28 - /Volumes is always shown in / (whatever the hidden-files setting).
- 2026-11-28 - FTP: one kept-open control connection per server (own POSIX-socket client, Sources/Core/FTPSession.swift; no Network.framework for 10.13) for listings and commands, logged in again by itself up to 3 times per command (PhotoLab 1). Transfers stay on curl (own connections, progress); a refused data connection over the session falls back to curl. CI runs --ftptest against a local pyftpdlib server.
- Earlier PhotoLab 2 decisions that still hold as intent (and are re-checked when the feature is ported): sets = PL1's GROUPABLE_EXTENSIONS; XMP:ColorClass master with xmp:Label in step; thumbnails 256 px from embedded previews; one preview mode (cheapest embedded >= ~1000 px, no RAW decode for the screen, Decode Full Image on request); preview reads wait for a selection-rest delay; tags read only for rows on screen.
