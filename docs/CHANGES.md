# Changes

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
