# foreman-tools Spec

See `api-schema.md` for the locked JSON output contract for all subcommands.

---

**The real goal:** Replace Claude's inline token-expensive shell reasoning with a native binary that hands back a JSON blob — Claude reads, not reasons.

**Who it's for:** Foreman's command files running inside Claude Code sessions; the user never invokes this directly.

**Domain:** Developer tooling / CLI

**Success in 30 days:** Session-start token overhead drops 70–80%; `/release` and `/restore-projects` token cost drops 60–75%. Every Foreman command that uses foreman-tools gets its answer in one read, not a chain of shell calls.

**How we'll measure it:** Before/after token counts on a representative session: open Foreman (triggers self-update), run `/release`, run `/restore-projects`. Target: each of the three drops below the thresholds above.

---

## Scope — v1 only

**In:**
- `foreman-tools status <workspace-path>` — session-start data: git fetch result, SHA compare, `.first-run` exists, `_projects.md` exists → single JSON blob
- `foreman-tools commits <repo-path> [since-tag]` — git log since tag, commits categorized into new/improvement/fix/docs/other → JSON array

**Out (explicitly):**
- `foreman-tools repos` (GitHub repo scanning for `/restore-projects`) — v2
- `foreman-tools sha <url>` (tarball SHA256 for `/brew-release`) — v2
- Linux / Windows builds — macOS only through v2
- Interactive mode, colored output, human-readable formatting — JSON only, always

---

## The simplest version that delivers value

A single binary with two subcommands. `status` runs on every session open — the highest-frequency call in all of Foreman. `commits` runs on every release. Both hand Claude a JSON blob and exit. No state, no config, no auth.

---

## Risks

- **Zig API instability** — Zig is pre-1.0; breaking changes between minor versions are real. Pin a specific Zig version in the build and document it explicitly.
- **git subprocess reliability** — foreman-tools calls git via subprocess. If git isn't in PATH or the workspace isn't a git repo, it must fail clearly to stderr and exit 1, not silently return bad JSON.
- **Fallback gap** — Foreman commands must detect foreman-tools absence and fall back gracefully. If the fallback path diverges from the foreman-tools path, they'll produce inconsistent results. Both paths must be tested.
- **Universal binary complexity** — macOS arm64 + amd64 `lipo` merge adds a build step. If CI isn't set up, cross-compilation may require a workaround.

---

## Key decisions — requires explicit sign-off

- [x] Single binary, multiple subcommands (not separate per-operation binaries)
- [x] JSON to stdout, errors to stderr, exit 1 on failure — no other output modes
- [x] Optional dependency: Foreman commands check `command -v foreman-tools`; if absent, fall back to existing inline bash
- [x] Zig 0.16 (pinned in build.zig.zon)
- [x] Distributed via the existing `homebrew-foreman` tap alongside `foreman-ai` — no separate tap
- [x] macOS only for v1 (arm64 + amd64 universal binary)
- [ ] M12: `scan` new fields are additive — existing callers that ignore unknown JSON fields are unaffected; no version flag needed
- [ ] M12: file inventory capped at 500 files sorted largest-first — avoids huge output on monorepos; `fileCount` lets Claude know if the cap was hit
- [ ] M12: kind classification rules — test: `*.test.*`, `*.spec.*`, `*_test.*`, `test_*`, files in `test/` or `tests/` dirs; config: existing KNOWN_CONFIG_FILES list; docs: `*.md`, `*.txt`, files in `docs/`; source: everything else
- [ ] M12: entry point detection order — `main.go`, `cmd/*/main.go`, `index.js`, `index.ts`, `src/index.js`, `src/index.ts`, `src/main.*`, `app.py`, `main.py`, `bin/<repo-name>` (from repo dirname); first match wins, null if none found
- [ ] M13: `diff-dirs` is structural only — compares paths and byte sizes, no file content; `same: bool` is derived from equal byte counts (not a real content hash)
- [ ] M17: `gh-release` shells out to `gh` (not a native GitHub API call) — keeps auth delegation to `gh` the same as today; notes file is a temp file written by Claude, read by foreman-tools, deleted after the call

---

## Open questions

- Should `status` do the actual `git fetch` or just read the already-fetched `origin/main` ref? Fetching adds latency on every session open; reading the ref is instant but stale if fetch hasn't run. Lean toward read-only for speed, let the self-update skill decide whether to fetch.
- `gh-user` calls `gh` as a subprocess — `gh` may not be in PATH on all installs. Exit 0 with `{"authenticated": false, "login": ""}` or exit 1? Lean toward exit 0 with unauthenticated state so callers don't need to handle the error case differently.

---

## Milestones

| Milestone | What a user can do | Done when... |
|-----------|-------------------|--------------|
| Milestone | What a user can do | Done when... |
|-----------|-------------------|--------------|
| M1 — status subcommand | Session-start check outputs JSON in <10ms | `foreman-tools status ~/foreman` exits 0 and returns valid JSON with all four fields: `upToDate`, `behindBy`, `firstRun`, `projectsFileExists` |
| M2 — commits subcommand | Release workflow hands Claude categorized JSON | `foreman-tools commits ~/foreman/myproject v1.2.0` returns JSON array of commits since that tag, each with `hash`, `category`, `message`; categories are one of `new`, `improvement`, `fix`, `docs`, `other` |
| M3 — Homebrew distribution + Foreman integration | foreman-tools installs alongside foreman-ai; all relevant Foreman commands use it when present | `brew install foreman-ai` installs foreman-tools binary; `/self-update` and `/release` use foreman-tools when available, fall back cleanly when not; token savings verified against baseline |
| M4 — gh-user subcommand | GitHub auth check + username in one call | `foreman-tools gh-user` exits 0 and returns `{"authenticated": bool, "login": "string"}`; exits 0 with `authenticated: false` when `gh` is absent or not logged in; `/first-run`, `/restore-projects`, `/sync-memory`, `/setup-automation`, and `github-repo` skill use it when available |
| M5 — release-info subcommand | Release pre-flight in one call | `foreman-tools release-info <path>` returns `{"latestTag": "string\|null", "suggestedNext": "string", "commitsSince": N, "isDirty": bool}`; `/release`, `/release-notes`, and `/brew-release` use it when available |
| M6 — repo-info subcommand | Remote URL parsed to owner/repo in one call | `foreman-tools repo-info <path>` returns `{"owner": "string", "repo": "string", "url": "string"}`; eliminates SSH-vs-HTTPS parsing in `/release`, `/brew-release`, and `/sync-memory` |
| M7 — tag-exists subcommand | Tag pre-flight check in one call | `foreman-tools tag-exists <path> <tag>` returns `{"exists": bool}`; `/release` and `/brew-release` use it when available |
| M8 — doctor subcommand | Dependency check in one call | `foreman-tools doctor` returns `{"claude": bool, "git": bool, "gh": bool, "version": "string"}`; `/first-run`, `CLAUDE.md` session-start guardrail, and `foreman-ai` launcher use it when available |
| M9 — changes-preview subcommand | Incoming update summary in one call | `foreman-tools changes-preview <path>` returns `{"commits": [...], "filesChanged": N}`; `self-update` skill uses it instead of raw `git log` + `git diff --stat` |
| M10 — scan subcommand | Project structure summary in one call | `foreman-tools scan <path>` returns `{"framework": "string", "keyFiles": [...], "depCount": N, "dirMap": [...]}`; `/absorb` and `/new-project` use it instead of manual filesystem browsing |
| M11 — list-projects subcommand | GitHub Foreman project list in one call | `foreman-tools list-projects` returns `[{"name", "url", "isForeman": bool, "isLocal": bool}]`; `/restore-projects` uses it instead of `gh repo list` + per-repo API checks |
| M12 — scan file inventory | Full repo map in one call; Claude reads which files to open instead of exploring | `foreman-tools scan <path>` gains three new fields (additive, non-breaking): `"entryPoint": string\|null` (detected main file — `main.go`, `index.js/ts`, `src/main.*`, `app.py`, `cmd/*/main.go`, `bin/<name>`); `"files": [{"path": string, "bytes": N, "kind": "source"\|"test"\|"config"\|"docs"\|"other"}]` (flat inventory, capped at 500 files, sorted largest-first); `"fileCount": N` (total before cap). `/absorb`, `/new-project`, and the `software-projects` skill use the file list to prioritize reads instead of running `find`/`ls` chains |
| M13 — diff-dirs subcommand | Structural comparison of two directories in one call | `foreman-tools diff-dirs <path1> <path2>` returns `{"onlyInA": [string], "onlyInB": [string], "inBoth": [{"path": string, "bytesA": N, "bytesB": N, "same": bool}]}` where paths are relative and the same SCAN_SKIP_DIRS exclusions apply; used when Claude needs to compare two projects, a project against a template, or two branches of similar work |
| M14 — tarball-sha subcommand | GitHub tarball SHA256 in one call with retry | `foreman-tools tarball-sha <owner> <repo> <tag>` fetches `https://github.com/<owner>/<repo>/archive/refs/tags/<tag>.tar.gz`, computes SHA256, retries once after 10s if the empty-file hash is returned (`e3b0c44...`); returns `{"sha256": "string", "url": "string"}`; `/brew-release` uses it instead of `curl \| shasum -a 256` |
| M15 — formula-info subcommand | Homebrew formula fields in one call | `foreman-tools formula-info <tap-path> <formula-name>` reads the `.rb` file, parses `url`, `sha256`, `version` fields; returns `{"formulaPath": "string", "url": "string", "sha256": "string", "version": "string"}`; `/brew-release` uses it instead of manual Ruby file parsing |
| M16 — validate-hooks subcommand | Claude Code Stop hooks check in one call | `foreman-tools validate-hooks` reads `~/.claude/settings.json`, checks that both Stop hooks (memory-sync + auto-push) exist by `statusMessage`; returns `{"memorySync": bool, "autoPush": bool}`; `/setup-automation` and `/first-run` use it instead of `jq` traversal |
| M17 — gh-release subcommand | GitHub release creation without shell escaping | `foreman-tools gh-release <owner> <repo> <tag> <title> <notes-file>` reads release notes from a file (avoiding heredoc/quote escaping), calls `gh release create`; returns `{"url": "string"}`; `/release` and `/brew-release` use it instead of inline `gh release create --notes "..."` |
| M18 — file-hash subcommand | SHA256 of any file in one call | `foreman-tools file-hash <file-path>` returns `{"path": "string", "sha256": "string", "bytes": N}`; foundation for cache-engine change detection — callers store hashes and compare on subsequent calls to skip unchanged reads |
| M19 — cache-check subcommand | Persistent change detection in one call | `foreman-tools cache-check <file-path>` returns `{"path": "string", "sha256": "string", "changed": bool, "cached": bool}`; persists hash to `~/.cache/foreman-tools/<sha256-of-path>`; `changed: false` means file is identical to last check — caller can skip the read |
| M20 — cache-store/cache-fetch subcommands | Store and retrieve arbitrary JSON values keyed to a file's content hash | `cache-store <file-path> <sub-key>` (value via stdin) persists `sha256+value`; `cache-fetch <file-path> <sub-key>` returns `{"hit": bool, "value": <raw json>}`; `hit: true` = file unchanged + value cached; auto-invalidates when file changes |
| M24 — context-rank subcommand (Context Optimizer M13 M1) | Relevance ranking — which files to read first for a given question | `foreman-tools context-rank <root-path> <query>` returns top 15 files by composite score (content hits × 5 + name match × 300 + kind bonus); scans all files, reads first 8 KB each; `.DS_Store` + binary files excluded |
| M23 — context-changed subcommand (Context Builder M12 M3) | Diff with content in one call — orient to what changed without reading raw git output | `foreman-tools context-changed <repo-path> [ref]` returns `{"ref", "totalFiles", "totalAdditions", "totalDeletions", "truncated", "files": [{path, status, additions, deletions, diff}]}`; first 8 files, diff capped at 100 lines each; default ref is HEAD (all uncommitted changes) |
| M22 — context-evidence subcommand (Context Builder M12 M2) | Evidence packets — relevant excerpts from a file without reading the whole thing | `foreman-tools context-evidence <abs-file-path> <pattern>` returns `{"path", "pattern", "fileBytes", "matchCount", "chunks": [{startLine, endLine, content}]}`; case-insensitive literal search; ±10 lines context per match; overlapping windows merged; capped at 8 chunks; Claude calls this instead of reading the full file when it only needs to answer a question about a specific function, rule, or keyword |
| M21 — context-scan subcommand (Context Builder M12 M1) | Compact project summary in one call; replaces full `scan` for context-loading | `foreman-tools context-scan <path>` returns `{"framework", "entryPoint", "fileCount", "summary": {source/test/config/docs/other counts}, "topFiles": [{path, bytes}] (top 10), "keyFiles", "dirs"}`; Claude reads this instead of `scan` when it only needs structure, not the full file inventory |
| M25 — yaml-query subcommand | Read a value from any YAML file without loading the whole file | `foreman-tools yaml-query <file-path> <dot-path>` returns `{"path", "found", "type", "value"}`; same shape as `json-query` and `toml-query`; handles nested mappings + sequence indexing; covers GitHub Actions, docker-compose, k8s, Rails config |
| M26 — outline subcommand | Source file structure in one call — no full read needed | `foreman-tools outline <file-path>` returns `{"path", "lang", "symbols": [{name, kind, line}]}`; extracts function/class/struct/enum/trait/interface names with line numbers; covers Go, Python, JS, TS, Rust, Zig, Ruby, Java, Kotlin, C#, Swift, PHP; capped at 200 symbols |
| M27 — deps subcommand | Project dependencies in one call without reading the full manifest | `foreman-tools deps <root-path>` returns `{"manifest", "format", "totalCount", "deps": [{name, version, dev}]}`; auto-detects package.json/Cargo.toml/go.mod/requirements.txt; capped at 100 deps |
| M28 — run-tests subcommand (Module 18 M1–M3) | Detect test framework, run tests, return structured pass/fail/failures — no raw output parsing | `foreman-tools run-tests <path>` auto-detects framework (jest/pytest/go/cargo/zig/bats), runs tests, returns `{"framework", "command", "success", "passed", "failed", "skipped", "duration_ms", "failures": [{file, line, test, message}], "truncated"}`; failures capped at 50; Claude reads verdict + failures without seeing raw test runner output |
| M29 — build subcommand (Module 17 M1–M4) | Detect build system, run build, return structured errors/warnings — no raw compiler output parsing | `foreman-tools build <path>` auto-detects build system (cargo/go/zig/npm/make), runs the build command, returns `{"tool", "command", "success", "errors": [{file, line, col, message, severity}], "warnings": [{file, line, col, message}], "duration_ms", "truncated"}`; errors capped at 50, warnings capped at 20; Claude reads verdict + structured errors without parsing raw compiler output |
| M30 — device-scan subcommand (Module 30 M1) | Snapshot hardware, installed tools, and optimal settings — Claude reads this at session start instead of re-discovering the environment | `foreman-tools device-scan` returns `{"profile_id", "hardware": {cpu, cores, ram_gb, os, arch}, "tools": {zig/git/gh/brew/node/python3/go/cargo/foreman_tools — each with present/version/path}, "optimal": {zig_build_flags, bottleneck, git_spawn_ms_estimate}, "shell", "scanned_at"}`; profile_id is a stable slug (e.g. `apple_m3_pro_36gb_macos_arm64`); saved to `~/.foreman/profile.json`; public-safe subset (no user paths) contributed to `foreman-env` repo with user consent |
| M31 — compat-check subcommand (Module 31 M1–M3) | Zero-token session guard — detect tool version drift before the first user prompt, surface rollback advice, prevent silent Foreman breakage | `foreman-tools compat-check` compares current tool versions (zig, git, gh, homebrew, node, python3, foreman_tools) against `~/.foreman/compat-baseline.json`; returns `{"ok", "baselineAge", "drifted": [{"tool", "was", "now", "risk", "rollback"}], "advice"}`; `ok: true` → all tools match baseline; `ok: false` → advice string contains specific rollback commands; `--baseline` flag snapshots current versions; `--update-baseline` flag promotes current versions to new baseline + optionally pushes verified compat matrix to `foreman-env` repo; zero Claude tokens — advice is pre-computed Zig output, not a prompt |
| M32 — plugin-run subcommand (Module 11 M1) ← IMPLEMENT NEXT | Execute a user-defined plugin in one call — extends foreman-tools without recompiling Zig | `foreman-tools plugin-run <name> [args...]` loads `~/.foreman/plugins/<name>/plugin.json`, validates required fields (`name`, `lang`, `entry`), executes the entry script via the `worker-run` runtime for `lang`, passes `args` through, returns the script's JSON stdout verbatim; exits 1 with `{"error": "plugin not found"}` if directory missing, `{"error": "invalid manifest: <reason>"}` if manifest malformed, or `{"error": "worker failed: <stderr>"}` if the script itself crashes; `route` and `capability-check` treat installed plugins as first-class capabilities alongside native subcommands |
| M33 — plugin-list subcommand (Module 11 M2) | Discover all installed plugins in one call — `capability-check` and `route` pick these up automatically | `foreman-tools plugin-list` walks `~/.foreman/plugins/`, reads each `plugin.json`, returns `{"plugins": [{"name", "lang", "description", "args", "entry"}], "count": N}`; same shape as `worker-list`; skips subdirectories with missing or unparseable manifests (logs path in a `"skipped"` array); `capability-check <query>` and `route <task>` merge plugin results with native subcommands so Claude gets a single unified capability map |
