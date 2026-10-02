# Game-making benchmarks

These live-model tasks exercise planning, file edits, shell commands, deterministic simulation tests, and context management through the freshly built harness. They do not add a JavaScript build step to the main binary.

Run one task with `OPENROUTER_API_KEY` available:

```bash
zig build
python3 benchmarks/game_tasks.py --task orbit-dodger
```

Use `--task all` for all three games. The default route is OpenRouter's `stealth/space-bunny-alpha` with low reasoning effort. Use `--effort` and `--reasoning-format` only for capabilities supported by the selected route. The runner uses an isolated configured provider, so the harness cannot silently switch the benchmark to a paid fallback. To explicitly evaluate the requested OpenPaths free route without assuming reasoning support, use `--base-url https://openpaths.io/v1 --key-env OPENPATHS_API_KEY --model free --effort auto --reasoning-format omit` after confirming that route is available.

Each timestamped directory under `games/runs/` contains a generated workspace, private session files, request output, stderr, a harness trace, verification output, and metrics. Generated games and traces are ignored by Git. Traces and session files may contain task data; inspect and redact them before sharing.

Metrics include elapsed time, session file count and bytes, and sampled Linux root-process I/O counters. `io_observation` reports successful and missed samples. Process hardening normally blocks observation after startup; use `--observe-io` to set `FX_ALLOW_DEBUG=1` for this benchmark process. This opt-in permits local debugging and may permit core dumps containing credentials or task data. It does not change profile settings. Sampling still misses activity after the last observation and excludes subprocess I/O, so counters are lower bounds, not total disk-write measurements.

Model-generated tests are one signal, not an independent correctness oracle. A successful verifier does not prove that the game renders or plays correctly: serve its workspace, exercise the controls in a browser, and inspect rendering and console errors separately.

Metrics record the starting binary's SHA-256 and size, and flag a changed binary path during the run. Build before benchmarking and avoid rebuilding concurrently when comparing runs.
