# Changes

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
