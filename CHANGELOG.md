# Changelog

All notable changes to foreman-tools are documented here.

## [0.60.0] — 2026-07-01

### New
- `export <project-path> [--format fmz|brew|mac|linux|windows|backup] [--out <dir>]` — package a project for distribution or archival; fmz format is a tar.gz containing `foreman.manifest.json` + git-archive of project source + `knowledge/`; brew/mac/linux/windows formats emit installer scripts; backup format snapshots the entire foreman workspace (all project .fmz files + ledger + framework files)
- `import <source-path> [<foreman-root>]` — absorb a `.fmz` or raw project directory into the foreman workspace; detects workspace backup vs single project from manifest `kind` field; carries over `knowledge/` directory; aborts if destination already exists

## [0.59.0] — 2026-07-01

### New
- `knowledge-audit <project-path> [<foreman-root>]` — pre-export/archive gate; scans a project across 7 checks: spec.md present, CLAUDE.md decision log entries, knowledge/ files exist, _knowledgebase/ mirror entry, git repo clean, HEAD pushed to remote, ledger references; returns `{ ready, captured[], unextracted[], warnings[] }`; `ready: true` only when both `unextracted` and `warnings` are empty

## [0.58.0] — 2026-07-01

### New
- `tui [<foreman-root>]` — interactive split-panel project dashboard; left panel lists all Foreman projects (j/k/arrow navigate), right panel shows project detail with release state and MVP readiness checklist; q to quit, r to reload; powered by embedded Python curses renderer (`@embedFile("tui.py")`); SIGWINCH resize support

## [0.57.0] — 2026-07-01

### New
- `ledger [show|record <winner> <question> <reasoning>|check-stale|validate <id>|score <question> <sources-json>]` — decision ledger implementing the Rigged Rock-Paper-Scissors protocol; stores Claude-vs-Zig contested decisions at `~/.foreman/ledger.json`; score computes composite from ≥10 cited live sources (10pt each, -10 if contradicted); Zig stored entry beats Claude reasoning at tiebreak; 365-day staleness tracking; append-only

## [0.56.0] — 2026-07-01

### New
- `context-slice <abs-path> <focus-query>` — Module 20 M1 Multi-Agent Coordinator; top 8 files ranked by relevance (via `context-rank`) + up to 3 evidence excerpts per file (via `context-evidence`); binary files detected via Mach-O/ELF magic bytes and silently excluded from evidence extraction; output: `{ focus, path, fileCount, files: [{path, score, excerpts: [{startLine, endLine, content}]}] }`; enables Claude to hand each subagent a focused project slice instead of the full context dump
- `state-merge <file1> <file2>` — merge two JSON objects from disk; array fields are concatenated (both orders preserved), non-array fields default to `file2` value on conflict; output is the merged JSON object; enables multi-agent partial results to be combined into one coherent state file; both files must be valid JSON objects at root level

### Fixed
- `allocJsonEscape` now escapes all control characters (bytes 0x00–0x1f, excluding \t, \n, \r) as `\u00XX` — previously raw control bytes from binary file content could produce structurally invalid JSON in `context-evidence`, `context-slice`, and any future subcommand that reads arbitrary file content
- `zig-cache/` directory (without leading dot) now excluded from all scan-based subcommands (`scan`, `context-scan`, `context-rank`, `context-slice`) — previously build artifacts in `zig-cache/z/` were scored as highly relevant source files, crowding out actual source

## [0.55.0] — 2026-07-01

### New
- `plugin-run <name> [args...]` — execute a plugin from `~/.foreman/plugins/<name>/`; loads `plugin.json` manifest, dispatches the entry script via the `worker-run` runtime for `lang`, passes args through, returns the script's JSON stdout verbatim; exits 1 with a descriptive message on missing plugin, malformed manifest, unknown lang, or interpreter not found
- `plugin-list` — walk `~/.foreman/plugins/`, read each `plugin.json`, return `{ plugins: [{name, lang, description, args, entry}], count, skipped }`; manifests with missing/malformed fields are skipped gracefully and listed in `skipped`; `capability-check` and `route` now include installed plugins alongside native subcommands

## [0.54.1] — 2026-07-01

### Fixed
- Rebuilt universal binary from v0.54.0 source — prior release shipped a stale v0.53.0 binary; `worker-run` and `worker-list` were unreachable via Homebrew

## [0.54.0] — 2026-07-01

### New
- `worker-run <lang> <script> [args...]` — Module 10 Language Worker Manager (M1); executes a script file in a named language runtime; 11 runtimes with aliases: python (py), node (js), deno, bun, go (golang), ruby (rb), bash (sh), swift, zig, lua, php; interpreter discovery is PATH-based with ordered candidates (e.g. python3 before python, lua5.4 before lua5.3); deno gets `--allow-all`; zig and go get `run` prefix automatically; output: `{ lang, interpreter, script, exit_code, stdout, stderr, duration_ms, timed_out, truncated }`; stdout/stderr capped at 64KB; timeout is retrospective (30s default, reported in `timed_out` field); non-zero script exit codes are surfaced in `exit_code` — foreman-tools itself exits 0 as long as the interpreter was found and ran
- `worker-list` — returns all 11 supported language workers as `{ workers: [{lang, binary, ext}], count }` — Claude can call this to know what's available before choosing a runtime

### Fixed
- Applied `zig fmt` to all source files (`main.zig`, `root.zig`, `stress.zig`)

## [0.53.1] — 2026-06-30

### Dev tooling
- `src/stress.zig` + `zig build stress` — three-tier stress tester (56 tests) that runs against the freshly built binary; Tier 1: smoke (exit 0 + valid JSON for every major subcommand); Tier 2: real-data field assertions (framework contains "Zig", git-cache branch="main", sha256 len=64, registry ≥55 subcommands, etc.); Tier 3: adversarial (bad inputs exit 1, edge inputs exit 0 gracefully); exits 1 on any failure so `zig build stress` fails the build gate

## [0.53.0] — 2026-06-30

### New
- `ant <path> [--since <ms>]` — filesystem change detection (Ant colony: "what changed?"); walks `<path>` and returns files whose mtime exceeds `since_ms`; default is 24h ago when `--since` is omitted; uses `file.stat(io).mtime.nanoseconds` (Zig 0.16 Io API — no `std.c.stat` required); capped at 500 entries with `truncated` flag; skips same dirs/files as `scan` (`.git`, `node_modules`, binary extensions); output: `{ root, sinceMs, scannedAtMs, total, truncated, changed: [{path, mtimeMs}] }`; complements `context-changed` (git-based) for untracked files and non-git directories; foundation for Ant colony ("what changed since last session?") thin Hive runtime

## [0.52.0] — 2026-06-30

### New
- `capability-promote <command...>` — score a repeated shell command for promotion eligibility as a foreman-tools subcommand; returns `{ command, score, already_covered, similar_subcommand, recommendation, reasons }`; scoring signals: git operation (+20), parses structured output (+20), read-only / no side effects (+15), deterministic (+15), compact command (<80 chars, +10), takes path/repo argument (+10); baseline score 10; recommendation: "promote" (≥60), "consider" (≥40), "skip" (<40); if the command already matches an existing subcommand at exact/high confidence, returns `already_covered: true`, `score: 0`, `recommendation: "skip"`; foundation for Module 21 (Capability Promotion)

## [0.51.0] — 2026-06-30

### New
- `rollback <repo-path> [--list | --revert <id>]` — three-mode git-state snapshot system; default: capture current branch + HEAD SHA + dirty flag from git-cache, write to `~/.foreman/snapshots/<sanitized-path>.json` (capped at 20 entries, atomic write), return `{ id, branch, head, dirty, created_at_ms, snapshot_count, snapshot_file }`; `--list`: return all snapshots for that repo as `{ repo, snapshots: [...], count }`; `--revert <id>`: find snapshot by ID and return `{ snapshot_id, branch, head, commands: [git checkout, git reset --hard], warning }`; timestamps via `std.c.clock_gettime(CLOCK.REALTIME)`; foundation for Module 29 (Rollback / Recovery)

## [0.50.0] — 2026-06-30

### New
- `sandbox-check <command...>` — classifies a shell operation by severity (`safe` / `caution` / `destructive` / `blocked`) and returns whether it is allowed; returns `{ operation, allowed, severity, reason }`; pattern table of 30 entries covers: blocked (sudo rm, mkfs, fdisk, dd if=, fork bomb), destructive (rm -rf, git reset --hard, git push --force, git clean -f, DROP TABLE, --no-verify, git branch -D), caution (git push, git commit, git tag, npm/yarn/cargo publish, brew install/upgrade, gh release create, gh pr create); case-insensitive matching against lowercased operation string; foundation for Module 27 (Permissions / Sandbox)

## [0.49.0] — 2026-06-30

### New
- `session-snapshot <foreman-root>` — writes ground-truth session state to `~/.foreman/session-snapshot.json` before compaction; extracts `version` (binary constant), `wave` and `current` from ROADMAP.md Active Work section, `pending_errors: null`; atomic write (tmp + rename); also added `route`, `report`, `metrics`, and `session-snapshot` entries to `registry` output (were missing since v0.44.0)

### Improved
- `registry` — now includes all 56 subcommands including `route`, `report`, `metrics`, and `session-snapshot` added in v0.46–v0.49

## [0.48.0] — 2026-06-30

### New
- `metrics` — telemetry snapshot of foreman-tools runtime state; returns `{ cacheEntries, projectStates, totalDecisions, totalPatterns, deviceProfiled, compatBaselineSet, estimatedTokenSavings, note }`; walks `~/.cache/foreman-tools/` for cache entry count and `~/.foreman/state/` for project-state JSON files, counting decisions and known_patterns per file; checks `~/.foreman/profile.json` and `~/.foreman/compat-baseline.json` for device/compat status; estimates token savings at 80% hit rate × 200 tokens/hit; all sub-walks fault-tolerant (missing dirs → zeros); foundation for Module 26 (Telemetry / Metrics)

## [0.47.0] — 2026-06-30

### New
- `report <path>` — composite project status report; runs git-cache + quality-gate + secret-scan in sequence; returns `{ path, status, confidence, gitBranch, gitDirty, buildOk, testsOk, secretsFound, issues: [{source, severity, message}], nextAction }`; status: "clean" / "issues" / "blocked"; confidence: "high" (quality-gate ran) / "medium" (git-cache only) / "low" (nothing ran); nextAction: prescribed string based on issue severity; issues capped at 20; each sub-call fault-tolerant; foundation for Module 23 (Reporting Layer)

## [0.46.0] — 2026-06-30

### New
- `route <task...>` — given a task description, returns an ordered execution plan: `{ task, routed, steps: [{step, layer, subcommand, argHint, confidence, reason}], fallback }`; reuses capability-check matching logic + enrichment table of 25 subcommands with context-aware arg hints and reasons; scoring: exact name=100, substring=80, all-words-in-name=70, all-in-desc=60, name-words≥2=50, desc-words≥2=45, any-in-name=35, any-in-desc=30; tie-breaking by total name+desc match count; `routed: false` → `fallback: "claude"` with reason; foundation for Module 3 (Tool Router)

### Improved
- `capability-check` — scoring now distinguishes multi-word name matches (≥2 words → 50) from multi-word description matches (≥2 words → 45), giving higher weight to semantically dense description matches than single-word name hits; tie-breaking by total match count prevents registry-order bias

## [0.45.0] — 2026-06-30

### New
- `capability-check <query...>` — checks whether a capability is natively available in foreman-tools or needs a Claude fallback; returns `{ query, available, source, subcommand, description, args, confidence }`; matching: exact name → "exact" (100), name substring → "high" (80), all query words in name → "high" (70), all in description → "medium" (50), any in name → "low" (40), any in description → "low" (30); words under 3 chars filtered to skip stop words; `available: false` → `source: "claude"`, `confidence: "none"`; foundation for Module 2 (Capability Registry) and Module 3 (Tool Router)

## [0.44.0] — 2026-06-30

### New
- `registry` — machine-readable catalog of all foreman-tools subcommands; returns `{ version, subcommands: [{name, description, args}] }`; 50 subcommands listed; zero allocations — pure comptime static data; foundation for Module 1 (Foreman Core) capability registry

## [0.43.0] — 2026-06-30

### New
- `prod-ready <path>` — composite production readiness gate; runs quality-gate (build + tests), secret-scan, and env-inspect in sequence; returns `{ ready: bool, blockers: [{source, message}], warnings: [{source, message}] }`; blockers: quality-gate critical/high findings, any secret-scan findings; warnings: build warnings, no-build-system, no-test-framework, missing deps from env-inspect, secret-scan truncated; `ready: true` only when blockers array is empty; each check is fault-tolerant — if one fails to run, a warning is added and the others continue

## [0.42.0] — 2026-06-30

### New
- `validate-schema <file> <schema>` — validates a JSON file against a JSON Schema (subset); returns `{ valid, violations: [{path, expected, got}], file, schema }`; supported constraints: `type` (null/boolean/integer/number/string/array/object), `required`, `properties` (recursive up to depth 6), `enum`, `minLength`/`maxLength`, `minimum`/`maximum`, `minItems`/`maxItems`, `items`, `additionalProperties: false`; violations capped at 50; uses `$` as root path with dot-notation for properties and bracket-notation for array indices

## [0.41.0] — 2026-06-30

### New
- `quality-gate <path>` — runs build + tests for a project and returns a severity-bucketed verdict; auto-detects build system and test framework (same as `build` and `run-tests`); skips gracefully if neither is present; categorizes: build errors → `high`, build crash (non-zero exit, no parsed errors) → `critical`, test failures → `high`, test runner crash (non-zero exit, no parsed failures) → `critical`, build warnings → `medium`; verdict is `fail` on any critical or high finding, `pass` otherwise; returns `{ verdict, critical, high, medium, low, buildRan, buildTool, testsRan, testFramework, testsPassed, testsFailed }` with each finding as `{ source, file, line, message }`; findings capped at 50 per level

## [0.40.0] — 2026-06-30

### New
- `shell-run [--timeout <ms>] <shell-command>` — runs a shell command via `/bin/sh -c` and returns structured JSON; blocks destructive patterns before execution (`rm -rf` on root/home, `mkfs`, `dd of=/dev/`, SQL `drop/truncate`); captures stdout + stderr (capped at 128KB each for display); tracks wall-clock duration; sets `timedOut: true` when `durationMs >= timeout` (retrospective — enforced softly since execution is synchronous); returns `{ command, exitCode, stdout, stderr, durationMs, timedOut, blocked, blockReason, stdoutTruncated, stderrTruncated }`

## [0.39.0] — 2026-06-30

### New
- `project-state <path>` — reads persisted project state from `~/.foreman/state/ps-{sha256(path)}.json`; returns `{ path, decisions: [{date, what, why}], knownPatterns: [...], lastBuildResult: null, lastTestResult: null }`; survives restarts and power loss (atomic writes)
- `project-state <path> record-decision <what> [<why>]` — appends a decision with today's date, saves atomically, returns updated state; capped at 100 decisions
- `project-state <path> record-pattern <pattern>` — appends a known pattern, saves atomically, returns updated state; capped at 50 patterns

## [0.38.0] — 2026-06-30

### New
- `git-cache <repo-path>` — reads branch, HEAD SHA, dirty state, ahead/behind counts, and last 10 commits in one call; caches result to `~/.cache/foreman-tools/gc-{sha256(repo)}.json` invalidated by HEAD SHA; returns `{ hit, branch, head, dirty, ahead, behind, commits: [{hash, subject, author, date}] }`; second call within the same HEAD returns `hit: true` with zero git subprocesses; replaces repeated `status`/`commits`/`changes-preview` calls within a session

## [0.37.0] — 2026-06-30

### New
- `delta-context <repo-path> [ref]` — finds which symbols changed between ref and HEAD, then resolves callers for each; returns `{ ref, symbols: [{name, kind, file, line, callers: [{file, line}]}] }`; walks changed files via `git diff --name-only`, extracts changed line ranges from `@@ -old +new @@` hunk headers, maps lines to owning symbols via outline detection, then runs `symbol-find` per symbol for caller resolution; capped at 8 files, 10 symbols, 10 callers; replaces reading raw git diffs + grepping for usages

## [0.36.0] — 2026-06-30

### New
- `device-scan` — snapshots hardware + installed tools + optimal build settings to `~/.foreman/profile.json`; pre-warms `cache-fetch ~/.foreman/profile.json device` so the next session-start reads `hit: true` without any tool-detection shell calls; returns `{ profile_id, hardware: {cpu, cores, ram_gb, os, arch}, tools: {name, version, present}, optimal: {zig_build_flags}, shell, scanned_at, path }`; detects M1–M5 Apple Silicon and maps to Zig `-Dcpu=apple_mN` flag; covers foreman_tools, zig, git, gh, node, python3, brew

## [0.35.0] — 2026-06-30

### New
- `secret-scan <path>` — walks the project tree and flags likely hardcoded secrets; returns `{ findings: [{file, line, pattern, severity}], truncated }`; two detection modes: (1) prefix-match for specific token formats (Stripe sk_live_/sk_test_, AWS AKIA, GitHub ghp_/gho_/ghs_/github_pat_, GitLab glpat-, Slack xoxb-/xoxp-, PEM private keys, Google AIza/ya29); (2) assignment-key match for generic patterns (password, api_key, api_secret, secret, access_token, auth_token, private_key) with placeholder filtering; skips comment lines, binary files, and .example/.sample/.template files; findings capped at 200

## [0.34.0] — 2026-06-30

### New
- `symbol-find <path> <symbol>` — single-pass directory walk that locates a symbol's definition and all references; returns `{ symbol, kind, definition: {file, line} | null, references: [{file, line}], capped }`; keyword-based declaration detection (fn/def/function/func/class/struct/trait/const/var/let/etc) with whole-word boundary matching; skips binary files via magic-byte check (Mach-O + ELF); references capped at 100; replaces `grep + read N files` pattern for symbol lookup

## [0.33.0] — 2026-06-30

### New
- `env-inspect <path>` — detects languages present in the project (go/python/node/rust/zig/ruby/java via manifests), checks runtime presence + version, reports all package managers (npm/pip/cargo/brew/yarn/pnpm), lists missing deps (node_modules, .venv, vendor/bundle), and returns env var keys from `.env*` files; one call replaces `which` + `--version` loops

## [0.32.0] — 2026-06-30

### New
- `build <path>` — auto-detects build system (Cargo.toml→cargo, build.zig→zig, go.mod→go, package.json with "build" script→npm, Makefile→make), runs the build, returns `{ tool, command, success, errors: [{file, line, col, message, severity}], warnings: [{file, line, col, message}], duration_ms, truncated }`; errors capped at 50, warnings at 20; uses `env -C <path>` as working-directory mechanism; per-toolchain parsers (cargo state-machine via " --> ", zig/gcc/clang colon-separated, go dotted-path, TypeScript paren-coords)

## [0.31.0] — 2026-06-30

### New
- `run-tests <path>` — auto-detects test framework (jest/vitest/pytest/go/cargo/zig), runs tests, returns `{ framework, command, success, passed, failed, skipped, duration_ms, failures: [{file, line, test, message}], truncated }`; failures capped at 50; uses `env -C <path>` as working-directory mechanism; Claude reads verdict + structured failures without seeing raw test runner output

## [0.30.0] — 2026-06-30

### New
- `compat-check` — zero-token dependency guard; compares current tool versions (foreman_tools, zig, git, gh, brew, node, python3) against a stored baseline; returns `{ ok, baselineAge, drifted, advice }` with risk-rated drift entries and exact rollback commands; high-risk drift (zig, foreman_tools) surfaces a STOP advisory before the user starts typing
- `compat-check --baseline` — snapshot current tool versions to `~/.foreman/compat-baseline.json` (atomic write); returns `{ recorded, path, tools }`
- `compat-check --update-baseline` — alias for `--baseline`; after confirming drift is safe, promotes current versions to the new baseline

## [0.29.1] — 2026-06-30

### Fixed
- Cache writes are now atomic — `cache-store` and `cache-check` write to a `.tmp` file then rename, eliminating corrupted cache entries on power loss

## [0.29.0] — 2026-06-29

### New
- `deps <root-path>` — declared dependencies from any package manifest without reading the full file; auto-detects package.json (npm), Cargo.toml (cargo), go.mod (go), requirements.txt (pip); returns name + version + dev flag; capped at 100 deps

## [0.28.0] — 2026-06-29

### New
- `outline <file-path>` — source file structure in one call (function/class/struct/enum/trait names + line numbers); covers Go, Python, JS, TS, Rust, Zig, Ruby, Java, Kotlin, C#, Swift, PHP; capped at 200 symbols

## [0.27.0] — 2026-06-29

### New
- `yaml-query <file-path> <dot-path>` — read a value from any YAML file; handles nested mappings + sequence indexing; covers GitHub Actions, docker-compose, k8s, Rails config

## [0.26.0] — 2026-06-29

### New
- `context-rank <root-path> <query>` — relevance ranking; scores and ranks files by query relevance so the most important files are read first; top 15 results; content + name match scoring

## [0.25.0] — 2026-06-29

### New
- `context-changed <repo-path> [ref]` — diff with content in one call; first 8 changed files with unified diffs capped at 100 lines each; default ref is HEAD (uncommitted changes)

## [0.24.0] — 2026-06-29

### New
- `context-evidence <file-path> <pattern>` — relevant excerpts from a file without reading the whole thing; case-insensitive literal search; ±10 lines context; overlapping windows merged; capped at 8 chunks

## [0.23.0] — 2026-06-29

### New
- `context-scan <path>` — compact project summary; replaces full `scan` for context-loading; returns framework, entry point, file counts by kind, top 10 files by size, key files, directory map

## [0.22.0] — 2026-06-29

### New
- `cache-store <file-path> <sub-key>` — store arbitrary JSON value keyed to file content; value via stdin; auto-invalidates when file changes
- `cache-fetch <file-path> <sub-key>` — retrieve cached value; returns `{hit, value}`; hit: true means file unchanged and value is available — skip the read entirely

## [0.21.0] — 2026-06-29

### New
- `cache-check <file-path>` — persistent change detection; returns `{changed, cached, sha256}`; changed: false means file is identical to last check

## [0.20.0] — 2026-06-29

### New
- `file-hash <file-path>` — SHA256 of any local file in one call; foundation for cache-engine change detection
