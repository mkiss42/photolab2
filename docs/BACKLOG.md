# Backlog

Every idea goes here first, tagged with where it belongs. Order of work:
1. **Parity**: every PhotoLab 1 feature, transposed (Swift or brain) — tracked in `docs/PARITY.md`.
2. **Best of both**: what Find does better, folded in.
3. **New**: the user's further expansions.

An idea that changes architecture (data model, cache keys, protocol, window model) is scheduled
early even if its feature comes late, so nothing has to be rebuilt.

## Open

| # | Idea | From | Kind | Phase |
|---|---|---|---|---|
| 1 | Spinner while a folder loads: big one in the list (enter), small one in status (re-read), "Loading..." row under an expanding folder | user 2026-11-25 | parity+ | 0.1.3 done / 0.1.4 |
| 2 | Expandable list (disclosure triangles, PhotoLab 1 tree behaviour) | user 2026-11-25 | parity | 0.1.4 |
| 3 | One SMB folder lists empty (Finder and PhotoLab 1 see files); 0.1.3 adds readdir re-check + diagnostics | user 2026-11-25 | bug | 0.1.3 check |
| 4 | Full parity checklist from PhotoLab 1 source (`docs/PARITY.md`) | user 2026-11-25 | process | with 0.1.4 |
| 5 | Metadata written into RAWs as well as sidecars and JPEGs; every field kept identical across raw+jpg+xmp. Setting: "sidecar only" for RAWs. Default: write everything | user 2026-11-25 | new (changes safety rule) | 2 (design), 4 |
| 6 | Tools / plugins in the brain (Python): e.g. "Goodbye Drill" marks bad facial expressions with a colour label (colour from settings). Port the user's existing Python tools later | user 2026-11-25 | new (affects protocol) | 3 groundwork, 5 tools |
