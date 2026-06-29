# Changelog

All notable changes to foreman-tools are documented here.

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
