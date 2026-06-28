# foreman-tools

A native Zig CLI binary that offloads mechanical data-gathering from Claude's token budget — outputs JSON blobs that Foreman commands read instead of reasoning through raw shell output.

---

## Spec

See `spec.md` for the full spec. Key facts:

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
