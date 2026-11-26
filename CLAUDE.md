# PhotoLab 2 — instructions for Claude

Read `docs/PLAN.md` before doing anything. It holds the architecture, the PhotoLab 1 feature
verdicts, the phases and the Decision Log. `docs/PROTOCOL.md` is the app↔brain contract.

## Ground rules

1. **Targets:** macOS 10.13+ (x86_64) and 11.0+ (arm64), one universal app. AppKit only.
   Not allowed in Swift: SwiftUI, Combine, async/await, actors, `some`/opaque result types
   in public API, Network.framework, any API newer than 10.13 unless behind
   `if #available(macOS X, *)` with a 10.13 fallback. Concurrency = GCD + OperationQueue.
2. **Swift vs Python:** Swift for everything the user waits on. Python ("brain") only for:
   shared cache + sync, metadata DB/search, ingest, stationery/templates, AI. The app must
   work when the brain is down; every brain call has a timeout and a fallback.
3. **File safety:** only `Sources/Core/FileOperations.swift`, `Sources/Core/AppFiles.swift`
   and `Sources/Platform/Platform.swift` may change files. `tools/check_mutations.sh`
   enforces it; never weaken the script to make a build pass. Trash, never delete (exception: shares without a Trash, after
   explicit confirmation - PLAN.md section 7). Never overwrite. Verify, then swap. Journal multi-step operations. RAW metadata writes only as PLAN.md section 7 describes.
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
8. **Self-tests** live in the app (`--self-test`) and run in CI. New core logic comes with a
   self-test case.
9. **Decisions:** any new architectural choice → entry in the Decision Log in PLAN.md.
10. **PhotoLab 1 source** is in the Claude project docs (Python). Port logic from it where
    PLAN.md says "Python"; read it for behaviour where it says "Swift". Do not port its
    workarounds for Qt/GIL.

## Build

- `./build-legacy.sh` — Xcode 26, universal, x86_64 ≥ 10.13 / arm64 ≥ 11.0. The default today.
- `./build-modern.sh` — Xcode 27+, universal, ≥ 12.0. For when old Macs are retired.
- Both call `tools/build.sh <profile>`; profiles live in `profiles/*.env`.
- Output: `build/PhotoLab.app`, `build/PhotoLab2.dmg`, `build/build-log.txt`.

## Layout

```
Sources/App       AppKit UI (windows, views, menus)
Sources/Core      platform-independent logic (models, listing, protocol, self-tests)
Sources/Platform  the only Darwin-specific primitives that change files
brain/            Python helper (package photolab_brain, tests/)
shared/           data shared by both sides (field definitions, test vectors)
profiles/         build profiles
tools/            build + guard scripts
docs/             PLAN, PROTOCOL, CHANGES
```
