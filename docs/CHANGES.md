# Changes

## 0.5.0 — Finder tags, totals, type-select cycling

- Finder tags in the list: coloured dots after the name, like Finder. Read in the background,
  only for rows on screen (one small request per file on a share), so big folders stay fast.
  Re-read when the folder is (Cmd-R, or a change is seen).
- Right-click > Tags: the seven Finder colours; a tick when every selected file has it, a dash
  when some do. Choosing one adds it to all selected files (whole sets), or removes it when all
  have it. Other tags (names without colour) are kept. Cmd-Z undoes, Cmd-Shift-Z redoes.
  Copies keep their tags.
- Status bar: "7 items (1 set, 9 total)" - rows, sets, and files counting every set member.
- Type-select cycles: pressing the same letter again goes to the next name starting with it.
- Tooltip on a folder shows its item count when it has been listed (expanded or visited).
- (XMP colour labels are separate and come with the contact sheet.)

Test checklist (3 minutes):
[ ] 1  A folder with Finder-tagged files: dots after the names (compare with Finder).
[ ] 2  Right-click a set row > Tags > Red: Finder shows Red on all three files. Cmd-Z: gone.
[ ] 3  Select two files, one red: Tags menu shows a dash at Red; choose Red: both red.
[ ] 4  Press "c" three times: the third name starting with c is selected.
[ ] 5  Status bar on a folder with sets: "N items (S sets, T total)".


## 0.4.3 — path bar: Paste Into, Open in New Window

- Right-click any folder in the path bar: Paste Into (copies the clipboard's files there),
  Move Items Into, Open in New Window - next to Copy Path / Copy Full Path.

Test checklist (1 minute):
[ ] 1  Cmd-C a file, right-click a parent folder in the path bar > Paste Into: copied there.


## 0.4.2 — filter bar

- Cmd-F (Edit > Filter...) opens a filter field above the list. Typing keeps only rows whose
  name contains the text (any case; a set matches by any of its files). Expanded folders stay
  open and are filtered too. Down arrow or Return jumps to the list; Esc clears and closes it.
  Going to another folder clears the filter. The status bar shows the active filter.

Test checklist (1 minute):
[ ] 1  Cmd-F, type part of a file name: only matching rows; expanded folders filtered too.
[ ] 2  Down arrow: into the list. Cmd-F, Esc: everything back, expansion unchanged.


## 0.4.1 — Finder actions, columns, folders only

- Right-click: Open With (default app first, Other...), Open in New Window (folders), Show in
  Finder, Get Info, Eject (volumes). Same in the File menu: Open in New Window Cmd-Option-Down,
  Show in Finder Cmd-Shift-R, Get Info Cmd-I, Eject. Cmd-double-click a folder: new window.
- Get Info asks once for permission to control Finder (macOS asks, like the folder prompt).
- Eject: windows showing the volume move to /Volumes first.
- View > Show Folders Only (remembered).
- Right-click the column header to hide or show Ext / Date Modified / Size / Kind (remembered).
- Status bar counts every row on screen, expanded folders included, and how many are sets.
- Cmd-/ refreshes too (PhotoLab 1's key).
- Tooltips: a file's full path; a set row lists its files.

Test checklist (3 minutes):
[ ] 1  Right-click a JPG > Open With: apps listed, default first; one opens it.
[ ] 2  Cmd-I: Finder's info window (allow the prompt once). Cmd-Shift-R: Finder shows it.
[ ] 3  In /Volumes select a share > Eject: it disappears.
[ ] 4  Header right-click: hide Kind; new window: still hidden.
[ ] 5  View > Show Folders Only; expand a folder: status bar counts the expanded rows.


## 0.4.0 — one row per set, Ext column

- With sets on (Settings > Files, default), raw + jpg/heic + xmp with the same name are one row:
  the name without extension, and a new Ext column right after Name: "CR3+JPG+XMP". Size is the
  whole set; Date Modified the newest member. Hover the name to see the member files.
  Ordinary files show their extension in Ext; click the Ext header to sort by it.
- Renaming a set row edits just the name; every member keeps its extension.
- Dragging a set row to Finder (or anywhere) now carries all of its files.
- Turning sets off in Settings shows every file as its own row again, at once.

Test checklist (3 minutes):
[ ] 1  A folder with RAW+JPG+XMP sets: one row each, Ext "CR3+JPG+XMP", a PSD of the same name
       is its own row.
[ ] 2  Return on a set row: only the name is selected; type a new one: all three renamed.
[ ] 3  Drag a set row to a Finder window: all three files arrive.
[ ] 4  Settings > Files off: separate rows; on again: back to one row.


## 0.3.1 — Short Report fixes

- "up N min" counts from launch (it showed 0 min: the clock started when the report opened).
- Freezes during copying, dragging and the clipboard are now named in the FREEZE line
  (copy, drag, clipboard) instead of "idle", so the 0.3 s stalls can be found.

Test checklist (1 minute): use PhotoLab for a few minutes with some copies and drags, then
Short Report: "up" shows the real minutes; FREEZE names what it was during.


## 0.3.0 — copy, paste, drag and drop, duplicate

- Cmd-C copies the selected files (with their whole set) to the clipboard; they paste in PhotoLab
  and in Finder. Cmd-V pastes (copies) into the folder of the selection, or into the window's
  folder. Cmd-Option-V moves them there instead (Finder's "Move Items Here"). Cmd-D duplicates
  ("IMG_1 copy.CR3", a set stays a set). Also in the right-click menu and the Edit / File menus.
- Drag and drop: drag rows to another folder, window or Finder; drop on a folder row (into it) or
  anywhere else (into the folder shown). Like Finder: moves on the same volume, copies to another
  one; hold Option to copy, Command to move. Drops from Finder work too.
- Sets travel whole: dropping or pasting a RAW brings its JPG and XMP.
- Never overwrites. A taken name asks once: Keep Both ("IMG_1 2.CR3", the whole set gets the same
  number), Skip, or Stop. There is no Replace.
- Safe copies: each item is written under a hidden name and only gets its real name when every
  file in it is complete and the same size as the original, and the original did not change
  meanwhile. Stop, a crash or a pulled cable never leave half-copied files under real names;
  the next launch removes the hidden leftovers and says so.
- Moves on one volume are instant renames. Moves to another volume copy, verify, and only then
  remove the originals - and only the ones that did not change during the move.
- Progress window (appears for copies longer than 0.6 s): bar, files, bytes, MB/s, Stop.
- Undo: copy (the copies go to the Trash; on a share, after the delete warning), move on one
  volume (moved back). A move to another volume can't be undone.
- Short Report: new COPY line (jobs, files, MB, MB/s per local/share, failures). Warnings the
  self-test causes on purpose (its own test delete, simulated stops) no longer count in CODES -
  the W-OPS-2 in your 0.2.1 report was most likely the self-test, not your share delete.

Test checklist (5 minutes; scratch folders, one local, one on a share):
[ ] 1  Select a RAW with JPG+XMP, Cmd-C, click into another folder, Cmd-V: all three copied.
[ ] 2  Cmd-V again: the Keep Both / Skip / Stop question. Keep Both: "... 2" for all three.
[ ] 3  Cmd-Z: the copies go away (on a share: the delete warning first).
[ ] 4  Drag a folder of a few GB from local to a share: progress window, MB/s. Press Stop:
       nothing named like the folder is left on the share.
[ ] 5  Drag a file within one share to a subfolder: moved at once. Cmd-Z: back.
[ ] 6  Option-drag: copies instead. Cmd-D on a file: "name copy".
[ ] 7  Short Report: COPY line shows the share MB/s; CODES has no E-OPS.

## 0.2.1 — delete on shares without a Trash

- On a share with no Trash, Move to Trash now asks, like Finder: "This share has no Trash. The items
  will be deleted for good. You can't undo this action." Delete / Cancel (Return does NOT delete;
  Esc cancels). Each deleted item is logged (W-OPS-2). Local disks still use the Trash and Cmd-Z.
- The self-test's simulated interrupted rename no longer shows as W-OPS-1 in the Short Report.

Test checklist (2 minutes, scratch files on a share):
[ ] 1  Backspace on a file on a share: the warning appears. Cancel: the file stays.
[ ] 2  Again, click Delete: it is gone. Same with a RAW set: the whole set is listed and deleted.
[ ] 3  Short Report: CODES shows W-OPS-2 per deleted item, no W-OPS-1.

## 0.2.0 — rename, new folder, Trash, undo (first release that changes files)

- Rename: Return or M (M right after typing other letters is still type-to-select). The name
  without its extension is selected; Esc cancels. Cmd-E, Cmd-Down and double-click open.
- Sets (Settings > Files, on by default): raw + jpg/jpeg/heic + xmp/acr with the same name rename
  and go to the Trash together, exactly PhotoLab 1's grouping (tif/psd/png never join a set).
  Changing the extension while renaming renames only that one file.
- Never overwrites: a name already in use refuses the whole rename and changes nothing. A set is
  renamed all-or-nothing; if one file fails, the others are put back.
- Move to Trash: Cmd-Backspace, Backspace or Delete, at once. Nothing is ever deleted permanently;
  if a share has no Trash the items stay where they are and PhotoLab says so.
- Undo / Redo (Cmd-Z / Cmd-Shift-Z): rename, Move to Trash (puts back), New Folder.
- New Folder: Cmd-Shift-N, starts renaming it.
- Right-click an item: Open, Rename, Copy Path, New Folder, Move to Trash.
- Crash safety: a multi-file rename is journaled; if PhotoLab stops in the middle, the next launch
  gives the files their old names back and says so.
- App Nap is off for PhotoLab, so folder polling keeps its timing in the background (and the
  occasional 0.26 s "idle" freeze was most likely the Mac napping the app).

Test checklist (5 minutes) - please use a scratch folder first, then a share:
[ ] 1  Rename a RAW that has a JPG and XMP: all three get the new name. Cmd-Z: all three back.
[ ] 2  Rename onto a name that exists: refused, nothing changed.
[ ] 3  Settings > Files off: rename the RAW alone. Turn it back on.
[ ] 4  Backspace on a RAW of a set: the set goes to the Trash (the PSD stays). Cmd-Z: back.
[ ] 5  On a share: Backspace. Moved to the share's Trash, or a message that it has none?
[ ] 6  Cmd-Shift-N: "untitled folder" appears in rename mode. Type a name, Return.
[ ] 7  Help -> Run Self-Test (new ops-* lines) and Short Report.

## 0.1.6 — spinner on enter, Computer, copy paths

- Fixed: no spinner (and no "Empty folder" text) in the list - they were inside the list's scroll
  view and got drawn over. They now float above the list, centred.
- Fixed: Cmd-Option-S toggles the sidebar (caught before the menu).
- Path bar below the list moves only the path; the Back/Forward/Up/Sidebar buttons stay on top.
- Sidebar button is an icon.
- "/" is called Computer; in the path bar it is the computer icon alone.
- Edit > Copy Path (Cmd-Option-C): paths of the selected items, one per line (the folder itself
  when nothing is selected).
- Right-click a path bar item: Copy Path (up to that item) / Copy Full Path.
- Short Report is longer: what the app was doing during freezes, folders served from memory,
  watcher events, slow icon loads.

Test checklist (4 minutes):
[ ] 1  Enter a slow share folder: spinner + "Reading..." in the middle of the list.
[ ] 2  Cmd-Option-S toggles the sidebar.
[ ] 3  Settings: path bar below -> buttons stay on top, path moves under the list.
[ ] 4  Cmd-Option-C on two selected files, paste into a text editor: two paths.
       Right-click a path bar item: both copy options.
[ ] 5  Help -> Short Report (now ~13 lines).

## 0.1.5 — expand loop fixed, sidebar and path bar options

- Fixed: expanding a folder could flicker endlessly and rows slid over each other (0.1.4). Cause:
  refreshing an open folder's rows makes macOS announce "expanding" again, which PhotoLab answered
  with a new listing, forever. Expansions caused by PhotoLab itself are now ignored.
- Path bar shows the whole chain from / (/ > Volumes > Share > ...); click any level. Cmd-Up goes all
  the way to /. The start-up disk is called "/" everywhere (no invented "Macintosh HD").
- /Volumes is always shown in /, although macOS marks it hidden.
- Sidebar: hidden by default; Sidebar button and Cmd-Option-S toggle it; 160 px by default, snaps to
  160 when dragged near it, width remembered; the last window closed decides the state at next launch.
- PhotoLab > Settings (Cmd-,): "Path bar below the list".
- The Name column always takes the free width; other columns keep their size. Resized widths last
  until the window closes; new windows start from the defaults.

Test checklist (4 minutes):
[ ] 1  Expand folders quickly, several in a row, on a share: no flicker, no sliding rows.
[ ] 2  Click "/" in the path bar, and press Cmd-Up repeatedly from deep in a share: Volumes is listed in /.
[ ] 3  Sidebar: Cmd-Option-S and the button; drag it near 160 (snaps); quit with it shown, relaunch.
[ ] 4  Settings: path bar below. Resize the window: only the Name column grows.
[ ] 5  Help -> Short Report.

## 0.1.4 — expandable list

- Folders in the list have disclosure triangles (click, or Right/Left arrow; Option-click a
  triangle is Finder's "expand all" and is not supported yet). Double-click a folder to go into it.
- Expanding a folder that takes longer than 0.15 s shows a "Loading..." row with a small spinner
  directly under it.
- Expanded folders stay open when the list is re-read, and each one is watched: changes inside
  an expanded folder update just that folder. Cmd-R re-reads the folder and every expanded one.
- Diagnostics for the ~0.3 s freeze seen in every session: slow icon loads are logged.

Test checklist (4 minutes):
[ ] 1  On a share, expand a few folders, including a slow one: "Loading..." row with spinner, then
       its contents. Expand a folder inside an expanded folder.
[ ] 2  Have someone add a file inside an expanded folder: it appears within ~5 s, nothing collapses.
[ ] 3  Sort by another column with folders expanded: they stay expanded, sorted inside too.
[ ] 4  Double-click an expanded folder's subfolder: the window goes into it.
[ ] 5  Help -> Short Report: type it back.

## 0.1.3 — empty-folder safety net, spinners

- A bulk listing that comes back empty is checked once with readdir; if readdir finds items they
  are shown and W-LIST-3 is logged (appears in the Short Report CODES line).
- Empty listings are never remembered, so revisiting a folder always reads it again.
- A folder made only of hidden items now says how many there are.
- Spinners after 0.15 s: big one in the list when entering a slow folder, small one in the status
  line while the folder on screen is re-read.
- Short Report LIST lines add the item count of the slowest folder and how many were empty.

Test checklist (2 minutes):
[ ] 1  Go back to the folder that showed 0 items. Does it list now? What does the status line say?
[ ] 2  Enter a slow share folder: a spinner shows until the list appears.
[ ] 3  Help -> Short Report: type the LIST share and CODES lines.

## 0.1.2 — bulk listing fixed for folders on SMB and HFS+

- Cause found from the 0.1.1 log: for folders, smbfs (and HFS+ on 10.13) leave out the 8-byte size
  field, so the record is 112 bytes, not 116. That is valid; PhotoLab wrongly called it broken.
  Shares now list in bulk. The three records from the lab's servers are permanent self-test cases.
- Help -> Short Report: ~8 lines, no paths or names - safe to retype from an air-gapped Mac.
- Self-test results open in a normal window (the old modal box was logged as a 35-second FREEZE).
- The freeze watchdog no longer mistakes an open menu for a freeze.
- "brain exited with status 15" was PhotoLab stopping its own test brain; it is no longer a warning.

Test checklist (3 minutes, one of the Intel Macs is enough):
[ ] 1  Browse a few SMB folders, including a share's top folder. Status line should say "bulk".
[ ] 2  Help -> Run Self-Test (shares mounted): listing-network-shares and listing-smb-records OK.
[ ] 3  Help -> Short Report: type those lines back to me.

## 0.1.1 — bulk listing on shares

- A broken bulk-listing record no longer switches fast listing off for the whole session. An odd
  field in one record now only means that one item is looked up on its own; a broken record
  structure re-reads that folder the slow way; only 3 broken folders on the SAME volume switch
  bulk off for that volume (this session). Local disks are never affected by a share.
- The first odd record per volume is logged in full (W-LIST-2: reason, file system, raw bytes).
- Self-test forces bulk for real, and now also compares both methods on the top folder of each
  mounted network share (differences there are WARN, not FAIL).
- The status line says how a folder was listed: "bulk", "bulk+2" (2 items looked up on their own),
  or "readdir (bulk record broken)".
- Logs and self-test show the real macOS version instead of "10.16".

Test checklist (3 minutes, the same two Intel Macs):
[ ] 1  Browse the same SMB folders as last time. Status line: does it say "bulk", "bulk+N" or
       "readdir (bulk record broken)"?
[ ] 2  Browse a local folder afterwards: it must still say "bulk".
[ ] 3  With your shares mounted: Help -> Run Self-Test. Send me the listing-network-shares line.
[ ] 4  Help -> Save Report..., attach it (the W-LIST-2 lines tell me exactly what the server sends).

## 0.1.0 — Phase 1a: read-only browser

A Finder-like browser that only reads: it cannot change, move or delete anything yet.

Test checklist (5 minutes; the 10.13 Mac plus one newer Mac, at least one test on a busy share):
[ ] 1  Open PhotoLab. A browser window opens at the folder you used last (first time: your home).
[ ] 2  Sidebar: click a share under VOLUMES. The list fills; the status line shows the item count
       and how long the listing took (e.g. "bulk 35 ms").
[ ] 3  Double-click folders to go in; Cmd-Up, Cmd-[ and Cmd-] (or the Back/Forward/Up buttons and the
       path bar) to move around. Going up selects the folder you came from.
[ ] 4  On a share, have someone (or Finder) add, rename and delete a file in the folder you are
       looking at. The list updates by itself within ~5 seconds.
[ ] 5  Go back to a folder you just visited: it appears instantly (status says "from memory").
[ ] 6  Cmd-Shift-. shows/hides hidden files. Click column headers to sort. Type a name to jump to it.
[ ] 7  Double-click a file: it opens in its usual app.
[ ] 8  Unplug the network or eject a share while browsing: no beachball; the window says what happened.
[ ] 9  Help -> Run Self-Test: all OK. If anything is slow or wrong: Help -> Save Report..., attach it.
       (Lines starting with FREEZE in the log name any moment the window hung.)

## 0.0.1 — Phase 0 skeleton (toolchain proof)

What it is: an empty window that starts the Python brain and shows whether it answered.
Nothing in it touches your files.

Test checklist (5 minutes, on each of: the 10.13 Mac, an Intel Mac on 11+, an Apple Silicon Mac):
[ ] 1  Open PhotoLab2.dmg, drag PhotoLab to Applications, open it (first time: right-click → Open,
       or System Settings → Privacy & Security → Open Anyway).
[ ] 2  The window says "Brain: connected (Python 3.x)" within a few seconds.
[ ] 3  Help → Run Self-Test: every line says OK.
[ ] 4  Apple Silicon only: Activity Monitor → PhotoLab → Kind column says "Apple", not "Intel".
[ ] 5  If anything fails: Help → Save Report…, attach the zip in the chat.
