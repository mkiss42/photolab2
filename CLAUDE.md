# PhotoLab 2 — instructions for Claude

Read `docs/PLAN.md` before doing anything. Since 2026-11-27 the code base is **Find 0.18.16**
(a coworker's app, adopted as the one codebase) renamed PhotoLab; PhotoLab 2 0.9.2 is kept on the
branch `archive/pl2-0.9.2` (also tag `pl2-0.9.2` locally) - port from it, don't merge it. It holds the architecture, the PhotoLab 1 feature
verdicts, the phases and the Decision Log. `docs/PROTOCOL.md` is the app↔brain contract.

## Ground rules

0. **Two people push to this repo** (the user and a coworker). `git pull --rebase` before every
   push; never force-push `main`.


1. **Targets:** macOS 10.13+ (x86_64) and 11.0+ (arm64), one universal app. AppKit only.
   Not allowed in Swift: SwiftUI, Combine, async/await, actors, `some`/opaque result types
   in public API, Network.framework, any API newer than 10.13 unless behind
   `if #available(macOS X, *)` with a 10.13 fallback. Concurrency = GCD + OperationQueue.
2. **Swift vs Python:** Swift for everything the user waits on. Python ("brain") only for:
   shared cache + sync, metadata DB/search, ingest, stationery/templates, AI. The app must
   work when the brain is down; every brain call has a timeout and a fallback.
3. **File safety:** only `Sources/Core/FileOperations.swift`, `Sources/Core/AppFiles.swift`
   and `Sources/Darwin/DarwinPlatform.swift` may change files (Find's rule, kept). `tools/check_mutations.sh`
   enforces it; never weaken the script to make a build pass. Trash, never delete (exception: shares without a Trash, after
   explicit confirmation - PLAN.md section 5, S1/S2). Never overwrite. Verify, then swap. Journal multi-step operations. Metadata writes as PLAN.md section 5 (S3-S6) describes.
4. **Main thread:** never touches a network volume. Long work → background queue, with
   cancellation.
5. **Done means CI is green.** Push, read the workflow result (`gh run list`, `gh run view
   --log-failed`), fix, repeat. Never tell the user something works if CI did not build and
   self-test it. Swift cannot be compiled in Claude's Linux workspace; Python can — run
   `python3 -m pytest brain/tests` locally before pushing.
6. **Small releases.** Each release: bump `VERSION`, add a section to `docs/CHANGES.md` with
   a ≤5-minute test checklist for the user, covering the three test Macs when relevant.
7. **Logs:** ASCII, one fact per line, stable codes `E-AREA-n` / `W-AREA-n`. User-visible
   errors say what happened and that nothing was lost (when true).
8. **Self-tests** live in the app and run in CI: `--selfcheck` (safety), `--searchtest`,
   `--indextest`, `--phototest` (Find's). New core logic comes with a check in one of them; a
   check marked `safety: true` fails the build.
9. **Decisions:** any new architectural choice → entry in the Decision Log in PLAN.md.
10. **The repo is public.** Never put real paths, share/server/host names, user names, IP
    addresses, file names from the lab or anything retyped from the lab Macs into code, docs,
    test vectors or commit messages. Use invented examples (`/Volumes/Share/Job`).
11. **PhotoLab 1 source** is in the Claude project docs (Python). Port logic from it where
    PLAN.md says "Python"; read it for behaviour where it says "Swift". Do not port its
    workarounds for Qt/GIL.
12. **Two people share this repo.** Find's author and the PhotoLab owner both push to `main`,
    each with their own Claude. Before starting any change, pull (`git fetch origin main` then
    `git pull --ff-only`, or rebase local work onto `origin/main`) and read the new commits and
    `docs/CHANGES.md` so you build on the other side's latest work. Pull again right before
    pushing; if `main` moved, rebase and re-check CI. Never force-push `main`, never revert or
    rewrite the other side's work without asking, and push every fix so both sides stay in sync.

## Build

- `./build-legacy.sh` — Xcode 26, universal, x86_64 ≥ 10.13 / arm64 ≥ 11.0. The default today.
- `./build-modern.sh` — Xcode 27+, universal, ≥ 12.0. For when old Macs are retired.
- Both call `tools/build.sh <profile>`; profiles live in `profiles/*.env`.
- Output: `build/PhotoLab.app`, `build/PhotoLab2.dmg`, `build/build-log.txt`.

## Layout

```
Sources/App       AppKit UI (windows, panes, menus) - Find's
Sources/Core      platform-independent logic (much of it tested on Linux by Find's author)
Sources/Darwin    macOS-only code: BulkLister, DarwinPlatform (the only primitives that change
                  files), ExifToolServer, ImageMeta, PhotoSelfTest
Resources         exiftool (bundled, run by /usr/bin/perl), PhotoLab.iconset
brain/            Python helper (package photolab_brain, tests/) - not wired into the Find base yet
shared/           data shared by both sides (field definitions, test vectors)
profiles/         build profiles
tools/            build + guard scripts
docs/             PLAN, PROTOCOL, CHANGES
```
