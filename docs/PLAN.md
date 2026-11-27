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
| P4 | Contact sheet tiles as CALayers (GPU scrolling, no redraw) | PL2 | todo - measure Find's grid first |
| P5 | Preview for culling: zoom intent + pan memory between shots and Z in/out, final size probed from the header, Decode Full Image, selection-rest delay, documents in-window | PL2 + PL1 | alpha.3: in Find's Space window (keeps Find's rule that the list keeps the keys): zoom canvas (Z / double-click, Cmd =/-/0, Cmd-scroll/pinch at the pointer), pan kept between shots and across Z, final size from the header, bigger version loaded when zoomed, selection-rest delay (Settings). Todo: stars/colours shown in the preview, Decode Full Image button, documents arrowed through in-window |
| P6 | Sets as one row + Ext column; set-aware rename/copy/trash; set rows drag whole sets | PL1 + PL2 | todo - check Find's sidecar handling |
| P7 | Finder tags: live updates (FSEvents, light on-screen check on shares), dots, inline menu row | PL2 | done alpha.3 (TagCache: ctime per item, FSEvents per list folder, 5 s check of rows on screen on shares, list and contact sheet; removed tags now update too) |
| P8 | Menu bar icon (Favorites, Volumes, Network), app stays open, Dock drops, editable favourites | PL2 | done alpha.3 (menu bar icon with Favorites/Devices/Network/Servers, Option = front window; Dock / Open With drops, list or contact sheet; Find already stays open and has editable favourites) |
| P9 | Freeze watchdog (labelled activities) + Short Report for the air-gapped Macs | PL2 | alpha.3: Find's StallWatch kept (BEACHBALL lines); Help > Short Report (to Retype): version, READS, STALLS, thumbs on disk - no paths |
| P10 | Type-select cycling and nearest name | PL2 | done alpha.3 (same letter cycles, no match = nearest name, Space inside a typed name) |
| P11 | XMP:ColorClass master, xmp:Label kept in step | decision 2026-11-26 | done alpha.3 (both writers: ExifTool and Find's in-place XMP; Label = Red/Orange/Yellow/Green/Blue/Purple/Cyan/Gray for classes 1-8; T-PHOTO-45) |
| P12 | Brain, shared cache, ingest, AI, Goodbye Drill | PL2 plan / PL1 | later phases |
| P13 | Split panes / combo window (tree + sheet + inspector + tools) | user | Find has split panes; combo window to discuss |
| P14 | Styling like PhotoLab 1 | user | later |
| P15 | Activity light + activity window (only if cheap) | user | later |

## 5. File-safety rules where Find and PhotoLab 2 differ (decided one by one)

| # | Situation | Find 0.18.16 | PhotoLab 2 0.9.2 | Decision |
|---|---|---|---|---|
| S1 | Name clash on copy/move | Keep Both / Skip / Replace (existing item to the Trash first) / Stop | Keep Both / Skip / Stop, never Replace | **decided 2026-11-27: Find's** (existing item to the Trash). Where there is no Trash (SMB/NFS/WebDAV): the dialog says so and its button reads "Replace (Delete Old)"; the old FILE is deleted only after the new one is in place under a "name 2" and verified; folders are never replaced there. No Undo. Done alpha.3 (T-SAFE-60..62) |
| S2 | Move to another volume | copy, verify, originals to the Trash (undoable) | copy, verify, delete originals that did not change meanwhile (not undoable) | **decided 2026-11-27:** Find's where there is a Trash; from a volume without a Trash, asked once ("Move / Copy Instead / Cancel"), then each original is deleted after its copy is verified and only if it did not change meanwhile (size + date of every file). No Undo. Done alpha.3 (T-SAFE-63..65) |
| S3 | Metadata write default | new version under a hidden name, read back and checked, then swapped; modes in Settings (default "fingerprint") | ExifTool -overwrite_original + cheap checks; verified mode opt-in (lab decision) | **decided 2026-11-27:** Find's fastest mode becomes the default if it measures as fast as -overwrite_original - to measure (todo) |
| S4 | RAW rewritten with new metadata | previous version to the Trash as "NAME (before metadata edit).NEF" | (not built) | **decided 2026-11-27: no copy kept, ever** (user: "skip it always"). The new version is read back and checked, then the previous one is removed, RAWs like JPEGs. Done alpha.3 (T-PHOTO-28) |
| S5 | Where metadata goes | RAW sidecar (always kept up to date), XMP inside RAWs, IPTC in every picture; on by default | RAW + JPG + sidecar, setting for sidecar-only (lab decision) | **the same** in both (Settings 1-3 in Find = the lab decision); nothing to change |
| S6 | Conflicting values between set members | sidecar wins when newer than the file | newest MetadataDate/mtime wins, sidecar on ties, winner taken whole incl. empty fields (lab decision) | **decided 2026-11-27: the lab rule.** Find already takes the newer FILE whole (tie = sidecar); still to add: compare xmp:MetadataDate first when both sides have one (todo, with P6/P11) |

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
- Earlier PhotoLab 2 decisions that still hold as intent (and are re-checked when the feature is ported): sets = PL1's GROUPABLE_EXTENSIONS; XMP:ColorClass master with xmp:Label in step; thumbnails 256 px from embedded previews; one preview mode (cheapest embedded >= ~1000 px, no RAW decode for the screen, Decode Full Image on request); preview reads wait for a selection-rest delay; tags read only for rows on screen.
