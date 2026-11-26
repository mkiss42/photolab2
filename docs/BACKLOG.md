# Backlog

Every idea goes here first, tagged with where it belongs. Order of work:
1. **Parity**: every PhotoLab 1 feature, transposed (Swift or brain) — tracked in `docs/PARITY.md`.
2. **Best of both**: what Find does better, folded in.
3. **New**: the user's further expansions.

An idea that changes architecture (data model, cache keys, protocol, window model) is scheduled
early even if its feature comes late, so nothing has to be rebuilt.

## Open

- **Styling like PhotoLab 1** (colours, density, tile look) when we get to styles.
- **Activity monitor** (nice to have; only if it stays cheap): a window with what PhotoLab is
  doing now (listing, thumbnails, copies, tag checks, brain), counters, and a read-only tail of
  the last log lines; plus a small activity light at the bottom right of every window (idle /
  disk or share read / poll / change event received / writing). Cheap design: the light reads
  the existing Activity label and counters twice a second; nothing new runs in the file paths.

- **Split panes like Find** (two or more file panes in one window, side by side / stacked).
- **Combo window**: folder tree left, contact sheet middle, metadata inspector + tools right.
  To be discussed when we get there (Phase 2/4).

- **Setting: items dropped on the app icon open in the tree or in the contact sheet** (Phase 2).
- **Text paths dropped on the app icon:** macOS only delivers files/folders to a Dock icon;
  a typed/pasted path works through Go > Go to Folder (Cmd-Shift-G). Revisit with Services.

- **Folder merge on copy** (copy engine, later): copying a folder onto one with the same name
  could offer "Merge" (add missing files, keep both on file clashes). 0.3.0 offers Keep Both / Skip.

| # | Idea | From | Kind | Phase |
|---|---|---|---|---|
| 1 | Spinner while a folder loads: big one in the list (enter), small one in status (re-read), "Loading..." row under an expanding folder | user 2026-11-25 | parity+ | done 0.1.3 + 0.1.4 |
| 2 | Expandable list (disclosure triangles, PhotoLab 1 tree behaviour) | user 2026-11-25 | parity | done 0.1.4 |
| 3 | One SMB folder lists empty - was a mix-up, not a bug; the readdir re-check stays as a safety net | user 2026-11-25 | bug | closed |
| 4 | Full parity checklist from PhotoLab 1 source (`docs/PARITY.md`) | user 2026-11-25 | process | with 0.1.4 |
| 5 | Metadata written into RAWs as well as sidecars and JPEGs; every field kept identical across raw+jpg+xmp. Setting: "sidecar only" for RAWs. Default: write everything | user 2026-11-25 | new (changes safety rule) | 2 (design), 4 |
| 6 | Tools / plugins in the brain (Python): e.g. "Goodbye Drill" marks bad facial expressions with a colour label (colour from settings). Port the user's existing Python tools later | user 2026-11-25 | new (affects protocol) | 3 groundwork, 5 tools |
| 7 | Sidebar hidden by default; app remembers the state of the last browser window closed and restores it on relaunch | user 2026-11-25 | UI | done 0.1.5 |
| 8 | Sidebar default width 160 px, width remembered, snaps to 160 while dragging (split view delegate) | user 2026-11-25 | UI | done 0.1.5 |
| 9 | Sidebar toggle button + Cmd-Option-S | user 2026-11-25 | UI | done 0.1.5 |
| 10 | Setting: path (crumb) bar on top or bottom - needs the Settings window | user 2026-11-25 | UI | done 0.1.5 |
| 11 | Name column always takes all free width, other columns fixed; user-resized widths kept for that window until it closes, new windows start with defaults | user 2026-11-25 | UI | done 0.1.5 |
| 12 | Path bar reaches / (Macintosh HD > Volumes > ...) | user 2026-11-25 | UI | done 0.1.5 |
| 13 | Path bar below moves only the path; nav buttons stay on top | user 2026-11-25 | UI | done 0.1.6 |
| 14 | Spinner in the centre when entering a folder (overlay fix) | user 2026-11-25 | bug | done 0.1.6 |
| 15 | Cmd-Option-S sidebar toggle did not work | user 2026-11-25 | bug | done 0.1.6 |
| 16 | Sidebar button as an icon | user 2026-11-25 | UI | done 0.1.6 |
| 17 | "/" shown as Computer; computer icon only in the path bar | user 2026-11-25 | UI | done 0.1.6 |
| 18 | Cmd-Option-C copies selected paths; path bar right-click: Copy Path / Copy Full Path | user 2026-11-25 | UI | done 0.1.6 |
