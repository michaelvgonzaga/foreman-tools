# foreman-tools

A native Zig CLI binary that offloads mechanical data-gathering from Claude's token budget — outputs JSON blobs that Foreman commands read instead of reasoning through raw shell output.

---

## Spec

See `spec.md` for milestones and decisions. See `api-schema.md` for the locked JSON output contract — any field change requires a version bump. Key facts:

- **Goal:** Replace Claude's inline shell reasoning with a native binary; Claude reads one JSON blob instead of parsing git/gh output token-by-token
- **User:** Foreman command files running inside Claude Code sessions — never invoked directly by the user
- **Domain:** Developer tooling / CLI
- **v1 scope:** `status` subcommand (session-start data) + `commits` subcommand (release workflow)
- **Out of scope:** `repos` (GitHub scanning), `sha` (tarball hashing), Linux/Windows builds

---

## Guardrails (project-specific)

### Always do
- Read `spec.md` before any implementation work
- Run `/verify-output` before marking tasks complete
- Keep changes scoped to v1 — do not add features not in the spec
- JSON to stdout, errors to stderr, exit 1 on failure — no exceptions

### Ask first
- Any new subcommand or output field not in the spec
- Any change to the JSON output schema — Foreman command files depend on it
- Cross-platform builds beyond macOS arm64 + amd64
- Distribution changes (tap formula, install location)

### Never do
- Never write to the filesystem (read-only tool)
- Never modify git state — read refs and log only
- Never make network calls directly — delegate to system git and gh binaries
- Never produce output that isn't valid JSON on stdout (on success)
- Skip the verifier before marking work done
- Add scope without updating spec.md and getting explicit sign-off first

---

## Tools & Resources

- **Repo:** https://github.com/michaelvgonzaga/foreman-tools
- **Platform / runtime:** Zig 0.16 — single binary, macOS arm64 + amd64 universal
- **Key tools & services:** System `git` binary (subprocess), system `gh` binary (subprocess for repos subcommand — v2 only)
- **Data & storage:** None — stateless, reads from git refs and filesystem
- **Domain-specific requirements:** None

---

## How to execute

```bash
# setup
brew install zig   # or download from ziglang.org — pin to 0.16

# build
zig build -Doptimize=ReleaseSafe -Dcpu=apple_m3

# run / work
./zig-out/bin/foreman-tools status ~/foreman
./zig-out/bin/foreman-tools commits ~/foreman/myproject v1.2.0

# validate / test
zig build test
```

---

## Knowledgebase

Project knowledge: `knowledge/[topic].md`. Global: `_knowledgebase/[topic].md`.

---

## Decision log

| Date | Decision | Why |
|------|----------|-----|
| 2026-06-28 | Single binary, multiple subcommands | Simpler distribution — one install, one PATH entry |
| 2026-06-28 | JSON to stdout only, errors to stderr | Claude reads stdout; mixing output formats breaks parsing |
| 2026-06-28 | Optional dependency with graceful fallback | Foreman must work without it; foreman-tools is an optimization, not a requirement |
| 2026-06-28 | Zig 0.16, macOS only for v1 | Zig pre-1.0 stability; macOS is the only current target platform |
| 2026-06-28 | Distributed via homebrew-foreman tap | No new tap; installs alongside foreman-ai in one step |
| 2026-06-28 | status reads already-fetched refs, does not git fetch | Latency: fetch adds 200-500ms on every session open; ref reads are instant |
| 2026-06-28 | Added M4 gh-user, M5 release-info, M6 repo-info to spec | Audit of 14 command/skill files found these patterns repeated across 3–5 files each; one JSON read replaces 2–3 shell calls + Claude parsing |
| 2026-06-28 | Added M7 tag-exists to spec | foreman-tools audit found `git tag \| grep "^v<version>$"` in both `/release` and `/brew-release` Step 2 pre-flight — candidate promoted per repetition rule |
| 2026-06-28 | comptime StaticStringMap for FRAMEWORK_MAP, CONFIG_FILE_MAP, SKIP_DIR_SET (v0.9.0) | O(1) lookups at zero runtime cost; replaces O(n) linear scans that ran on every file entry during scan |
| 2026-06-29 | grep subcommand uses literal string search, not regex (v0.10.0) | Covers the dominant Claude usage pattern (find a symbol/string); avoids pulling in a regex engine; can upgrade to regex in a future version |
| 2026-06-29 | grep caps at 500 matches and skips files >5 MB (v0.10.0) | Prevents unbounded JSON output that would consume the token budget the subcommand is meant to save |
| 2026-06-29 | parse-stack reads from stdin, not a file arg (v0.10.0) | Stack traces arrive inline in Claude's context, not as files on disk; stdin lets the caller pipe directly without writing a temp file |
| 2026-06-29 | find-files glob supports only *.ext / prefix* / *contains* / exact / * (v0.11.0) | Covers every real-world pattern without pulling in a regex engine; ** recursive glob deferred until a concrete need surfaces |
| 2026-06-29 | find-files caps at 2000 results (v0.11.0) | Beyond 2000 matches the JSON output itself becomes a token problem; caller should narrow the glob instead |
| 2026-06-29 | json-query value field is a raw JSON fragment, not a re-encoded string (v0.12.0) | Avoids double-encoding; caller reads the value directly without a second parse step |
| 2026-06-29 | json-query uses dot notation with numeric segments for array indexing (v0.12.0) | Keeps the path syntax uniform; `items.1` is simpler to pass as a CLI arg than `items[1]` |
| 2026-06-29 | git-diff runs two git calls (--numstat + --name-status) and correlates them (v0.13.0) | --numstat gives clean addition/deletion counts; --name-status gives A/M/D/R status; neither alone gives both |
| 2026-06-29 | list-dir sorts dirs first then files alphabetically (v0.13.0) | Matches mental model of ls -la; dirs up front means structure is visible before file noise |
| 2026-06-29 | env-scan returns keys only, never values (v0.14.0) | Values are secrets; keys are all Claude needs to understand what a project requires |
| 2026-06-29 | toml-query reuses JsonQueryResult (v0.14.0) | Same shape as json-query means callers handle both identically; no new struct needed |
| 2026-06-29 | toml-query TOML parser is line-by-line, no full AST (v0.14.0) | Covers 95% of real usage (Cargo.toml, pyproject.toml) without a full TOML library; handles [[array-of-tables]] by ignoring it |
| 2026-06-29 | tarball-sha sleep uses std.posix.system.nanosleep (v0.16.0) | std.time.sleep and std.posix.nanosleep don't exist in Zig 0.16; direct POSIX syscall via posix.system is the correct path |
| 2026-06-29 | formula-info parser is line-by-line, not a Ruby AST (v0.17.0) | Covers all real Homebrew formulas (url/sha256/version are always plain quoted fields); avoids pulling in a Ruby parser |
| 2026-06-29 | validate-hooks returns false on missing/malformed file, not an error (v0.18.0) | Callers (/setup-automation, /first-run) already handle the false case; erroring adds no new information and complicates caller logic |
| 2026-06-29 | validate-hooks uses std.c.getenv for HOME (v0.18.0) | std.posix.getenv doesn't exist in Zig 0.16; std.c.getenv is the correct path for libc-backed targets |
| 2026-06-29 | gh-release passes --notes-file to gh, not --notes (v0.19.0) | --notes requires shell escaping of newlines/quotes/backticks; --notes-file lets gh read content directly, eliminating the escaping problem entirely |
| 2026-06-29 | api-schema.md locks all 24 subcommand output shapes | Schema drift is the highest-cost failure mode for downstream modules (Context Builder, Cache Engine); a single source of truth forces a version bump before any shape change |
| 2026-06-29 | file-hash computes SHA256 of a local file (v0.20.0) | Reuses existing sha256Hex helper from tarball-sha; foundation for cache-engine M2 change detection; pure read, no persistent state yet |
| 2026-06-29 | cache-check persists hash to ~/.cache/foreman-tools/ (v0.21.0) | First write operation in foreman-tools; uses std.Io.Dir.createDirAbsolute(.default_dir) + createFileAbsolute; write failures silently ignored so the result is always correct even if caching fails; one file per tracked path keyed by SHA256(file_path) |
| 2026-06-29 | cache-store/cache-fetch keyed by SHA256(file_path + ":" + sub_key) (v0.22.0) | Cache entry format: "<sha256>\n<value>"; auto-invalidates on file change; std.mem.trimEnd (not trimRight) for trailing newline strip; value capped at 512KB |
| 2026-06-29 | context-scan builds on computeScan, distills to top-10 + kind counts (v0.23.0) | Avoids duplicating scan logic; calls computeScan internally and frees the full result after extracting the compact summary |
| 2026-06-29 | KindCounts.test field must be declared and accessed as @"test" in Zig 0.16 | `test` is a reserved keyword; `test: u32` in a struct body and `counts.test` in expressions both fail to parse — must use `@"test": u32` and `counts.@"test"` throughout |
| 2026-06-29 | context-rank reads first 8KB per file for relevance scoring (v0.26.0) | 8KB covers most small-medium files fully; large files (root.zig at 118KB) are partially scored — name match bonus (300 pts) compensates when the file name is meaningful; score = hits×5 + nameMatch×300 + kind_bonus |
| 2026-06-29 | scan now excludes .DS_Store + binary extensions via shouldSkipScanFile (v0.26.0) | SKIP_FILE_SET (.DS_Store, Thumbs.db) + BINARY_EXT_SET check applied in walkScanFiles — affects scan, context-scan, context-rank, find-files |
| 2026-06-29 | context-changed reuses computeGitDiff's numstat+name-status pattern, adds per-file unified diff (v0.25.0) | three git calls per invocation: numstat, name-status, then one `diff --unified=3 -- <path>` per file; diff capped at 100 lines; std.ArrayList(.empty) works in Zig 0.16 (only .init(gpa) fails) |
| 2026-06-29 | context-evidence uses two-pass slice allocation, not std.ArrayList (v0.24.0) | std.ArrayList([]const u8).init(gpa) fails in Zig 0.16 — the type resolves to ArrayListAligned which has no .init; avoid ArrayList entirely; count first, allocate exact size, fill in second pass |
| 2026-06-29 | context-evidence window merging: allocate match_count slots for windows, merge in place, cap at EVIDENCE_MAX_CHUNKS | worst case = match_count non-overlapping windows; over-allocate and track merged_count; no dynamic growth needed |
| 2026-06-29 | yaml-query uses indentation-based block-style parser, not a full YAML AST (v0.27.0) | covers 95%+ of real-world YAML (GitHub Actions, docker-compose, k8s); avoids pulling in a YAML library; trimLeft→trimStart, trimRight→trimEnd in Zig 0.16 |
| 2026-06-30 | outline uses line-by-line pattern matching, not a full AST (v0.28.0) | covers 12 languages; extracts top-level and nested definitions (no indentation filtering — trimmed lines look top-level); capped at 200 symbols; skips lines starting with comment chars before language dispatch |
| 2026-06-30 | deps errdefer uses `for (...) { ... } gpa.free(buf)` — no `;` between for-block and next statement (v0.29.0) | Zig 0.16: for-block is a compound statement, trailing `;` after `}` is a parse error |
| 2026-06-30 | atomic writes via `atomicRenameAbsolute` helper + `std.c.rename` (v0.30.0) | `writeCacheEntry` and `computeCacheStore` both wrote directly via `createFileAbsolute` — power loss mid-write left a corrupted cache entry; fix: write to `{entry_path}.tmp`, flush, close, then `std.c.rename(tmp, final)`; `std.c.rename` is the correct path in Zig 0.16 (libc-backed); `std.posix.rename` does not exist in 0.16 |
| 2026-06-30 | `device-scan` subcommand spec locked (M30, v0.30.0) | Profile hardware+tools+optimal at first install, store to `~/.foreman/profile.json`; Claude reads this at session start instead of re-discovering the environment; community contribution to `foreman-env` repo is opt-in with explicit consent and strips all user paths before sharing |
| 2026-06-30 | `run-tests` implemented (M28, v0.31.0) | Framework detection via manifest files (package.json→jest/vitest, pytest.ini/conftest.py/pyproject.toml→pytest, go.mod→go, Cargo.toml→cargo, build.zig→zig); uses `env -C <path>` as cwd mechanism (macOS 12+, no `.cwd` field in std.process.run in Zig 0.16); timing via `std.c.clock_gettime(CLOCK.MONOTONIC)` (std.time.nanoTimestamp does not exist in Zig 0.16); per-framework text parsers (zig/cargo/go/pytest/jest); failures capped at 50; `@"test"` field name required since `test` is a Zig keyword |
| 2026-06-30 | `build` implemented (M29, v0.32.0) | Detection order: Cargo.toml→cargo, build.zig→zig, go.mod→go, package.json(with "scripts"+"build")→npm, Makefile→make; cargo parser is a state machine (error[Exx]: msg + " --> file:N:M" two-line pair); zig/gcc/clang parser uses lastIndexOf(":") twice to split path:N:M from ": error: " marker; go parser matches ".go:" prefix pattern; TypeScript parser matches "file(N,M): error" paren-coord format; errors capped at 50, warnings at 20; `truncated` is a single shared bool across both arrays |
| 2026-06-30 | `env-inspect` implemented (M4, v0.33.0) | Manifest-gated language detection (go.mod→go, requirements.txt/pyproject.toml→python, package.json→node, Cargo.toml→rust, build.zig→zig, Gemfile→ruby, pom.xml/build.gradle→java); `checkBinary(bin, flag)` runs binary + collects stdout+stderr; `extractVersionStr` finds first N.N[.N] pattern (handles v-prefix, embedded versions like go1.22.0); package managers always checked (npm/pip/cargo/brew/yarn/pnpm); missing items include runtime gaps and uninstalled deps (node_modules, .venv, vendor/bundle); envVars from .env* files via existing parseEnvKeys |
| 2026-06-30 | `prod-ready` implemented (M24-M1-M5, v0.43.0) | Calls `computeQualityGate` (skips on error → warning), `computeSecretScan` (findings → blocker), `computeEnvInspect` (missing → warnings, bare `catch` for errors); quality-gate critical/high → blockers with build_errors/test_fails counted from `f.source` field; fault-tolerant: each check wrapped in labeled blk with `catch { break :blk null }`; `_ = e` pattern caused compiler error → use bare `catch` instead; GPA leak warnings go to stderr, not stdout — JSON output clean |
| 2026-06-30 | `validate-schema` implemented (M16-M5, v0.42.0) | JSON Schema subset validator; `validateValue(data, schema, path, depth)` recursive to depth 6; `jsonMatchesType` maps JSON variants to schema type names (integer matches "integer" and "number", float only matches "number"); labeled blocks (`break :min_len`) used instead of goto for constraint skipping; violations store `[]const u8` slices — required-field paths are direct allocPrint (no defer), property-descend paths use defer-freed temporaries with the actual violation storing a duped copy; `additionalProperties: false` flags unexpected keys |
| 2026-06-30 | `quality-gate` implemented (M15-M1-M3, v0.41.0) | Calls `computeBuild` (skips on `error.NoBuildSystem`) and `computeRunTests` (skips on `error.NoTestFramework`); build errors → `high`, build crash (success:false + errors.len==0) → `critical` with allocPrint message, build warnings → `medium`; test failures → `high`, test runner crash (success:false + failures.len==0 + failed==0) → `critical`; verdict = "fail" if critical.len>0 or high.len>0, else "pass"; findings reuse pointers from BuildResult/RunTestsResult (no dupe — process exits immediately); capped at 50 per level |
| 2026-06-30 | `shell-run` implemented (M9-M1-M4, v0.40.0) | Runs `/bin/sh -c <cmd>`; destructive check via `shellRunBlockReason` on lowercased first 4KB of command (uses `std.ascii.lowerString` into stack buf); `shellRunRmRfDanger` checks that char after `rm -rf /` is space/special/end (not a letter = specific path); exit code from `.term.exited |c|` (lowercase); duration from MONOTONIC clock diff in ms; `timedOut = duration_ms >= timeout_ms` (retrospective, not enforced); stdout/stderr owned by gpa, display-capped at 128KB; blockReason is a string literal (not owned) |
| 2026-06-30 | `project-state` implemented (M28-M1-M2, v0.39.0) | State file at `~/.foreman/state/ps-{sha256(abs_path)}.json`; `computeProjectState` accepts `ProjectStateMode` union (read / record_decision / record_pattern); `parseProjectStateFile` reads+parses via `std.json.parseFromSlice(std.json.Value,...)`; `writeProjectStateFile` uses `w.interface.writeAll`/`print`/`flush` + `atomicRenameAbsolute`; `allocJsonEscape` (already in root.zig at line ~407) handles user-supplied text; date from `std.c.clock_gettime(CLOCK.REALTIME)` → `tsToDateStr` (manual Gregorian calculation); capped at 100 decisions / 50 patterns |
| 2026-06-30 | `git-cache` implemented (M14-M3, v0.38.0) | Cache keyed by HEAD SHA (not file hash): cache file `gc-{sha256(repo)}.json`, first line is stored HEAD SHA, body is JSON state; `std.json.parseFromSlice` parses cache on hit; miss path calls `runGit` for branch/status/ahead-behind/log; `--left-right --count HEAD...@{u}` gives ahead\tbehind in one call; cache invalidates automatically on any commit |
| 2026-06-30 | `delta-context` implemented (M13-M2, v0.37.0) | `git diff --name-only [ref]` → parse `@@ -old +new,count @@` hunk headers → `computeOutline` per file → `findOwningSymbol` maps changed lines to symbol bodies (symbol owns from its line until next symbol's line) → `computeSymbolFind` per symbol for callers; capped at 8 files / 10 symbols / 10 callers; lone `}` in Zig format string needs `}}` escape |
| 2026-06-30 | `device-scan` implemented (M30-M1, v0.36.0) | `sysctl -n machdep.cpu.brand_string/hw.physicalcpu/hw.memsize` + `uname -m` for hardware; `checkBinary` (reused from env-inspect) for 7 tools; `deviceScanZigFlags` maps M1–M5 chip names to `-Dcpu=apple_mN`; profile written atomically to `~/.foreman/profile.json`; `std.fmt.bufPrint` into stack buffer for tools JSON (std.ArrayList.init/std.io.fixedBufferStream don't exist in Zig 0.16); `computeCacheStore` called inline to pre-warm cache so next `cache-fetch` hits immediately |
| 2026-06-30 | `secret-scan` implemented (M19-M1, v0.35.0) | Two detection modes: prefix-match (high-confidence token formats like sk_live_, AKIA, ghp_, PEM headers) and assignment-key (case-insensitive needle in variable name + non-placeholder value); `secretScanIsCleanKey` rejects compound-statement keys (containing `(`, `)`, `{`, `}`, `;`); `secretScanIsPlaceholder` rejects digit/dot-starting values, type declarations (struct/enum/union), env var references, and known placeholder strings; skips comment lines + binary files + .example files |
| 2026-06-30 | `symbol-find` implemented (M6-M2, v0.34.0) | Single-pass walk with keyword-based declaration detection (fn/def/function/func/class/struct/trait/const/var/let/val + 10 more); whole-word boundary matching via `isWordChar`; magic-byte binary skip (Mach-O 3 variants + ELF); definition = first keyword match, references = remaining whole-word hits; capped at 100 refs; replaces grep+read-N-files pattern |
| 2026-06-30 | `compat-check` implemented (M31, v0.30.0) | Pure Zig, ~20ms, zero Claude tokens; `parseBaselineField` returns slice into content (not owned) for safe in-place parsing; `extractVersionFromLine` strips leading v/V and finds first digit-starting token — handles zig/git/gh/brew/node/python3 output formats without special cases; rollback commands include exact version specifier from baseline (e.g. zig@0.15); risk levels: high=zig+foreman_tools, medium=node+python3, low=git+gh+brew; baseline stored atomically to ~/.foreman/compat-baseline.json |
