# 4orman-tools

A Zig-native CLI that replaces shell reasoning in Claude Code sessions with structured JSON — one binary call instead of a chain of bash commands.

Used internally by [4ORMan](https://github.com/michaelvgonzaga/4orman). Not designed for direct user invocation.

## Install

```bash
brew install michaelvgonzaga/4orman/4orman-tools
```

## Usage

Every subcommand returns JSON to stdout. Errors go to stderr, exit 1 on failure.

```bash
4orman-tools <subcommand> [args...]
```

### Key subcommands

| Category | Subcommand | What it returns |
|---|---|---|
| Session | `doctor` | claude / git / gh present + version |
| Session | `compat-check` | version drift vs baseline + rollback advice |
| Git | `git-cache <repo>` | branch, HEAD SHA, dirty state, ahead/behind, last 10 commits |
| Git | `release-info <repo>` | latest tag, suggested next version, commits since |
| Git | `git-diff <repo> [ref]` | structured diff summary |
| Filesystem | `scan <path>` | project structure, entry point, file inventory |
| Filesystem | `list-dir <path>` | immediate directory contents |
| Filesystem | `find-files <root> <glob>` | files matching a glob pattern |
| Context | `context-rank <root> <query>` | top 15 files ranked by query relevance |
| Context | `context-evidence <file> <pattern>` | relevant excerpts ±10 lines |
| Context | `context-changed <repo>` | changed files with unified diff content |
| Cache | `cache-fetch <file> <key>` | hit/miss + stored value |
| Cache | `cache-store <file> <key>` | store extracted JSON (reads stdin) |
| Workers | `worker-run <lang> <script>` | run a script in any of 11 language runtimes |
| Workers | `worker-list` | all supported language runtimes |
| Quality | `quality-gate <path>` | build + test verdict with severity-bucketed findings |
| Quality | `prod-ready <path>` | build + tests + secrets → `{ ready, blockers, warnings }` |
| Security | `secret-scan <path>` | hardcoded secrets across a project |
| Meta | `registry` | full catalog of all subcommands |
| Meta | `route <task>` | execution plan for a natural-language task description |
| Meta | `capability-check <query>` | is this capability native or needs Claude fallback? |

Full JSON output contract: [`api-schema.md`](api-schema.md)

### Supported worker runtimes

`python` · `node` · `deno` · `bun` · `go` · `ruby` · `bash` · `swift` · `zig` · `lua` · `php`

## Output contract

- JSON to stdout, always
- Errors to stderr, exit 1
- No interactive mode, no colored output
- macOS arm64 + amd64 universal binary
