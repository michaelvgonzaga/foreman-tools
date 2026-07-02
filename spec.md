# 4orman-tools Spec

See `api-schema.md` for the locked JSON output contract for all subcommands.

---

**The real goal:** Replace Claude's inline token-expensive shell reasoning with a native binary that hands back a JSON blob — Claude reads, not reasons.

**Who it's for:** 4ORMan's command files running inside Claude Code sessions; the user never invokes this directly.

**Domain:** Developer tooling / CLI

**Success in 30 days:** Session-start token overhead drops 70–80%; `/release` and `/restore-projects` token cost drops 60–75%. Every 4ORMan command that uses 4orman-tools gets its answer in one read, not a chain of shell calls.

**How we'll measure it:** Before/after token counts on a representative session: open 4ORMan (triggers self-update), run `/release`, run `/restore-projects`. Target: each of the three drops below the thresholds above.

---

## Scope — v1 only

**In:**
- `4orman-tools status <workspace-path>` — session-start data: git fetch result, SHA compare, `.first-run` exists, `_projects.md` exists → single JSON blob
- `4orman-tools commits <repo-path> [since-tag]` — git log since tag, commits categorized into new/improvement/fix/docs/other → JSON array

**Out (explicitly):**
- `4orman-tools repos` (GitHub repo scanning for `/restore-projects`) — v2
- `4orman-tools sha <url>` (tarball SHA256 for `/brew-release`) — v2
- Linux / Windows builds — macOS only through v2
- Interactive mode, colored output, human-readable formatting — JSON only, always

---

## The simplest version that delivers value

A single binary with two subcommands. `status` runs on every session open — the highest-frequency call in all of 4ORMan. `commits` runs on every release. Both hand Claude a JSON blob and exit. No state, no config, no auth.

---

## Risks

- **Zig API instability** — Zig is pre-1.0; breaking changes between minor versions are real. Pin a specific Zig version in the build and document it explicitly.
- **git subprocess reliability** — 4orman-tools calls git via subprocess. If git isn't in PATH or the workspace isn't a git repo, it must fail clearly to stderr and exit 1, not silently return bad JSON.
- **Fallback gap** — 4ORMan commands must detect 4orman-tools absence and fall back gracefully. If the fallback path diverges from the 4orman-tools path, they'll produce inconsistent results. Both paths must be tested.
- **Universal binary complexity** — macOS arm64 + amd64 `lipo` merge adds a build step. If CI isn't set up, cross-compilation may require a workaround.

---

## Key decisions — requires explicit sign-off

- [x] Single binary, multiple subcommands (not separate per-operation binaries)
- [x] JSON to stdout, errors to stderr, exit 1 on failure — no other output modes
- [x] Optional dependency: 4ORMan commands check `command -v 4orman-tools`; if absent, fall back to existing inline bash
- [x] Zig 0.16 (pinned in build.zig.zon)
- [x] Distributed via the existing `homebrew-4orman` tap alongside `4orman-ai` — no separate tap
- [x] macOS only for v1 (arm64 + amd64 universal binary)
- [ ] M12: `scan` new fields are additive — existing callers that ignore unknown JSON fields are unaffected; no version flag needed
- [ ] M12: file inventory capped at 500 files sorted largest-first — avoids huge output on monorepos; `fileCount` lets Claude know if the cap was hit
- [ ] M12: kind classification rules — test: `*.test.*`, `*.spec.*`, `*_test.*`, `test_*`, files in `test/` or `tests/` dirs; config: existing KNOWN_CONFIG_FILES list; docs: `*.md`, `*.txt`, files in `docs/`; source: everything else
- [ ] M12: entry point detection order — `main.go`, `cmd/*/main.go`, `index.js`, `index.ts`, `src/index.js`, `src/index.ts`, `src/main.*`, `app.py`, `main.py`, `bin/<repo-name>` (from repo dirname); first match wins, null if none found
- [ ] M13: `diff-dirs` is structural only — compares paths and byte sizes, no file content; `same: bool` is derived from equal byte counts (not a real content hash)
- [ ] M17: `gh-release` shells out to `gh` (not a native GitHub API call) — keeps auth delegation to `gh` the same as today; notes file is a temp file written by Claude, read by 4orman-tools, deleted after the call

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
| M1 — status subcommand | Session-start check outputs JSON in <10ms | `4orman-tools status ~/4orman` exits 0 and returns valid JSON with all four fields: `upToDate`, `behindBy`, `firstRun`, `projectsFileExists` |
| M2 — commits subcommand | Release workflow hands Claude categorized JSON | `4orman-tools commits ~/4orman/myproject v1.2.0` returns JSON array of commits since that tag, each with `hash`, `category`, `message`; categories are one of `new`, `improvement`, `fix`, `docs`, `other` |
| M3 — Homebrew distribution + 4ORMan integration | 4orman-tools installs alongside 4orman-ai; all relevant 4ORMan commands use it when present | `brew install 4orman-ai` installs 4orman-tools binary; `/self-update` and `/release` use 4orman-tools when available, fall back cleanly when not; token savings verified against baseline |
| M4 — gh-user subcommand | GitHub auth check + username in one call | `4orman-tools gh-user` exits 0 and returns `{"authenticated": bool, "login": "string"}`; exits 0 with `authenticated: false` when `gh` is absent or not logged in; `/first-run`, `/restore-projects`, `/sync-memory`, `/setup-automation`, and `github-repo` skill use it when available |
| M5 — release-info subcommand | Release pre-flight in one call | `4orman-tools release-info <path>` returns `{"latestTag": "string\|null", "suggestedNext": "string", "commitsSince": N, "isDirty": bool}`; `/release`, `/release-notes`, and `/brew-release` use it when available |
| M6 — repo-info subcommand | Remote URL parsed to owner/repo in one call | `4orman-tools repo-info <path>` returns `{"owner": "string", "repo": "string", "url": "string"}`; eliminates SSH-vs-HTTPS parsing in `/release`, `/brew-release`, and `/sync-memory` |
| M7 — tag-exists subcommand | Tag pre-flight check in one call | `4orman-tools tag-exists <path> <tag>` returns `{"exists": bool}`; `/release` and `/brew-release` use it when available |
| M8 — doctor subcommand | Dependency check in one call | `4orman-tools doctor` returns `{"claude": bool, "git": bool, "gh": bool, "version": "string"}`; `/first-run`, `CLAUDE.md` session-start guardrail, and `4orman-ai` launcher use it when available |
| M9 — changes-preview subcommand | Incoming update summary in one call | `4orman-tools changes-preview <path>` returns `{"commits": [...], "filesChanged": N}`; `self-update` skill uses it instead of raw `git log` + `git diff --stat` |
| M10 — scan subcommand | Project structure summary in one call | `4orman-tools scan <path>` returns `{"framework": "string", "keyFiles": [...], "depCount": N, "dirMap": [...]}`; `/absorb` and `/new-project` use it instead of manual filesystem browsing |
| M11 — list-projects subcommand | GitHub 4ORMan project list in one call | `4orman-tools list-projects` returns `[{"name", "url", "isForeman": bool, "isLocal": bool}]`; `/restore-projects` uses it instead of `gh repo list` + per-repo API checks |
| M12 — scan file inventory | Full repo map in one call; Claude reads which files to open instead of exploring | `4orman-tools scan <path>` gains three new fields (additive, non-breaking): `"entryPoint": string\|null` (detected main file — `main.go`, `index.js/ts`, `src/main.*`, `app.py`, `cmd/*/main.go`, `bin/<name>`); `"files": [{"path": string, "bytes": N, "kind": "source"\|"test"\|"config"\|"docs"\|"other"}]` (flat inventory, capped at 500 files, sorted largest-first); `"fileCount": N` (total before cap). `/absorb`, `/new-project`, and the `software-projects` skill use the file list to prioritize reads instead of running `find`/`ls` chains |
| M13 — diff-dirs subcommand | Structural comparison of two directories in one call | `4orman-tools diff-dirs <path1> <path2>` returns `{"onlyInA": [string], "onlyInB": [string], "inBoth": [{"path": string, "bytesA": N, "bytesB": N, "same": bool}]}` where paths are relative and the same SCAN_SKIP_DIRS exclusions apply; used when Claude needs to compare two projects, a project against a template, or two branches of similar work |
| M14 — tarball-sha subcommand | GitHub tarball SHA256 in one call with retry | `4orman-tools tarball-sha <owner> <repo> <tag>` fetches `https://github.com/<owner>/<repo>/archive/refs/tags/<tag>.tar.gz`, computes SHA256, retries once after 10s if the empty-file hash is returned (`e3b0c44...`); returns `{"sha256": "string", "url": "string"}`; `/brew-release` uses it instead of `curl \| shasum -a 256` |
| M15 — formula-info subcommand | Homebrew formula fields in one call | `4orman-tools formula-info <tap-path> <formula-name>` reads the `.rb` file, parses `url`, `sha256`, `version` fields; returns `{"formulaPath": "string", "url": "string", "sha256": "string", "version": "string"}`; `/brew-release` uses it instead of manual Ruby file parsing |
| M16 — validate-hooks subcommand | Claude Code Stop hooks check in one call | `4orman-tools validate-hooks` reads `~/.claude/settings.json`, checks that both Stop hooks (memory-sync + auto-push) exist by `statusMessage`; returns `{"memorySync": bool, "autoPush": bool}`; `/setup-automation` and `/first-run` use it instead of `jq` traversal |
| M17 — gh-release subcommand | GitHub release creation without shell escaping | `4orman-tools gh-release <owner> <repo> <tag> <title> <notes-file>` reads release notes from a file (avoiding heredoc/quote escaping), calls `gh release create`; returns `{"url": "string"}`; `/release` and `/brew-release` use it instead of inline `gh release create --notes "..."` |
| M18 — file-hash subcommand | SHA256 of any file in one call | `4orman-tools file-hash <file-path>` returns `{"path": "string", "sha256": "string", "bytes": N}`; foundation for cache-engine change detection — callers store hashes and compare on subsequent calls to skip unchanged reads |
| M19 — cache-check subcommand | Persistent change detection in one call | `4orman-tools cache-check <file-path>` returns `{"path": "string", "sha256": "string", "changed": bool, "cached": bool}`; persists hash to `~/.cache/4orman-tools/<sha256-of-path>`; `changed: false` means file is identical to last check — caller can skip the read |
| M20 — cache-store/cache-fetch subcommands | Store and retrieve arbitrary JSON values keyed to a file's content hash | `cache-store <file-path> <sub-key>` (value via stdin) persists `sha256+value`; `cache-fetch <file-path> <sub-key>` returns `{"hit": bool, "value": <raw json>}`; `hit: true` = file unchanged + value cached; auto-invalidates when file changes |
| M24 — context-rank subcommand (Context Optimizer M13 M1) | Relevance ranking — which files to read first for a given question | `4orman-tools context-rank <root-path> <query>` returns top 15 files by composite score (content hits × 5 + name match × 300 + kind bonus); scans all files, reads first 8 KB each; `.DS_Store` + binary files excluded |
| M23 — context-changed subcommand (Context Builder M12 M3) | Diff with content in one call — orient to what changed without reading raw git output | `4orman-tools context-changed <repo-path> [ref]` returns `{"ref", "totalFiles", "totalAdditions", "totalDeletions", "truncated", "files": [{path, status, additions, deletions, diff}]}`; first 8 files, diff capped at 100 lines each; default ref is HEAD (all uncommitted changes) |
| M22 — context-evidence subcommand (Context Builder M12 M2) | Evidence packets — relevant excerpts from a file without reading the whole thing | `4orman-tools context-evidence <abs-file-path> <pattern>` returns `{"path", "pattern", "fileBytes", "matchCount", "chunks": [{startLine, endLine, content}]}`; case-insensitive literal search; ±10 lines context per match; overlapping windows merged; capped at 8 chunks; Claude calls this instead of reading the full file when it only needs to answer a question about a specific function, rule, or keyword |
| M21 — context-scan subcommand (Context Builder M12 M1) | Compact project summary in one call; replaces full `scan` for context-loading | `4orman-tools context-scan <path>` returns `{"framework", "entryPoint", "fileCount", "summary": {source/test/config/docs/other counts}, "topFiles": [{path, bytes}] (top 10), "keyFiles", "dirs"}`; Claude reads this instead of `scan` when it only needs structure, not the full file inventory |
| M25 — yaml-query subcommand | Read a value from any YAML file without loading the whole file | `4orman-tools yaml-query <file-path> <dot-path>` returns `{"path", "found", "type", "value"}`; same shape as `json-query` and `toml-query`; handles nested mappings + sequence indexing; covers GitHub Actions, docker-compose, k8s, Rails config |
| M26 — outline subcommand | Source file structure in one call — no full read needed | `4orman-tools outline <file-path>` returns `{"path", "lang", "symbols": [{name, kind, line}]}`; extracts function/class/struct/enum/trait/interface names with line numbers; covers Go, Python, JS, TS, Rust, Zig, Ruby, Java, Kotlin, C#, Swift, PHP; capped at 200 symbols |
| M27 — deps subcommand | Project dependencies in one call without reading the full manifest | `4orman-tools deps <root-path>` returns `{"manifest", "format", "totalCount", "deps": [{name, version, dev}]}`; auto-detects package.json/Cargo.toml/go.mod/requirements.txt; capped at 100 deps |
| M28 — run-tests subcommand (Module 18 M1–M3) | Detect test framework, run tests, return structured pass/fail/failures — no raw output parsing | `4orman-tools run-tests <path>` auto-detects framework (jest/pytest/go/cargo/zig/bats), runs tests, returns `{"framework", "command", "success", "passed", "failed", "skipped", "duration_ms", "failures": [{file, line, test, message}], "truncated"}`; failures capped at 50; Claude reads verdict + failures without seeing raw test runner output |
| M29 — build subcommand (Module 17 M1–M4) | Detect build system, run build, return structured errors/warnings — no raw compiler output parsing | `4orman-tools build <path>` auto-detects build system (cargo/go/zig/npm/make), runs the build command, returns `{"tool", "command", "success", "errors": [{file, line, col, message, severity}], "warnings": [{file, line, col, message}], "duration_ms", "truncated"}`; errors capped at 50, warnings capped at 20; Claude reads verdict + structured errors without parsing raw compiler output |
| M30 — device-scan subcommand (Module 30 M1) | Snapshot hardware, installed tools, and optimal settings — Claude reads this at session start instead of re-discovering the environment | `4orman-tools device-scan` returns `{"profile_id", "hardware": {cpu, cores, ram_gb, os, arch}, "tools": {zig/git/gh/brew/node/python3/go/cargo/foreman_tools — each with present/version/path}, "optimal": {zig_build_flags, bottleneck, git_spawn_ms_estimate}, "shell", "scanned_at"}`; profile_id is a stable slug (e.g. `apple_m3_pro_36gb_macos_arm64`); saved to `~/.4orman/profile.json`; public-safe subset (no user paths) contributed to `4orman-env` repo with user consent |
| M31 — compat-check subcommand (Module 31 M1–M3) | Zero-token session guard — detect tool version drift before the first user prompt, surface rollback advice, prevent silent 4ORMan breakage | `4orman-tools compat-check` compares current tool versions (zig, git, gh, homebrew, node, python3, foreman_tools) against `~/.4orman/compat-baseline.json`; returns `{"ok", "baselineAge", "drifted": [{"tool", "was", "now", "risk", "rollback"}], "advice"}`; `ok: true` → all tools match baseline; `ok: false` → advice string contains specific rollback commands; `--baseline` flag snapshots current versions; `--update-baseline` flag promotes current versions to new baseline + optionally pushes verified compat matrix to `4orman-env` repo; zero Claude tokens — advice is pre-computed Zig output, not a prompt |
| M32 — plugin-run subcommand (Module 11 M1) ← IMPLEMENT NEXT | Execute a user-defined plugin in one call — extends 4orman-tools without recompiling Zig | `4orman-tools plugin-run <name> [args...]` loads `~/.4orman/plugins/<name>/plugin.json`, validates required fields (`name`, `lang`, `entry`), executes the entry script via the `worker-run` runtime for `lang`, passes `args` through, returns the script's JSON stdout verbatim; exits 1 with `{"error": "plugin not found"}` if directory missing, `{"error": "invalid manifest: <reason>"}` if manifest malformed, or `{"error": "worker failed: <stderr>"}` if the script itself crashes; `route` and `capability-check` treat installed plugins as first-class capabilities alongside native subcommands |
| M33 — plugin-list subcommand (Module 11 M2) | Discover all installed plugins in one call — `capability-check` and `route` pick these up automatically | `4orman-tools plugin-list` walks `~/.4orman/plugins/`, reads each `plugin.json`, returns `{"plugins": [{"name", "lang", "description", "args", "entry"}], "count": N}`; same shape as `worker-list`; skips subdirectories with missing or unparseable manifests (logs path in a `"skipped"` array); `capability-check <query>` and `route <task>` merge plugin results with native subcommands so Claude gets a single unified capability map |
| M34 — context-gate subcommand (Module 12/13 evolution) | One task-aware call that composes the existing context primitives into a single Compact Context Manifest, instead of Claude chaining 4+ separate calls | `4orman-tools context-gate <path> --task "<description>"` internally calls the already-shipped `context-rank` (M24), `context-changed` (M23), and `secret-scan` (M19-M1) rather than reimplementing file walking or scanning; returns `{"task", "token_estimate", "risk", "include": {"files": [...], "errors": [...], "diff": bool}, "exclude": {"dirs": [...], "large_files": bool, "secrets": bool}, "next_action": {"send_to_ai": bool, "reason": string}}`; JSON to stdout only, no filesystem writes. **Implemented, not yet released** — `--test-cmd` deferred (out of v1 cut, `errors` always returns `[]` for now) |
| M35 — context-budget subcommand (Module 13 evolution) | Token estimate + risk classification for a given file/diff set, callable standalone or from `context-gate` | `4orman-tools context-budget <path> [<path>...]` sums byte counts, estimates tokens (bytes/4 heuristic), classifies risk low/medium/high against fixed thresholds (<2000 low, <8000 medium, else high); returns `{"tokenEstimate", "risk", "breakdown": [{"path", "bytes", "tokens"}]}`. **Implemented, not yet released** |
| M36 — context-classifier subcommand (Module 13 evolution) | Task-type detection from a free-text description, so `context-gate` fetches different context for a compile error vs. an architecture refactor | `4orman-tools context-classifier "<task description>"` returns `{"task_type": "compile_error"\|"architecture_refactor"\|"bug_fix"\|"feature"\|"other", "confidence": float, "signals": [string]}`; keyword/pattern-based (~35 signal phrases across 4 categories), no ML; confidence = winning category's match count / total matches across all categories. **Implemented, not yet released**; not yet wired into `context-gate` |
| M37 — context-dependency-graph subcommand (Module 6 evolution) | Import/module graph for a file, reusing `outline`'s (M26) per-language detection | `4orman-tools context-dependency-graph <root-path> <rel-file-path>` returns `{"root", "imports": [...], "importedBy": [...]}`; line-based import extraction (go/python/javascript/typescript/rust/zig); `importedBy` is a heuristic substring match on the target's basename across the project, not a resolved graph — known false-positive source (e.g. a file mentioning "main" in prose, not code, still matches). **Implemented, not yet released**; not yet wired into `context-gate` |
| M38 — context-compressor subcommand (Module 12 evolution) | Summarize/truncate large files or diffs before inclusion in a manifest | `4orman-tools context-compressor <file-path> [--max-lines N]` (default 200) returns `{"path", "originalLines", "compressedLines", "summary"}`; under the cap returns the file unchanged; over the cap returns head + `"... N lines omitted ..."` + tail. **Implemented, not yet released**; not yet wired into `context-gate` |
| M39 — update subcommand, field-reports #1-3 (Field Reports plan #1-3) | Project-scoped operational memory that survives across sessions — discover, verify, checkpoint, resume | `4orman-tools update <project-root>` resolves the path, derives `project_id` (basename), creates/loads `~/.4orman/field-reports/<project_id>/` (same `~/.4orman/` convention as `ledger.json`, not a new location), runs `computeScan` for discovery and `computeQualityGate` as the verify step, writes `state.json` (`project`, `status`, `current_task`, `progress`, `last_checkpoint`, `resume_point`, `last_updated`), and appends one JSON-line entry each to `attempts.log` and `verification.log`. Returns `{"projectId", "fieldReportPath", "status", "progress", "discoverSummary", "verifyPassed"}`. `status` is `"idle"` when quality-gate passes, `"blocked"` when it doesn't. **Implemented, not yet released.** Scope explicitly excludes #4+ from the priority plan — no `solved.toml`/`blocked.toml`, no capability routing, no actual repair "execute work" step yet; `update` currently only discovers + verifies + checkpoints, it does not fix anything |
| M40 — field-report-solve / field-report-block subcommands (Field Reports plan #4) | Write reusable-solution and blocked-need-Claude records to a project's field report | `4orman-tools field-report-solve <project-root>` and `4orman-tools field-report-block <project-root>` both read an entry as JSON on stdin (matching the `cache-store` convention) and append a `[[solved]]`/`[[blocked]]` TOML array-of-tables block to `solved.toml`/`blocked.toml` in the project's field-report dir. `field-report-block` additionally demotes `state.json.status` to `"blocked"` and sets `resume_point` to `"review-field-reports"` — state.json stays the single source of truth for "what happens next", blocked.toml is the evidence trail, not a second place callers must check. Returns `{"fieldReportPath", "file"}`. **Implemented, not yet released.** Scope explicitly excludes: `review-field-reports` (#6, not started), the shared `.4orman/solutions.toml` ledger / graduation gate (#7, not started — extends the existing `ledger` subcommand per spec, not a new store) |
| M41 — review-field-reports subcommand (Field Reports plan #6) | Cross-project blocker summary — one call instead of manually scanning every `blocked.toml` | `4orman-tools review-field-reports` (no args) walks every `~/.4orman/field-reports/<project_id>/`, and for each project whose `state.json.status == "blocked"` parses `blocked.toml` and returns only its most recent `[[blocked]]` entry — not the full history, since older entries may already be superseded by a later solve and there is no per-entry "resolved" marker yet; `state.json.status` is the authoritative "still needs help" signal. Returns `{"projectsScanned", "blockers": [{"projectId", "objective", "context", "attempted", "blocker", "minimumHelpNeeded", "suggestedNextStep", "lastUpdated"}]}`, sorted newest-first. **Implemented, not yet released.** Priority is by recency only — true ROI/determinism/reuse-potential scoring (as the original spec asked for) needs metadata this schema doesn't capture yet, same "measure before ranking" gap as spec.md row 14/Wave 5 Phase 3, not solved here. Scope explicitly excludes: writing a solved blocker to the shared `.4orman/solutions.toml` ledger (#7, not started) |

---

## Zig Context Translator — Phase Roadmap & ROI

```
Zig Context Translator
        │
        ▼
Phase 1: Context Optimization → Phase 2: Context Intelligence → Phase 3: Verified Context Learning → Phase 4: Model Profiles + Routing → Phase 5: Self-Improving Context Translator
```

**Confirmed — Phase 1 and Phase 2 are Highest ROI, build them next. Phase 3 is Highest ROI to *design* now (the safeguards below are cheap to write down and prevent rework) but stays Low ROI to *implement* until Phase 1+2 are live and producing real interaction data — the safeguards make Phase 3 safe to build, they don't remove the sequencing dependency.**

### Phase 1 — Context Optimization (MVP)

Goal: deliver the smallest correct context to any AI. Output: a Compact Context Manifest (JSON to stdout — same convention as every other subcommand, no filesystem writes).

**Most of Phase 1 already shipped as separate subcommands** — M21 `context-scan`, M22 `context-evidence`, M23 `context-changed`, M24 `context-rank`, and M19 `secret-scan` already exist (see Milestones table above and `knowledge/decisions.md`). The remaining Phase 1 gap is the *orchestrator*, not new primitives:

| Module | Maps to | ROI | Why |
|--------|---------|-----|-----|
| context_gate | M34 (new) | **Highest** | The only missing piece — composes 5 already-shipped subcommands into one task-aware call instead of Claude chaining them itself. Directly targets the spec.md 60–80% token-overhead metric. |
| context_scout | M21 `context-scan` + M24 `context-rank` (done) | — | Already shipped. No new build. |
| context_ranker | M24 `context-rank` (done) | — | Already shipped. No new build. |
| context_manifest | M34's output shape (new) | **Highest** | Delivered as part of M34 — the JSON blob itself is the manifest. |
| context_budget | M35 (new) | Medium | Cheap utility (bytes/4 heuristic); useful guardrail, not a primary lever on its own. |
| token_estimator | Folded into M35 | Medium | Same reasoning as context_budget — not a separate build. |
| context_redactor | M19 `secret-scan` (done) | — | Already shipped — wire its output into M34's `exclude.secrets` field. |

Practical effect: Phase 1's real remaining cost is ~2 new subcommands (M34, M35), not 7 — the ROI here is unusually high because most of the "MVP" is reuse.

### Phase 2 — Context Intelligence

Goal: make the translator task-aware (a compile error and an architecture refactor need different context) instead of treating every request the same.

| Module | Maps to | ROI | Why |
|--------|---------|-----|-----|
| context_classifier | M36 (new) | **Highest** | The mechanism that prevents over-fetching once Phase 1 ships — biggest lever after the MVP lands. |
| context_dependency_graph | M37 (new) | **Highest** | Reused by nearly every task type (compile-error *and* refactor both need it); also unblocks deeper `symbol-find` (M6-M2) and `delta-context` (M13-M2) work already in the decision log. |
| context_compressor | M38 (new) | **Highest** | Attacks the other half of the token equation — large diffs/files — with high-frequency benefit. |
| context_quality_score | Not yet spec'd | Medium | Diagnostic/observability signal; doesn't reduce tokens by itself. Sequence after M36–M38. |
| context_gap_detector | Not yet spec'd | Medium | Depends on context_classifier + context_dependency_graph existing first. |
| context_expander | Not yet spec'd | Medium | Likely a thin wrapper over `context-evidence`/`context-rank` with broader parameters rather than a new primitive — re-evaluate scope once M36–M38 ship. |

### Phase 3 — Verified Context Learning

Goal: after every interaction, extract what context was actually needed vs. wasted, and store it as a reusable rule — safely.

**ROI: Low right now, Highest eventually.** Nothing to learn from until Phase 1 + 2 are live in production generating real interaction data — building it early means guessing at a schema instead of deriving one from evidence (the project's own "Mathematical proof" / measure-first guardrail applies directly). Revisit once Phase 2 has shipped and accumulated sessions.

**Safeguards — ranked by build priority once Phase 3 starts (not by abstract importance; everything here is required eventually, this is *sequencing*):**

| Safeguard | Priority | Why this position |
|-----------|----------|--------------------|
| Secret redaction always first | **Highest — day 0, non-negotiable** | Must run before any storage, no exceptions. Reuses M19 `secret-scan`, already shipped. Not ROI-ranked like the others — it's a hard gate. |
| Evidence log | **Highest** | Nothing else can be trusted without proof-linking. Directly extends the existing `ledger` subcommand (M-unnumbered, v0.57.0, `~/.foreman/ledger.json`) — reuse its storage + scoring pattern rather than building a second evidence store. |
| Negative memory | **Highest** | Symmetric with evidence log — without storing failures the rule set overfits to survivorship bias. Build alongside evidence log, same storage. |
| Scope control | **Highest** | Tag every rule with task_type/repo/lang/framework/version *from day one* — retrofitting scope tags onto existing rules later is expensive. Reuses M36's `context_classifier` output directly. |
| Human approval gate | **Highest** | Blocks the promotion path before any rule reaches Trusted/Core. Cheap to enforce (a boolean gate), matches the framework's existing "ask first" guardrail pattern for consequential actions. |
| Rollback | **Highest** | Extends the already-shipped `rollback` subcommand pattern (snapshot/list/revert) — reuse, don't rebuild. |
| Expiry / decay | **Highest** | Direct precedent already exists: `ledger check-stale` uses 365-day staleness today. Apply the same mechanism to learned rules. |
| Conflict resolver | Medium | Only matters once there are enough rules to conflict — depends on evidence log + negative memory existing first. |
| A/B testing | Medium | Valuable rigor but expensive to run; can piggyback on the existing ledger "Claude vs. Zig" scoring protocol rather than building a fresh comparison harness. |
| Drift audit | Medium | Reporting/observability (Module 26 — Telemetry, already ranked Low in Wave 4). Good hygiene, not blocking. |

**Anti-drift law (governs all of Phase 3):**

```
Observe → Verify → Store → Promote slowly → Roll back fast
```

**Accepted design:** insert a **Reflection Engine** between the AI and the knowledge base rather than coupling learning logic to Claude specifically:

```
Claude/Codex → Reflection Engine → Knowledge Base
                 ├── Extract reusable lessons
                 ├── Compare expected vs actual context
                 ├── Measure token efficiency
                 ├── Update context rules
                 └── Update model profiles
```

Why: keeps the translator model-agnostic. Lessons come from whichever model is in the seat today; tomorrow they could come from another. The Reflection Engine standardizes lessons into reusable knowledge instead of hard-coding "how Claude teaches Zig."

### Phase 4 — Model Profiles + Model Routing

Purpose: make the translator model-agnostic — Claude, Codex, GPT, Gemini each get the context shape they perform best with.

```
Task → Zig identifies task type → checks model profiles → chooses best model/context format
     → sends optimized context → tracks result → updates profile only after verification
```

**ROI: Medium — upgraded from a prior "Low" assessment.** 4ORMan already has a real 2-model surface today (Claude Code `.claude/commands/` + Codex `.codex/commands/` both exist in the sibling `foreman-codex` workspace) — this isn't speculative GPT/Gemini work, routing between models actually in use has an immediate payoff. Still sequenced after Phase 1–3 because `task_type` (Phase 2) and `success_rate`/`avg_tokens` (Phase 3's evidence log) are required inputs — Phase 4 has nothing to route on until those exist.

| Module | ROI within Phase 4 | Why |
|--------|--------------------|-----|
| model_profile.zig | **Highest** | Foundational schema/struct everything else reads and writes. |
| profile_registry.zig | **Highest** | Index/lookup, needed immediately alongside model_profile. |
| model_router.zig | **Highest** | The actual decision-maker — without it, profiles are inert data. |
| success_tracker.zig | Medium | Feeds `success_rate`/`confidence` into profiles — reuse Phase 3's evidence log rather than rebuilding a second tracker. |
| cost_tracker.zig | Medium | Per-call cost isn't trivially exposed from inside a Claude Code session — start with rough estimates. |
| latency_tracker.zig | Medium | Same caveat as cost_tracker; moderate build cost, moderate payoff. |
| prompt_adapter.zig | Medium | Only pays off once ≥2 models are actually routed through Zig regularly — depends on model_router. |
| context_formatter.zig | Medium | Formats the manifest per model's `preferred_order` — depends on model_router existing first. |

Profile example (illustrative shape, not yet built):

```
model = "claude_code"
task_type = "compile_error"
preferred_order = ["task", "error", "relevant_files", "constraints", "success_criteria"]
max_context_tokens = 8000
prefers_diff = true
prefers_full_file = false
prefers_tests = true
success_rate = 0.94
avg_tokens = 3200
avg_latency = "medium"
cost_rank = "high"
confidence = 0.88
```

**Phase 4 rule:** do not optimize for one AI — learn which AI works best for which task, and only from measured, verified results (same "no assumptions, only measurements" rule as the rest of this codebase's Mathematical Proof guardrail).

### Phase 5 — Self-Improving Context Translator

**ROI: Low near-term, Highest long-term (compounding).** Depends on Phase 3's data pipeline and Phase 4's model spread to be meaningful — premature before Phase 1–2 have proven out real token savings. Tracked metrics once this phase is live: Token Efficiency, Reasoning Success Rate, Missing Context Rate, Over-Context Rate, Retry Rate, Execution Success Rate, Verification Pass Rate, Average Cost, Average Latency — feeding back into the Capability Registry (Module 2).

### Final architecture (target)

```
You → Context Translator
        ├── Context Gate
        ├── Context Scout
        ├── Context Optimizer
        ├── Token Budget
        ├── Manifest Builder
        ├── Model Adapter
        ├── Reflection Engine
        ├── Learning Engine
        ├── Rule Generator
        └── Profile Manager
      → Claude / Codex / GPT / Gemini
      → Execution + Verification
      → Knowledge Feedback → Capability Registry
```

### Build order (highest ROI first)

1. M34 `context-gate` + M35 `context-budget` — the only new Phase 1 primitives; everything else in Phase 1 is already shipped (M19, M21–M24).
2. M36 `context-classifier`, M37 `context-dependency-graph`, M38 `context-compressor` (Phase 2 Highest tier) once Phase 1 is live and measured.
3. Phase 2 Medium tier (`context_quality_score`, `context_gap_detector`, `context_expander`) after the Phase 2 core lands and scope is re-evaluated.
4. Phase 3 safeguards, in the priority order in the table above — secret redaction and evidence log first, conflict resolver / A/B testing / drift audit last — only after Phase 1+2 have live sessions to learn from.
5. Phase 4 `model_profile.zig` / `profile_registry.zig` / `model_router.zig` once Phase 2 (task_type) and Phase 3 (success_rate) exist to feed them.
6. Phase 5 — revisit trigger only, not scheduled work.

---

## 4ORMan Compile — Deterministic-YES Gap Analysis

Every scenario where 4ORMan cannot currently produce a deterministic execution verdict ("YES"). Root-cause types: rule, capability, evidence, verification, metadata, terminal primitive, cache, registry, ledger, architecture, policy, dependency, other. Existing systems are extended, not duplicated — no new ledger/worker/registry/plugin unless it permanently reduces future reasoning.

| # | Issue | Why 4ORMan Cannot Say YES | Root Cause | Existing Component to Extend | Smallest Permanent Fix | Priority | Dependencies |
|---|---|---|---|---|---|---|---|
| 1 | ~~`build`/`deps`/`env-inspect`/`secret-scan`/`outline` panic on valid-but-uncommon input~~ **FIXED**. Actual root cause (not the originally-suspected Zig 0.16 zon syntax): every `*Absolute` API in `std.Io.Dir` (`accessAbsolute`, `openDirAbsolute`, etc.) is undefined behavior when given a relative path — confirmed by reproducing `4orman-tools build .` (relative) crashing while `4orman-tools build /abs/path` (absolute) succeeded on identical input. This affects far more than the 5 originally named — also confirmed on `scan`, `context-scan`, `run-tests`, `quality-gate`, `prod-ready`, `report` (quality-gate/prod-ready/report crash transitively by calling `computeBuild`/`computeDeps` with an unresolved path) | A crash returns zero JSON — `quality-gate`/`prod-ready` can't compute even a deterministic NO, the pipeline just dies. Also the single most common way anyone would actually invoke this tool (`cd myproject && 4orman-tools build .`) | capability | `computeBuild`, `computeDeps`, `computeEnvInspect`, `computeSecretScan`, `computeOutline`, `computeScan`, `computeContextScan`, `computeRunTests`, `computeQualityGate`, `computeProdReady`, `computeReport` (root.zig) | Added `root.resolveAbsolutePath(gpa, io, path)` (wraps `std.Io.Dir.cwd().realPathFileAlloc`) and wired it into all 11 dispatch sites above in main.zig before the path reaches any compute* call. **11 of ~45 path-taking subcommands fixed and verified; the remaining ~34 (e.g. `symbol-find`, `delta-context`, `git-cache`, `knowledge-audit`, `export`/`import`, `context-slice`, `worker-run`, etc.) share the same input shape and very likely share the same bug — not yet individually verified or fixed. Follow-up: audit and patch the rest with the identical 5-line pattern** | Highest (fixed for the 11 confirmed-crashing/highest-value ones; remaining audit still Highest until closed) | none |
| 2 | `sandbox-check` only classifies shell-command strings; `FOREMAN_MODE=gate` is advisory — nothing at the tool-call layer can refuse an action | Enforcement depends on Claude remembering the mode each session; a context reset silently reverts to autopilot with no hard stop | terminal primitive | `sandbox-check` | Extend `sandbox-check` to accept current `FOREMAN_MODE` and return `blocked: true` for caution/destructive ops when mode is `gate` | High | none |
| 3 | `secret-scan` findings are binary; `SecretFinding.severity` is returned but unused for gating (confirmed false positive this session: a field named `excludeSecrets` flagged as `hardcoded-secret`) | `context-gate`'s `send_to_ai` gate blocks equally on a real key and a variable name — operators learn to ignore it, the worst failure mode for a safety gate | verification | `context-gate` (M34), `SecretFinding.severity` | Gate only on `high`/`critical` severity; surface `medium`/`low` as warnings. No new primitive, just use the field already returned | High | none |
| 4 | `context-gate` never executes build/test — `include.errors` always `[]`, `--test-cmd` deferred | `send_to_ai: true` can be returned while actual compile/test state is unknown — "safe context" and "passing code" are conflated | capability | `context-gate` (M34) + already-shipped `run-tests` (M28) / `build` (M29) | Wire `--test-cmd` into `computeContextGate`, fold results into `errors`/`risk` | High | #1 (build/deps must stop panicking first) |
| 5 | `ledger score` trusts Claude's self-reported source list; Zig checks count/format (≥10, cited) but not that a citation was actually fetched live | A fabricated-but-well-formatted citation set scores identically to a real one — the "Claude wins" path has no independent check | verification | `ledger score` | Require a fetch-timestamp/session tool-call hash per citation instead of a free-text URL array | High | session tool-call logging exposed to 4orman-tools (not yet available) |
| 6 | No negative-memory store — failed approaches aren't recorded anywhere queryable | 4ORMan can re-propose a previously-failed approach; only decisions/outcomes are tracked, not failures as first-class entries | ledger | `ledger` (`~/.4orman/ledger.json`) | Add `ledger record-failure <question> <tried> <why-failed>` reusing existing storage/staleness/append-only machinery | Medium | none |
| 7 | No conflict resolver for rule-vs-rule disagreement (Phase 3, not built) — only Claude-vs-Zig ties are resolved | Once Phase 3 produces multiple learned rules, two can disagree with zero deterministic tiebreaker | rule | `ledger score` composite formula | Extend `ledger score` to accept two rule IDs, return the one with higher stored verified success rate | Medium | #6 (need stored outcomes to compare) |
| 8 | `compat-check` baseline is only verified at session start, not before later high-stakes calls | Mid-session drift (e.g. background `brew upgrade`) isn't caught before a later `YES`, even though spec.md's own risk register flags exactly this | cache | `compat-check` | Cheap mtime/version re-check before any `quality-gate`/`prod-ready`/`build`/`run-tests` call, not just at boot | Medium | none |
| 9 | `context-dependency-graph` `importedBy` is a basename-substring heuristic, not a resolved import graph | A refactor "blast radius" built on this can miss aliased imports or flag prose/comment mentions — unreliable for the exact task type (architecture_refactor) it's meant to serve | capability | `context-dependency-graph` (M37) | Tighten `extractImportTarget` matchers to require import-statement context, not bare substring | Medium | none |
| 10 | `plugin-run` executes user plugins from manifest declarations with no behavioral verification | A plugin can claim read-only behavior while actually writing/deleting — `sandbox-check` covers raw shell strings, not plugin scripts | policy | `plugin-run`, `sandbox-check` | Route plugin execution through `sandbox-check` before `worker-run` invokes it | Medium | #2 (same enforcement point) |
| 11 | `ledger record-outcome` (matched/diverged) is self-reported with no independent check | A falsely-reported "matched" outcome silently corrupts the 365-day staleness/decay signal with no detection path | evidence | `ledger record-outcome` | Require a re-runnable evidence hash (e.g. `quality-gate` JSON) instead of free-text reasoning | Medium | #1 (crash-free build/test verdicts as evidence source) |
| 12 | `context-classifier` confidence is relative (winner/total), not absolute — one weak match reports 1.0 same as ten strong matches | Downstream consumers can't threshold on confidence — "barely classified" and "clearly classified" are numerically identical | metadata | `computeContextClassifier` | Return absolute match-count alongside the existing relative ratio | Low | none |
| 13 | No model router (Phase 4) — task→model assignment is implicit (whichever launcher was typed), not measured | Claude/Codex dual-surface already exists but nothing decides which one a task should run under based on fit | architecture | none yet (genuinely new) | Defer — do not build until #6's evidence log feeds `success_rate`, per already-agreed roadmap sequencing | Low | #6, M36 |
| 14 | No prompt-pattern learning/reuse loop exists — only per-project `project-state record-pattern` and decision-level `ledger` entries exist; neither captures reusable *structural* prompt patterns with reuse/determinism scoring | Every request re-derives context/prompt structure from scratch; 4ORMan has no deterministic basis to choose "reuse this proven pattern" over "let Claude re-derive it," and no mechanism to reject a lower-quality variant of an already-known-good pattern | registry | `project-state record-pattern` (per-project storage) + `ledger` (dedup / staleness / append-only / reject-lower-quality mechanics) — merge into one, don't add a third store | Promote pattern storage to a global `~/.4orman/patterns.json` (same tier as `~/.4orman/ledger.json`), schema below. Rank by lifetime value, not a single token delta. New entries only when no existing pattern can be extended (reuse `ledger`'s dedup logic). Gate promotion through the same anti-drift law as Phase 3: Observe → Verify → Store → Promote slowly → Roll back fast — one successful run is not proof of a reusable pattern | High | M36 `context-classifier` (trigger matching), #6 (evidence log — pattern promotion needs verified outcomes, not self-certified ones) |
| 15 | No general rule that raw stdlib APIs with input-shape-dependent UB (not just `*Absolute` — the same class of bug can exist anywhere a function silently assumes a precondition instead of validating it) must go through a vetted wrapper before use | Row 1's bug (11 confirmed crashes, ~34 more unaudited) is one instance of a pattern, not an isolated fix — without a standing rule, the next unvalidated-precondition bug ships the same way: undetected until a real invocation hits it | terminal primitive | `resolveAbsolutePath` (row 1's fix) as the first instance; `CLAUDE.md` guardrails as the enforcement point | Added to `CLAUDE.md` "Always do": any raw `std.Io.Dir` `*Absolute` call must go through a resolver, never take `args[N]` directly. Generalize as more UB-on-bad-input classes are found — this is a standing rule, not a one-time fix | Highest | none — done for path args, open-ended for other UB classes |
| 16 | No Patch Integrity Gate — no standing, enforced sequence for verifying a code edit before declaring it done | This exact bug shipped (and would have shipped again on the next 11-site patch) without a forcing function that runs build + targeted tests + a full-suite check in a fixed order before "done" | policy | `CLAUDE.md` "Always do" guardrails | Added to `CLAUDE.md`: after every code edit — (1) `zig fmt --check`, (2) `zig build -Doptimize=ReleaseSafe`, (3) read the diff for incomplete `catch`/`try`/unhandled error unions, (4) targeted test for the changed function, (5) full `zig build test` only after the targeted pass | Highest | none |
| 17 | No regression-test-per-discovered-crash discipline — row 1's bug was fixed at the 11 call sites but `zig build test`/`stress` had zero coverage of relative-path invocation before today, meaning the fix's own correctness was unverified until stress.zig was extended | A fix without a regression test is a fix that can silently regress on the next refactor — "fixed" and "verified fixed, permanently" are different claims | evidence | `src/stress.zig` (black-box Tier 1/2/3 harness) | Added Tier 4 to `stress.zig`: `runIn`/`smokeIn`/`badIn` (subprocess `cwd` override) covering all 11 fixed subcommands invoked with `.` — every future discovered-crash fix gets one line here, not just a manual repro that then gets discarded | High | row 1 (fix must exist before its regression test does) |

### Prompt Pattern Registry — data matrix

One unified schema per registry entry (`~/.4orman/patterns.json`). Extraction fields are Claude-authored at learning time; scoring fields are Zig-computed and read-only to Claude — Claude proposes a pattern, Zig owns its value.

| Field | Type | Source | Description |
|---|---|---|---|
| `id` | string | Zig (hash) | `sha256(triggers + structuralPattern)`, truncated — stable dedup key |
| `triggers` | `[]string` | Claude (extracted) | keyword/task-type signals that should match this pattern; reuses `context-classifier`'s signal vocabulary rather than inventing a second one |
| `structuralPattern` | string | Claude (extracted) | the reusable prompt/context *structure* — never the literal prompt text |
| `compressionRules` | `[]string` | Claude (extracted) | rules for shrinking context when this pattern applies |
| `reasoningPrinciples` | `[]string` | Claude (extracted) | why the structure works — used for future dedup/merge judgment, not shown to the end user |
| `avgTokensSaved` | f64 | Zig (running average) | mean token delta across all reuses; updated incrementally on each verified reuse, never overwritten |
| `reuseCount` | u32 | Zig (increment) | increments only on *verified* successful reuse, not on every match attempt |
| `determinismScore` | f64, 0–1 | Zig (measured) | fraction of reuses producing bit-identical structural output |
| `confidence` | f64, 0–1 | Zig (ledger-style scoring) | same 10-source / 100%-composite discipline as `ledger score`, where citations apply |
| `lifetimeValue` | f64 | Zig (derived, read-only) | `avgTokensSaved × reuseCount × determinismScore × confidence` — see formula below. This is the ranking key `context-gate`/pattern-matching sorts by, never `avgTokensSaved` alone |
| `supersededBy` | `?string` | Zig | id of the replacing pattern, if any — append-only, same convention as the ledger |
| `lastVerifiedAt` | timestamp | Zig | staleness clock — reuses the ledger's 365-day `check-stale` model rather than a new one |

**Lifetime Value, not token delta:**

```
Pattern Value = Average Tokens Saved × Successful Reuse Count × Determinism Score × Confidence
```

A pattern saving 20 tokens reused 5,000 times outranks one saving 300 tokens used once — the optimization target is cumulative savings over the project's lifetime, not the single biggest one-time compression. `lifetimeValue` is what gets compared when Zig decides whether a new candidate pattern should supersede an existing registry entry, per the "reject lower-quality variants" rule.

**Never store:** full prompts, conversations, responses, duplicate patterns — only the structural, reusable shape and its scoring metadata.

### Worked example: first real Prompt Pattern Registry entry

The registry doesn't exist yet (row 14 — High, not yet built), but row 1's fix produced the first pattern that would go into it once it does. Recorded here now so it isn't lost before the registry is built:

```
Pattern: Path Argument Normalization

Trigger: any subcommand whose spec accepts a filesystem path as a positional arg

Rule: never pass a raw user-supplied path into a std.Io.Dir *Absolute API.
Resolve every such arg through root.resolveAbsolutePath(gpa, io, path) —
then free it — before it reaches any compute* call.

Reason: *Absolute APIs are undefined behavior on a relative path in this
Zig version. Confirmed as allocator corruption (panic: reached unreachable
code), not a clean error — "." is also the single most natural way a user
invokes a CLI tool from inside a project directory, so this triggers on
the common path, not an edge case. One shared resolver at the dispatch
layer prevents the same bug from being independently rediscovered and
independently fixed at N call sites.

Verification checklist for any new path-taking subcommand:
- invoked with "."
- invoked with a relative subpath
- invoked with an absolute path
- invoked with a nonexistent path
- invoked with a path containing a symlink or ".."
```

This is exactly the shape row 14's data matrix expects: a trigger, a structural rule (not the literal fix diff), the reasoning, and a verification checklist — no prompt or conversation text stored, just the reusable engineering pattern. `reuseCount` for this pattern is already 11 (the confirmed sites) with an estimated ~34 more to go — a strong `lifetimeValue` candidate once the registry exists to score it.
