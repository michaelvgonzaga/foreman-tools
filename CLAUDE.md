# 4orman-tools

A native Zig CLI binary that offloads mechanical data-gathering from Claude's token budget — outputs JSON blobs that 4ORMan commands read instead of reasoning through raw shell output.

---

## Spec

See `spec.md` for milestones and decisions. See `api-schema.md` for the locked JSON output contract — any field change requires a version bump. Key facts:

- **Goal:** Replace Claude's inline shell reasoning with a native binary; Claude reads one JSON blob instead of parsing git/gh output token-by-token
- **User:** 4ORMan command files running inside Claude Code sessions — never invoked directly by the user
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
- **Patch Integrity Gate — after every code edit, in order:** (1) `zig fmt --check` on only the files you changed, and only fail on hunks inside your own diff — this repo has pre-existing unformatted code elsewhere; never run a bare `zig fmt` and commit whatever it reformats, that turns a scoped fix into an unrelated-code diff (verify with `diff <(zig fmt --stdin < file) file` scoped to your changed lines, not a blind `zig fmt <file>`), (2) `zig build -Doptimize=ReleaseSafe`, (3) grep/read the diff for incomplete `catch`/`try` blocks or unhandled error unions, (4) run the targeted test(s) for the changed function only, (5) run the full `zig build test` suite only after the targeted pass — don't jump straight to the full suite, it hides which change broke what
- **Path Argument Normalization — any subcommand accepting a filesystem path:** never pass the raw arg into a `std.Io.Dir` `*Absolute` API. Resolve through `root.resolveAbsolutePath(gpa, io, path)` first, then free it, before any `compute*` call. Relative paths (including `.`) into `*Absolute` APIs are undefined behavior in this Zig version — confirmed as allocator corruption, not a clean error (2026-07-02 decision log). Verify any new path-taking subcommand against: `.`, a relative subpath, an absolute path, a nonexistent path, and a symlink/`..`-containing path

### Ask first
- Any new subcommand or output field not in the spec
- Any change to the JSON output schema — 4ORMan command files depend on it
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

- **Repo:** https://github.com/michaelvgonzaga/4orman-tools
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
./zig-out/bin/4orman-tools status ~/4orman
./zig-out/bin/4orman-tools commits ~/4orman/myproject v1.2.0

# validate / test
zig build test
```

---

## Knowledgebase

Project knowledge: `knowledge/[topic].md`. Global: `_knowledgebase/[topic].md`.

---

## Decision log

See [knowledge/decisions.md](knowledge/decisions.md) for all implementation decisions.
