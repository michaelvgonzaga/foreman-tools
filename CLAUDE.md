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
zig build -Doptimize=ReleaseSafe

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
| 2026-06-29 | context-changed reuses computeGitDiff's numstat+name-status pattern, adds per-file unified diff (v0.25.0) | three git calls per invocation: numstat, name-status, then one `diff --unified=3 -- <path>` per file; diff capped at 100 lines; std.ArrayList(.empty) works in Zig 0.16 (only .init(gpa) fails) |
| 2026-06-29 | context-evidence uses two-pass slice allocation, not std.ArrayList (v0.24.0) | std.ArrayList([]const u8).init(gpa) fails in Zig 0.16 — the type resolves to ArrayListAligned which has no .init; avoid ArrayList entirely; count first, allocate exact size, fill in second pass |
| 2026-06-29 | context-evidence window merging: allocate match_count slots for windows, merge in place, cap at EVIDENCE_MAX_CHUNKS | worst case = match_count non-overlapping windows; over-allocate and track merged_count; no dynamic growth needed |
