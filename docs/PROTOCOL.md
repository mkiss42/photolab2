# App ↔ Brain protocol (v1)

Transport: Unix domain socket. Default path
`~/Library/Application Support/PhotoLab2/brain.sock` (the app passes `--socket <path>`).
Framing: one JSON object per line, UTF-8, `\n`-terminated. Max line 16 MiB.

## Messages

Request (app → brain):
```json
{"id": 7, "method": "ping", "params": {}}
```
Response:
```json
{"id": 7, "result": {"pong": true, "brain_version": "0.0.1", "protocol": 1, "python": "3.11.9"}}
{"id": 7, "error": {"code": "E-BRAIN-1", "message": "unknown method: foo"}}
```
Event (brain → app, no id):
```json
{"event": "cache.updated", "params": {"folder": "/Volumes/Share/Job"}}
```

Rules:
- `id` is a positive integer chosen by the app, unique per connection.
- The app applies its own timeout to every request (default 2 s; see each method) and
  carries on without the answer when it expires.
- Unknown methods → `E-BRAIN-1`. Bad params → `E-BRAIN-2`. Internal failure → `E-BRAIN-3`.
- Adding a method or a field is backwards compatible. Removing or changing one bumps
  `protocol`.

## Methods

| Method | Params | Result | Timeout | Phase |
|---|---|---|---|---|
| `ping` | — | `pong`, `brain_version`, `protocol`, `python` | 2 s | 0 |
| `shutdown` | — | `ok` (brain exits after replying) | 2 s | 0 |

More are added per phase (exif cache, thumbnails sharing, search, ingest, AI).
