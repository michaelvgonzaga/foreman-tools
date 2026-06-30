# Changelog

All notable changes to foreman-tools are documented here.

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
