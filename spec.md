# foreman-tools Spec

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
- Linux / Windows builds — v1 is macOS only (arm64 + amd64)
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

---

## Open questions

- Should `status` do the actual `git fetch` or just read the already-fetched `origin/main` ref? Fetching adds latency on every session open; reading the ref is instant but stale if fetch hasn't run. Lean toward read-only for speed, let the self-update skill decide whether to fetch.

---

## Milestones

| Milestone | What a user can do | Done when... |
|-----------|-------------------|--------------|
| M1 — status subcommand | Session-start check outputs JSON in <10ms | `foreman-tools status ~/foreman` exits 0 and returns valid JSON with all four fields: `upToDate`, `behindBy`, `firstRun`, `projectsFileExists` |
| M2 — commits subcommand | Release workflow hands Claude categorized JSON | `foreman-tools commits ~/foreman/myproject v1.2.0` returns JSON array of commits since that tag, each with `hash`, `category`, `message`; categories are one of `new`, `improvement`, `fix`, `docs`, `other` |
| M3 — Homebrew distribution + Foreman integration | foreman-tools installs alongside foreman-ai; all relevant Foreman commands use it when present | `brew install foreman-ai` installs foreman-tools binary; `/self-update` and `/release` use foreman-tools when available, fall back cleanly when not; token savings verified against baseline |
