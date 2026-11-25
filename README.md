# PhotoLab 2

Native macOS photo-lab browser (Swift/AppKit) with a Python helper for lab tools and AI.
Runs on macOS 10.13 and later, Intel and Apple Silicon.

- Plan and decisions: [docs/PLAN.md](docs/PLAN.md)
- What changed and how to test each release: [docs/CHANGES.md](docs/CHANGES.md)
- App ↔ brain protocol: [docs/PROTOCOL.md](docs/PROTOCOL.md)

## Build

On a Mac with Xcode 26: `./build-legacy.sh` → `build/PhotoLab2.dmg` (macOS 10.13+).
When every Mac runs macOS 12+: `./build-modern.sh` instead (works with Xcode 26 and 27+).
If a build fails, send `build/build-log.txt`.

Every push is built and self-tested on GitHub's Mac machines (Actions tab); the disk image is
attached to each run.
